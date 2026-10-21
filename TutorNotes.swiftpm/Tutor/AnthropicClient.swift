import Foundation

struct AnthropicError: LocalizedError, Sendable {
    var status: Int?
    var type: String
    var message: String

    var errorDescription: String? {
        switch type {
        case "authentication_error": return "Your Anthropic API key was rejected. Check it in Settings."
        case "permission_error": return "This API key doesn't have access to that model or feature."
        case "not_found_error": return message.isEmpty ? "Not found." : message
        case "rate_limit_error": return "Rate limited by the API — try again in a moment."
        case "overloaded_error": return "Claude is overloaded right now — retrying usually works."
        case "request_too_large": return "That request was too large (try fewer or smaller attachments)."
        case "network": return "Network problem: \(message)"
        default: return message.isEmpty ? "Something went wrong (\(type))." : message
        }
    }

    var isRetryable: Bool {
        if let s = status {
            if [408, 409, 429].contains(s) || s >= 500 { return true }
            // Other 4xx (including non-JSON bodies, which are typed "api_error") won't succeed as-is.
            if s >= 400 { return false }
        }
        return type == "overloaded_error" || type == "rate_limit_error" || type == "api_error" || type == "network"
    }
}

/// Server-sent events from POST /v1/messages with `stream: true`.
enum StreamEvent: Sendable {
    case messageStart(model: String?)
    case blockStart(index: Int, block: JSONValue)
    case textDelta(index: Int, text: String)
    case thinkingDelta(index: Int, text: String)
    case signatureDelta(index: Int, signature: String)
    case inputJSONDelta(index: Int, partial: String)
    case blockStop(index: Int)
    case messageDelta(stopReason: String?, usage: JSONValue?)
    case messageStop
}

/// Minimal raw-HTTP client for the Claude API (there is no official Swift SDK).
struct AnthropicClient: Sendable {
    let apiKey: String
    static let baseURL = URL(string: "https://api.anthropic.com")!
    static let apiVersion = "2023-06-01"

    private func request(path: String, method: String = "POST", betas: [String] = []) -> URLRequest {
        var req = URLRequest(url: AnthropicClient.baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(AnthropicClient.apiVersion, forHTTPHeaderField: "anthropic-version")
        if !betas.isEmpty {
            req.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        return req
    }

    static func parseError(status: Int?, data: Data) -> AnthropicError {
        if let json = try? JSONValue.parse(data), let err = json["error"] {
            return AnthropicError(status: status, type: err["type"]?.stringValue ?? "api_error",
                                  message: err["message"]?.stringValue ?? "")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return AnthropicError(status: status, type: status == 529 ? "overloaded_error" : "api_error",
                              message: text.isEmpty ? "HTTP \(status ?? 0)" : String(text.prefix(300)))
    }

    /// Streams a Messages API request. Cancelling the consuming task cancels the HTTP request.
    func streamMessage(body: JSONValue, betas: [String]) -> AsyncThrowingStream<StreamEvent, Error> {
        var req = request(path: "v1/messages", betas: betas)
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")
        req.httpBody = body.data
        req.timeoutInterval = 600
        let finalRequest = req
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: finalRequest)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        var data = Data()
                        for try await b in bytes {
                            data.append(b)
                            if data.count > 64_000 { break }
                        }
                        throw AnthropicClient.parseError(status: status, data: data)
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, let json = try? JSONValue.parse(payload) else { continue }
                        if json["type"]?.stringValue == "error" {
                            let err = json["error"]
                            throw AnthropicError(status: nil, type: err?["type"]?.stringValue ?? "api_error",
                                                 message: err?["message"]?.stringValue ?? "Stream error")
                        }
                        if let event = AnthropicClient.event(from: json) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch let e as AnthropicError {
                    continuation.finish(throwing: e)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let e as URLError where e.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: AnthropicError(status: nil, type: "network", message: error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func event(from json: JSONValue) -> StreamEvent? {
        switch json["type"]?.stringValue {
        case "message_start":
            return .messageStart(model: json["message"]?["model"]?.stringValue)
        case "content_block_start":
            guard let index = json["index"]?.intValue, let block = json["content_block"] else { return nil }
            return .blockStart(index: index, block: block)
        case "content_block_delta":
            guard let index = json["index"]?.intValue, let delta = json["delta"] else { return nil }
            switch delta["type"]?.stringValue {
            case "text_delta": return .textDelta(index: index, text: delta["text"]?.stringValue ?? "")
            case "thinking_delta": return .thinkingDelta(index: index, text: delta["thinking"]?.stringValue ?? "")
            case "signature_delta": return .signatureDelta(index: index, signature: delta["signature"]?.stringValue ?? "")
            case "input_json_delta": return .inputJSONDelta(index: index, partial: delta["partial_json"]?.stringValue ?? "")
            default: return nil
            }
        case "content_block_stop":
            guard let index = json["index"]?.intValue else { return nil }
            return .blockStop(index: index)
        case "message_delta":
            return .messageDelta(stopReason: json["delta"]?["stop_reason"]?.stringValue, usage: json["usage"])
        case "message_stop":
            return .messageStop
        default:
            return nil
        }
    }

    // MARK: Files API

    /// Uploads a file once so later requests reference it by `file_id` instead of re-sending bytes.
    func uploadFile(data: Data, filename: String, mimeType: String) async throws -> String {
        var req = request(path: "v1/files")
        let boundary = "TutorNotes-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        let safeName = filename.components(separatedBy: CharacterSet(charactersIn: "<>:\"|?*\\/")).joined(separator: "-")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.timeoutInterval = 300
        let (respData, response): (Data, URLResponse)
        do {
            (respData, response) = try await URLSession.shared.upload(for: req, from: body)
        } catch {
            throw AnthropicError(status: nil, type: "network", message: error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AnthropicClient.parseError(status: status, data: respData) }
        guard let id = (try? JSONValue.parse(respData))?["id"]?.stringValue else {
            throw AnthropicError(status: status, type: "api_error", message: "Upload response had no file id")
        }
        return id
    }

    /// Cheap key check: lists models (free) and returns their ids.
    func listModels() async throws -> [String] {
        let req = request(path: "v1/models", method: "GET")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw AnthropicError(status: nil, type: "network", message: error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AnthropicClient.parseError(status: status, data: data) }
        let json = try JSONValue.parse(data)
        return json["data"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
    }
}
