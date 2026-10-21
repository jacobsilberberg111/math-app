import UIKit
import PencilKit

enum CanvasToolKind: String, CaseIterable, Identifiable, Codable {
    case pen, highlighter, eraser, lasso, text, select, tutor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .eraser: return "Eraser"
        case .lasso: return "Lasso"
        case .text: return "Text"
        case .select: return "Select"
        case .tutor: return "Ask Tutor"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        case .text: return "textformat"
        case .select: return "hand.point.up.left"
        case .tutor: return "sparkles.rectangle.stack"
        }
    }

    var usesPencilKit: Bool {
        switch self {
        case .pen, .highlighter, .eraser: return true
        default: return false
        }
    }
}

enum PenStyle: String, CaseIterable, Identifiable, Codable {
    case ballpoint, fountain, pencil, monoline, crayon, watercolor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ballpoint: return "Ballpoint"
        case .fountain: return "Fountain Pen"
        case .pencil: return "Pencil"
        case .monoline: return "Monoline"
        case .crayon: return "Crayon"
        case .watercolor: return "Watercolor"
        }
    }

    var symbol: String {
        switch self {
        case .ballpoint: return "pencil.tip"
        case .fountain: return "pencil.and.scribble"
        case .pencil: return "pencil"
        case .monoline: return "line.diagonal"
        case .crayon: return "paintbrush.pointed"
        case .watercolor: return "paintbrush"
        }
    }

    var inkType: PKInkingTool.InkType {
        switch self {
        case .ballpoint: return .pen
        case .fountain: return .fountainPen
        case .pencil: return .pencil
        case .monoline: return .monoline
        case .crayon: return .crayon
        case .watercolor: return .watercolor
        }
    }
}

enum EraserMode: String, Codable, CaseIterable {
    case stroke, pixel
}

/// A value snapshot of the current tool, passed from SwiftUI into the canvas.
struct CanvasToolConfig: Equatable {
    var kind: CanvasToolKind = .pen
    var penStyle: PenStyle = .ballpoint
    var penColorHex: String = "#1F2328"
    var penWidth: CGFloat = 3
    var highlighterColorHex: String = "#FFE066"
    var highlighterWidth: CGFloat = 18
    var eraserMode: EraserMode = .stroke
    var eraserWidth: CGFloat = 20
    var shapeRecognition = true
    var fingerDrawing = false
    var rulerActive = false
    var hoverPreview = true
    var gestureUndo = true

    var inkColorHex: String { kind == .highlighter ? highlighterColorHex : penColorHex }
    var inkWidth: CGFloat { kind == .highlighter ? highlighterWidth : penWidth }

    func pkTool() -> PKTool {
        switch kind {
        case .pen:
            return PKInkingTool(penStyle.inkType, color: UIColor(hex: penColorHex), width: penWidth)
        case .highlighter:
            return PKInkingTool(.marker, color: UIColor(hex: highlighterColorHex), width: highlighterWidth)
        case .eraser:
            return eraserMode == .stroke ? PKEraserTool(.vector) : PKEraserTool(.bitmap, width: eraserWidth)
        default:
            return PKInkingTool(penStyle.inkType, color: UIColor(hex: penColorHex), width: penWidth)
        }
    }
}

enum ElementAction {
    case askTutor, explain, delete, duplicate, edit, revealHint, revealSolution, checkAnswer
}

/// What the lasso's "To Text" and "To Math" buttons turn the selected handwriting into.
enum InkConversionKind {
    case text, math
}

/// Callbacks from the canvas to the editor.
@MainActor
protocol CanvasHost: AnyObject {
    func canvasVisiblePageChanged(_ page: Int)
    func canvasStudentWrote(docRects: [CGRect])
    func canvasPencilStateChanged(isDrawing: Bool)
    func canvasRegionSelected(page: Int, rect: CGRect, anchor: CGRect)
    func canvasTutorMenuRequested(docPoint: CGPoint, anchor: CGRect)
    func canvasElementAction(_ action: ElementAction, element: CanvasElement)
    func canvasRequestTool(_ kind: CanvasToolKind?)
    func canvasRequestPalette(anchor: CGRect)
    func canvasUndoStateChanged()
    func canvasSelectionChanged(_ element: CanvasElement?)
    func canvasConvertLasso(_ kind: InkConversionKind)
    func canvasReplayTapped(at docPoint: CGPoint)
    func canvasShapeSnapped(_ name: String)
    func canvasOffscreenTutorEdit(page: Int, docRect: CGRect)
}
