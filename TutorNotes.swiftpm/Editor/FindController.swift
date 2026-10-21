import SwiftUI

/// Find in note: searches typed text at once and handwriting as Vision reads it (page by page,
/// cached), and tells the canvas what to highlight.
@MainActor
@Observable
final class FindController {
    /// One hit, in document coordinates.
    struct Match: Equatable {
        var page: Int
        /// Top of the line or element it's on, so matches on one line sort left to right.
        var sortY: CGFloat
        var rect: CGRect
    }

    /// What a typed element can be found by.
    private struct TypedEntry {
        var page: Int
        var rect: CGRect
        var text: String
    }

    /// What was read from a region's ink, valid while its signature is unchanged.
    private struct Reading {
        var signature: Int
        var lines: [RecognisedLine]
    }

    /// Case- and diacritic-insensitive.
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    let document: NoteDocument
    @ObservationIgnored weak var canvas: NoteCanvasViewController?

    private(set) var isOpen = false
    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    private(set) var matches: [Match] = []
    private(set) var currentIndex: Int?
    /// Handwriting is still being read.
    private(set) var isReading = false
    /// Bumped to put the cursor back in the search field.
    private(set) var focusTick = 0

    @ObservationIgnored private var typed: [TypedEntry] = []
    @ObservationIgnored private var typedRevision = -1
    @ObservationIgnored private var readings: [InkRegion.Key: Reading] = [:]
    /// The regions with ink as of `readRevision`; only these are searched.
    @ObservationIgnored private var regions: [InkRegion] = []
    @ObservationIgnored private var readRevision = -1
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?

    init(document: NoteDocument) {
        self.document = document
    }

    var current: Match? { currentIndex.flatMap { matches[safe: $0] } }

    // MARK: Opening and closing

    func open() {
        focusTick += 1
        guard !isOpen else { return }
        withAnimation(.easeOut(duration: 0.18)) { isOpen = true }
        startReading()
    }

    func close() {
        guard isOpen else { return }
        searchTask?.cancel()
        searchTask = nil
        readTask?.cancel()
        readTask = nil
        withAnimation(.easeOut(duration: 0.18)) { isOpen = false }
        isReading = false
        query = ""
        matches = []
        currentIndex = nil
        canvas?.clearFindHighlights()
    }

    // MARK: Navigation

    func next() { step(1) }

    func previous() { step(-1) }

    private func step(_ delta: Int) {
        // Return can arrive before the debounce does: search for what's typed first.
        if searchTask != nil {
            searchTask?.cancel()
            searchTask = nil
            refresh()
        }
        guard !matches.isEmpty else { return }
        currentIndex = ((currentIndex ?? 0) + delta + matches.count) % matches.count
        showHighlights()
        if let match = current { reveal(match) }
    }

    private func reveal(_ match: Match) {
        canvas?.scrollToReveal(match.rect.insetBy(dx: -20, dy: -20))
    }

    private func showHighlights() {
        canvas?.showFindHighlights(matches.map(\.rect), current: currentIndex)
    }

    // MARK: Searching

    /// The note changed while the bar is open (typing, writing, the tutor).
    func documentChanged() {
        guard isOpen else { return }
        scheduleRefresh()
    }

    private func queryChanged() {
        guard isOpen else { return }
        if normalizedQuery.isEmpty {
            searchTask?.cancel()
            searchTask = nil
            recompute()
        } else {
            scheduleRefresh()
        }
    }

    private func scheduleRefresh() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            self.searchTask = nil
            self.refresh()
        }
    }

    private func refresh() {
        if readRevision != document.revision { startReading(afterQuietFor: 600_000_000) }
        recompute()
    }

    private var normalizedQuery: String {
        query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Searches everything read so far. The current match stays put if it's still a match;
    /// otherwise the first match on or after the visible area becomes current.
    private func recompute() {
        let q = normalizedQuery
        var found: [Match] = []
        if isOpen, !q.isEmpty {
            found = typedMatches(for: q) + inkMatches(for: q)
            found.sort(by: FindController.inReadingOrder)
        }
        let before = current
        matches = found
        if let before, let i = found.firstIndex(of: before) {
            currentIndex = i
        } else {
            currentIndex = found.isEmpty ? nil : firstIndexOnOrAfterView(in: found)
        }
        showHighlights()
        if let now = current, now != before { reveal(now) }
    }

    private func firstIndexOnOrAfterView(in found: [Match]) -> Int {
        guard let top = canvas?.visibleDocRect.minY else { return 0 }
        return found.firstIndex { $0.rect.maxY >= top } ?? 0
    }

    /// Page, then top to bottom, then left to right.
    private static func inReadingOrder(_ a: Match, _ b: Match) -> Bool {
        if a.page != b.page { return a.page < b.page }
        if a.sortY != b.sortY { return a.sortY < b.sortY }
        return a.rect.minX < b.rect.minX
    }

    // MARK: Typed text

    /// An element containing the query is one match, and highlights its whole frame.
    private func typedMatches(for q: String) -> [Match] {
        refreshTyped()
        return typed.compactMap { entry in
            guard entry.text.range(of: q, options: FindController.options) != nil else { return nil }
            return Match(page: entry.page, sortY: entry.rect.minY, rect: entry.rect)
        }
    }

    private func refreshTyped() {
        guard typedRevision != document.revision else { return }
        typedRevision = document.revision
        typed = document.content.elements.compactMap { e in
            guard let text = FindController.searchText(of: e), !text.isEmpty else { return nil }
            return TypedEntry(page: e.pageIndex, rect: document.docRect(for: e), text: text)
        }
    }

    private static func searchText(of e: CanvasElement) -> String? {
        switch e.kind {
        case .text(let t): return t.rich ? RichTextParser.plainText(t.text) : t.text
        case .question(let q): return RichTextParser.plainText(q.prompt)
        case .table(let t): return t.rows.flatMap { $0 }.map(RichTextParser.plainText).joined(separator: "\n")
        default: return nil
        }
    }

    // MARK: Handwriting

    /// Every occurrence in a recognised line is a match, highlighting the words it covers.
    private func inkMatches(for q: String) -> [Match] {
        var out: [Match] = []
        for region in regions {
            guard let reading = readings[region.key] else { continue }
            for line in reading.lines {
                let text = line.text
                var from = text.startIndex
                while from < text.endIndex, let r = text.range(of: q, options: FindController.options, range: from..<text.endIndex) {
                    let lo = text.distance(from: text.startIndex, to: r.lowerBound)
                    let hi = text.distance(from: text.startIndex, to: r.upperBound)
                    out.append(Match(page: region.page, sortY: line.rect.minY, rect: line.box(covering: lo..<hi)))
                    from = r.upperBound
                }
            }
        }
        return out
    }

    /// Reads the regions whose ink changed since they were last read, nearest the screen first.
    /// Each result is searched as soon as it lands. A pass after an edit waits for a pause in the
    /// writing before it starts.
    private func startReading(afterQuietFor delay: UInt64 = 0) {
        readRevision = document.revision
        let fresh = HandwritingReader.regions(for: document, near: canvas?.visibleDocRect.center ?? .zero)
        // Edits that left the ink alone (typing, the tutor) mustn't restart a pass under way.
        let sameInk = fresh.count == regions.count && fresh.allSatisfy { r in
            regions.contains { $0.key == r.key && $0.signature == r.signature }
        }
        regions = fresh
        if sameInk && isReading { return }
        readTask?.cancel()
        let pending = regions.filter { readings[$0.key]?.signature != $0.signature }
        guard !pending.isEmpty else {
            isReading = false
            return
        }
        isReading = true
        readTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            for region in pending {
                guard let self, !Task.isCancelled else { return }
                if self.readings[region.key]?.signature == region.signature { continue }
                var lines: [RecognisedLine] = []
                if let image = HandwritingReader.image(of: region, in: self.document) {
                    let rect = region.rect
                    lines = await Task.detached(priority: .userInitiated) {
                        HandwritingReader.recognize(image, in: rect)
                    }.value
                }
                // Keep the reading even if this pass was cancelled meanwhile: it's still right
                // for the ink it was made from.
                self.readings[region.key] = Reading(signature: region.signature, lines: lines)
                guard !Task.isCancelled else { return }
                self.recompute()
            }
            self?.isReading = false
        }
    }
}
