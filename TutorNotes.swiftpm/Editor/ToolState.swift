import SwiftUI

/// The pen box: current tool, favourite colours and widths per tool. Persisted across launches.
@MainActor
@Observable
final class ToolState {
    var kind: CanvasToolKind = .pen { didSet { if oldValue != kind, kind != .tutor { lastDrawingKind = kind }; save() } }
    var penStyle: PenStyle = .ballpoint { didSet { save() } }
    var penColors: [String] = ["#1F2328", "#1C64F2", "#E03131", "#2F9E44", "#7048E8"] { didSet { save() } }
    var penColorIndex = 0 { didSet { save() } }
    var penWidths: [CGFloat] = [1.8, 3.2, 6] { didSet { save() } }
    var penWidthIndex = 1 { didSet { save() } }
    var highlighterColors: [String] = ["#FFE066", "#8CE99A", "#74C0FC", "#FFA8A8", "#D0BFFF"] { didSet { save() } }
    var highlighterColorIndex = 0 { didSet { save() } }
    var highlighterWidths: [CGFloat] = [10, 18, 28] { didSet { save() } }
    var highlighterWidthIndex = 1 { didSet { save() } }
    var eraserMode: EraserMode = .stroke { didSet { save() } }
    var eraserWidth: CGFloat = 20 { didSet { save() } }
    var rulerActive = false
    @ObservationIgnored var lastDrawingKind: CanvasToolKind = .pen
    @ObservationIgnored private var loading = false

    private struct Stored: Codable {
        var kind: CanvasToolKind
        var penStyle: PenStyle
        var penColors: [String]
        var penColorIndex: Int
        var penWidths: [CGFloat]
        var penWidthIndex: Int
        var highlighterColors: [String]
        var highlighterColorIndex: Int
        var highlighterWidths: [CGFloat]
        var highlighterWidthIndex: Int
        var eraserMode: EraserMode
        var eraserWidth: CGFloat
    }

    init() {
        loading = true
        if let data = UserDefaults.standard.data(forKey: "toolState"), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            kind = s.kind == .tutor || s.kind == .select ? .pen : s.kind
            penStyle = s.penStyle
            penColors = s.penColors
            penColorIndex = min(s.penColorIndex, s.penColors.count - 1)
            penWidths = s.penWidths
            penWidthIndex = min(s.penWidthIndex, s.penWidths.count - 1)
            highlighterColors = s.highlighterColors
            highlighterColorIndex = min(s.highlighterColorIndex, s.highlighterColors.count - 1)
            highlighterWidths = s.highlighterWidths
            highlighterWidthIndex = min(s.highlighterWidthIndex, s.highlighterWidths.count - 1)
            eraserMode = s.eraserMode
            eraserWidth = s.eraserWidth
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let s = Stored(kind: kind, penStyle: penStyle, penColors: penColors, penColorIndex: penColorIndex, penWidths: penWidths,
                       penWidthIndex: penWidthIndex, highlighterColors: highlighterColors, highlighterColorIndex: highlighterColorIndex,
                       highlighterWidths: highlighterWidths, highlighterWidthIndex: highlighterWidthIndex, eraserMode: eraserMode,
                       eraserWidth: eraserWidth)
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: "toolState") }
    }

    // MARK: Current values

    var colors: [String] {
        get { kind == .highlighter ? highlighterColors : penColors }
    }

    var colorIndex: Int { kind == .highlighter ? highlighterColorIndex : penColorIndex }

    func selectColor(_ i: Int) {
        if kind == .highlighter { highlighterColorIndex = i } else { penColorIndex = i }
    }

    func setColor(_ hex: String, at i: Int) {
        if kind == .highlighter {
            guard highlighterColors.indices.contains(i) else { return }
            highlighterColors[i] = hex
        } else {
            guard penColors.indices.contains(i) else { return }
            penColors[i] = hex
        }
    }

    var widths: [CGFloat] { kind == .highlighter ? highlighterWidths : penWidths }
    var widthIndex: Int { kind == .highlighter ? highlighterWidthIndex : penWidthIndex }

    func selectWidth(_ i: Int) {
        if kind == .highlighter { highlighterWidthIndex = i } else { penWidthIndex = i }
    }

    func setWidth(_ w: CGFloat, at i: Int) {
        if kind == .highlighter {
            guard highlighterWidths.indices.contains(i) else { return }
            highlighterWidths[i] = w
        } else {
            guard penWidths.indices.contains(i) else { return }
            penWidths[i] = w
        }
    }

    var showsColorAndWidth: Bool { kind == .pen || kind == .highlighter || kind == .text }

    func config(settings: AppSettings) -> CanvasToolConfig {
        var c = CanvasToolConfig()
        c.kind = kind
        c.penStyle = penStyle
        c.penColorHex = penColors[safe: penColorIndex] ?? "#1F2328"
        c.penWidth = penWidths[safe: penWidthIndex] ?? 3
        c.highlighterColorHex = highlighterColors[safe: highlighterColorIndex] ?? "#FFE066"
        c.highlighterWidth = highlighterWidths[safe: highlighterWidthIndex] ?? 18
        c.eraserMode = eraserMode
        c.eraserWidth = eraserWidth
        c.shapeRecognition = settings.shapeRecognition
        c.fingerDrawing = settings.fingerDrawing
        c.rulerActive = rulerActive
        c.hoverPreview = settings.hoverPreview
        c.gestureUndo = settings.gestureUndo
        return c
    }
}
