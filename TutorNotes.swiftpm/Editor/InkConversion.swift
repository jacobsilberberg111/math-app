import SwiftUI
import UIKit

/// A conversion of lasso-selected handwriting to typed text or typeset math. It reads the ink
/// (text on-device, math with Claude), lets the student correct what it read, and then builds
/// the element that replaces the strokes. Shown as a sheet until the student confirms or cancels.
@MainActor
@Observable
final class InkConversion: Identifiable {
    enum Phase: Equatable {
        /// Maths is read by Claude, so it needs the tutor connection.
        case needsConnection
        case working
        case failed(String)
        case ready
    }

    let id = UUID()
    let kind: InkConversionKind
    let snapshot: LassoInkSnapshot
    private(set) var phase = Phase.working
    /// What was read: plain text, or LaTeX with one line per written line. The student edits it.
    var text = ""
    /// How many lines were read, which sets the new element's size from the height of the ink.
    private(set) var readLineCount = 1

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Changes whenever the reading starts over or is cancelled, so a late result can be told apart.
    @ObservationIgnored private var run = UUID()

    init(kind: InkConversionKind, snapshot: LassoInkSnapshot) {
        self.kind = kind
        self.snapshot = snapshot
    }

    var lines: [String] {
        text.split(separator: "\n").map { String($0).trimmed }.filter { !$0.isEmpty }
    }

    var canConvert: Bool { phase == .ready && !text.trimmed.isEmpty }

    // MARK: Reading

    /// Starts reading the ink (again, after a failure).
    func start() {
        task?.cancel()
        let run = UUID()
        self.run = run
        if kind == .math && !AppSettings.shared.isTutorConfigured {
            phase = .needsConnection
            return
        }
        phase = .working
        task = Task {
            do {
                let lines = try await self.read()
                guard self.run == run else { return }
                self.finish(with: lines)
            } catch is CancellationError {
                return
            } catch {
                guard self.run == run else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops reading and drops any result that is still on its way.
    func cancel() {
        task?.cancel()
        task = nil
        run = UUID()
    }

    private func read() async throws -> [String] {
        let image = snapshot.image
        switch kind {
        case .text:
            return try await Task.detached(priority: .userInitiated) { try InkTextRecognizer.recognize(image) }.value
        case .math:
            guard let png = InkConversion.pngForModel(image) else { return [] }
            return try await MathTranscriber.transcribe(png: png, client: AppSettings.shared.makeClient())
        }
    }

    private func finish(with found: [String]) {
        let lines = found.map(\.trimmed).filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            phase = .failed(kind == .text ? "No handwriting was recognised. Try selecting less, or writing a little larger."
                                          : "Couldn't read that as maths. Try selecting less, or writing a little larger.")
            return
        }
        readLineCount = lines.count
        text = lines.joined(separator: "\n")
        phase = .ready
    }

    /// The ink as PNG, downscaled when large (the model doesn't use more detail than this).
    private static func pngForModel(_ image: UIImage, maxSide: CGFloat = 1568) -> Data? {
        let longest = max(image.size.width, image.size.height) * image.scale
        guard longest > maxSide else { return image.pngData() }
        let k = maxSide / longest
        let size = CGSize(width: (image.size.width * image.scale * k).rounded(), height: (image.size.height * image.scale * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { rc in
            UIColor.white.setFill()
            rc.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return scaled.pngData()
    }

    // MARK: Result

    /// The LaTeX typeset as the finished element will show it, for checking before converting.
    func mathPreview(fontSize: CGFloat = 24) -> UIImage? {
        let lines = self.lines
        guard !lines.isEmpty else { return nil }
        let content = MathContent(lines: lines, fontSize: fontSize, colorHex: snapshot.colorHex)
        let size = ElementRenderer.measureMath(content)
        guard size.width > 0, size.height > 0 else { return nil }
        return UIGraphicsImageRenderer(size: size, format: .preferred()).image { rc in
            ElementRenderer.drawMath(content, rect: CGRect(origin: .zero, size: size), progress: 1, ctx: rc.cgContext)
        }
    }

    /// The student-authored element that takes the ink's place, where the ink was, in its colour
    /// and about its size. Nil when there is nothing to convert.
    func makeElement(in document: NoteDocument) -> CanvasElement? {
        let (page, ink) = document.pageRectFromDoc(snapshot.docBounds)
        let pageWidth = document.pageSize.width
        let lineHeight = ink.height / CGFloat(max(1, readLineCount))
        let content: ElementKind
        let size: CGSize
        switch kind {
        case .text:
            let body = text.trimmed
            guard !body.isEmpty else { return nil }
            let fontSize = min(44, max(14, (lineHeight * 0.85).rounded()))
            let typed = TextContent(text: body, style: .typed, fontSize: fontSize, colorHex: snapshot.colorHex, rich: false)
            // Typed text runs a little wider than handwriting; leave room so it doesn't wrap early.
            let width = min(max(ink.width * 1.25 + 16, 120), max(pageWidth - ink.minX - 8, 80))
            let height = ElementRenderer.measureText(typed, author: .student, width: width, env: PageRenderer.environment(for: document)).height
            content = .text(typed)
            size = CGSize(width: width, height: height)
        case .math:
            let lines = self.lines
            guard !lines.isEmpty else { return nil }
            var math = MathContent(lines: lines, fontSize: min(48, max(16, (lineHeight * 0.55).rounded())), colorHex: snapshot.colorHex)
            var measured = ElementRenderer.measureMath(math)
            // A long line shouldn't run off the page: step the size down until it fits.
            while measured.width > pageWidth - 16, math.fontSize > 16 {
                math.fontSize = max(16, math.fontSize - 2)
                measured = ElementRenderer.measureMath(math)
            }
            content = .math(math)
            size = measured
        }
        let origin = CGPoint(x: max(0, min(ink.minX, pageWidth - size.width - 8)), y: max(0, ink.minY))
        return CanvasElement(id: document.nextElementID(), pageIndex: page, frame: CGRect(origin: origin, size: size),
                             author: .student, kind: content)
    }
}

extension EditorModel {
    /// The lasso's "To Text" and "To Math" buttons: reads the selected handwriting and asks the
    /// student to confirm what it found before replacing the strokes.
    func canvasConvertLasso(_ kind: InkConversionKind) {
        guard let snapshot = canvas?.lassoInkSnapshot() else {
            flash("Select some handwriting first")
            return
        }
        inkConversion?.cancel()
        let conversion = InkConversion(kind: kind, snapshot: snapshot)
        inkConversion = conversion
        conversion.start()
    }

    func cancelInkConversion() {
        inkConversion?.cancel()
        inkConversion = nil
    }

    /// Swaps the selected ink for the converted element, as one undo step.
    func finishInkConversion(_ conversion: InkConversion) {
        guard inkConversion?.id == conversion.id, conversion.canConvert else { return }
        // The ink must still be the selected ink (the tutor or an undo may have changed it meanwhile).
        guard let canvas, canvas.lassoStrokes.map(\.path.creationDate) == conversion.snapshot.strokeDates else {
            inkConversion = nil
            flash("The handwriting changed. Select it again to convert it.")
            return
        }
        guard let element = conversion.makeElement(in: document) else { return }
        inkConversion = nil
        canvas.replaceLassoInk(with: element, actionName: conversion.kind == .text ? "Convert to Text" : "Convert to Math")
    }
}
