import Foundation
import PDFKit
import UIKit
import Vision

/// Big PDFs (a teacher's slide deck, a novel) are read on demand instead of being sent whole.
///
/// A document block is resent with every request, so a 24 MB deck of class slides cost about
/// 360k tokens per request (11¢ even when cached, around $2 when not). Large reference PDFs
/// are therefore left out of the conversation; the tutor is told they're attached and uses
/// `read_attachment` to search them or read the pages it needs. Past papers and mark schemes,
/// which the tutor needs in full to mark, are always sent whole.
enum AttachmentReader {
    static let largePageCount = 40
    static let largeBytes = 8_000_000
    static let maxPagesPerRead = 6
    static let maxImagesPerRead = 3

    static func pageCount(_ url: URL) -> Int? { PDFDocument(url: url)?.pageCount }

    static func isLarge(_ a: TutorAttachment, url: URL) -> Bool {
        guard a.kind == .pdf, a.role == nil else { return false }
        if a.sizeBytes > largeBytes { return true }
        return (pageCount(url) ?? 0) > largePageCount
    }

    // MARK: Page text index

    /// Where a PDF's page texts are saved, next to the file.
    static func indexURL(_ url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("pages.json") }

    /// Every page's text. Pages without real text (slides exported as pictures) are read with
    /// on-device text recognition. Built once and saved, so later reads are instant.
    static func buildIndex(_ url: URL) -> [String] {
        if let data = try? Data(contentsOf: indexURL(url)), let saved = try? JSONDecoder().decode([String].self, from: data) {
            return saved
        }
        guard let pdf = PDFDocument(url: url) else { return [] }
        var out: [String] = []
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { out.append(""); continue }
            var text = clean(page.string)
            if text.count < 25, let seen = recognizeText(page), seen.count > text.count { text = seen }
            out.append(text)
        }
        if let data = try? JSONEncoder().encode(out) { try? data.write(to: indexURL(url), options: .atomic) }
        return out
    }

    static func recognizeText(_ page: PDFPage) -> String? {
        let image = page.thumbnail(of: CGSize(width: 1600, height: 1600), for: .mediaBox)
        guard let cg = image.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func note(for a: TutorAttachment, pages: Int?) -> String {
        "The student attached \(a.name)\(pages.map { ", a \($0)-page PDF" } ?? ""). It's too big to keep in view every turn, so it isn't included: use read_attachment to list its pages, search it, or read the pages you need."
    }

    /// "4", "4-7", "4, 6, 9-10" → 1-based page numbers within 1...count, at most `maxPagesPerRead`.
    static func parsePages(_ spec: String, count: Int) -> [Int] {
        var out: [Int] = []
        for part in spec.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let bits = part.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if bits.count == 2, let a = bits[0], let b = bits[1], a <= b {
                out += Array(a...min(b, a + maxPagesPerRead))
            } else if bits.count == 1, let a = bits[0] {
                out.append(a)
            }
        }
        var seen = Set<Int>()
        return out.filter { $0 >= 1 && $0 <= count && seen.insert($0).inserted }.prefix(maxPagesPerRead).map { $0 }
    }

    struct Result {
        var text: String
        var images: [Data] = []
    }

    private static func clean(_ s: String?) -> String {
        (s ?? "").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Reads off the main thread: an outline (no pages or query), a search, or specific pages.
    static func read(url: URL, name: String, pages: String?, query: String?, images: Bool) async throws -> Result {
        let texts = await AttachmentIndex.shared.texts(for: url)
        return try await Task.detached(priority: .userInitiated) {
            guard let pdf = PDFDocument(url: url) else { throw ToolInputError(message: "Couldn't open \(name).") }
            let n = pdf.pageCount
            func pageText(_ i: Int) -> String { i < texts.count ? texts[i] : clean(pdf.page(at: i)?.string) }

            if let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
                let terms = q.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
                guard !terms.isEmpty else { throw ToolInputError(message: "Give some words to search for.") }
                var hits: [(page: Int, score: Int, snippet: String)] = []
                for i in 0..<n {
                    let text = pageText(i)
                    let lower = text.lowercased()
                    let score = terms.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
                    guard score > 0 else { continue }
                    var snippet = String(text.prefix(220))
                    if let r = lower.range(of: terms.first { lower.contains($0) } ?? terms[0]) {
                        let at = lower.distance(from: lower.startIndex, to: r.lowerBound)
                        let start = text.index(text.startIndex, offsetBy: max(0, at - 90))
                        snippet = String(text[start...].prefix(240))
                    }
                    hits.append((i + 1, score, snippet.replacingOccurrences(of: "\n", with: " / ")))
                }
                if hits.isEmpty { return Result(text: "No pages of \(name) mention \"\(q)\". Try other words, list the pages, or read pages by number.") }
                let top = hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.page < $1.page }.prefix(8)
                return Result(text: "Pages of \(name) (\(n) pages) matching \"\(q)\":\n" + top.map { "• p.\($0.page): …\($0.snippet)…" }.joined(separator: "\n") + "\nRead the ones you need with pages.")
            }

            if let spec = pages, !spec.trimmingCharacters(in: .whitespaces).isEmpty {
                let list = parsePages(spec, count: n)
                guard !list.isEmpty else { throw ToolInputError(message: "\(name) has pages 1–\(n).") }
                var out: [String] = []
                var pictures: [Data] = []
                for p in list {
                    guard let page = pdf.page(at: p - 1) else { continue }
                    let text = pageText(p - 1)
                    out.append("--- Page \(p) of \(n) ---\n" + (text.isEmpty ? "(no text on this page; see the image)" : String(text.prefix(2_500))))
                    // Pictures when asked for, or for pages that are mostly images.
                    let embedded = clean(page.string)
                    if (images || embedded.count < 40), pictures.count < maxImagesPerRead {
                        let thumb = page.thumbnail(of: CGSize(width: 1000, height: 1000), for: .mediaBox)
                        if let jpeg = thumb.jpegData(compressionQuality: 0.7) { pictures.append(jpeg) }
                    }
                }
                return Result(text: out.joined(separator: "\n\n"), images: pictures)
            }

            // Outline: the first line of each page (slide titles), to find where things are.
            var lines: [String] = ["\(name): \(n) pages. First line of each page:"]
            for i in 0..<min(n, 150) {
                let first = pageText(i).components(separatedBy: "\n").first ?? ""
                lines.append("p.\(i + 1): " + (first.isEmpty ? "(image)" : String(first.prefix(70))))
            }
            if n > 150 { lines.append("… search to find later pages.") }
            return Result(text: lines.joined(separator: "\n"))
        }.value
    }
}

/// Builds each big PDF's page index once (in the background when its note opens), and shares
/// the work if the tutor asks before it's done.
actor AttachmentIndex {
    static let shared = AttachmentIndex()
    private var tasks: [URL: Task<[String], Never>] = [:]

    func texts(for url: URL) async -> [String] {
        if let t = tasks[url] { return await t.value }
        let t = Task.detached(priority: .utility) { AttachmentReader.buildIndex(url) }
        tasks[url] = t
        return await t.value
    }
}
