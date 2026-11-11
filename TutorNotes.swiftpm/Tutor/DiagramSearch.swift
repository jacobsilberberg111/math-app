import UIKit

/// Finds freely licensed diagrams on Wikimedia Commons (MediaWiki API: a file-namespace search
/// with image info and licence metadata), and downloads a PNG rendering of the chosen one.
enum DiagramSearch {
    struct Candidate: Equatable {
        var title: String
        var imageURL: URL
        var width: Int
        var height: Int
        var mime: String
        var license: String?
        var artist: String?

        /// "Diagram of the human heart" from "File:Diagram of the human heart.svg".
        var displayName: String {
            var t = title
            if t.hasPrefix("File:") { t.removeFirst(5) }
            if let dot = t.lastIndex(of: ".") { t = String(t[..<dot]) }
            return t.replacingOccurrences(of: "_", with: " ")
        }

        var credit: String {
            var parts = ["Image: \(displayName)"]
            if let artist, !artist.isEmpty { parts.append(artist) }
            parts.append((license?.isEmpty == false ? license! + ", " : "") + "Wikimedia Commons")
            return parts.joined(separator: " · ")
        }
    }

    struct SearchError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// A generic client name, as Wikimedia asks automated clients to identify themselves.
    static let userAgent = "MarginStudyApp/1.0 (iPad note-taking app for students)"

    private static var cache: [String: [Candidate]] = [:]

    static func search(_ query: String) async throws -> [Candidate] {
        let key = query.lowercased()
        if let c = cache[key] { return c }
        var comps = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        comps.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: query + " filetype:bitmap|drawing"),
            URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrlimit", value: "8"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|size|mime|extmetadata"),
            URLQueryItem(name: "iiurlwidth", value: "1200"),
            URLQueryItem(name: "iiextmetadatafilter", value: "LicenseShortName|Artist"),
        ]
        guard let url = comps.url else { throw SearchError(message: "Couldn't build the search.") }
        let data = try await fetch(url)
        guard let json = try? JSONValue.parse(String(decoding: data, as: UTF8.self)),
              let pages = json["query"]?["pages"]?.objectValue else {
            cache[key] = []
            return []
        }
        let sorted = pages.values.sorted { ($0["index"]?.doubleValue ?? 0) < ($1["index"]?.doubleValue ?? 0) }
        let list: [Candidate] = sorted.compactMap { p in
            guard let title = p["title"]?.stringValue, let info = p["imageinfo"]?[0] else { return nil }
            let mime = info["mime"]?.stringValue ?? ""
            guard mime.hasPrefix("image/") else { return nil }
            let thumb = info["thumburl"]?.stringValue ?? info["url"]?.stringValue
            guard let thumb, let u = URL(string: thumb) else { return nil }
            let w = Int(info["thumbwidth"]?.doubleValue ?? info["width"]?.doubleValue ?? 0)
            let h = Int(info["thumbheight"]?.doubleValue ?? info["height"]?.doubleValue ?? 0)
            guard w >= 200, h >= 120 else { return nil }
            let meta = info["extmetadata"]
            return Candidate(title: title, imageURL: u, width: w, height: h, mime: mime,
                             license: meta?["LicenseShortName"]?["value"]?.stringValue.map(plain),
                             artist: meta?["Artist"]?["value"]?.stringValue.map(plain).map { String($0.prefix(60)) })
        }
        cache[key] = list
        return list
    }

    static func image(_ c: Candidate) async throws -> UIImage {
        let data = try await fetch(c.imageURL)
        guard let img = UIImage(data: data) else { throw SearchError(message: "That file couldn't be read as an image; try another candidate.") }
        return img
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw SearchError(message: "Couldn't reach Wikimedia Commons (is the iPad online?).")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 429 { throw SearchError(message: "Wikimedia Commons is busy (too many requests); wait a minute and try again, or draw the diagram instead.") }
        guard (200..<300).contains(status) else { throw SearchError(message: "Wikimedia Commons answered \(status).") }
        return data
    }

    /// Strips HTML tags and entities from licence and author fields.
    static func plain(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (e, r) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: e, with: r)
        }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
