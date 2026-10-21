import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Library

struct NoteMeta: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var subjectID: UUID?
    var createdAt: Date
    var modifiedAt: Date
    var pageCount: Int
    /// Text recognised from handwriting + typed text, used by library search.
    var searchText: String?
    var hasAudio: Bool
    var hasTutorSession: Bool
    var paper: PaperStyle?
    // Added after v1; optional so older meta.json files still decode.
    var layout: NoteLayout?
    var lastOpenedAt: Date?
    /// Question cards still waiting for an answer, counted when the note was last saved.
    var openQuestions: Int?

    init(id: UUID = UUID(), title: String, subjectID: UUID? = nil, paper: PaperStyle? = nil) {
        self.id = id
        self.title = title
        self.subjectID = subjectID
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.pageCount = 1
        self.searchText = nil
        self.hasAudio = false
        self.hasTutorSession = false
        self.paper = paper
    }

    var isFreeform: Bool { layout == .freeform }

    /// When the note was last opened or edited, whichever is later (for "recent" lists).
    var lastActivity: Date { max(lastOpenedAt ?? .distantPast, modifiedAt) }
}

/// A note is either a stack of pages or a freeform board: one large sheet with no page breaks
/// that grows as you write.
enum NoteLayout: String, Codable {
    case pages, freeform
}

struct Subject: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var colorHex: String

    static let palette = ["#5B5BD6", "#E5484D", "#30A46C", "#F76B15", "#0090FF", "#8E4EC6", "#D6409F", "#12A594"]
}

// MARK: - Paper

enum PaperPattern: String, Codable, CaseIterable, Identifiable {
    case blank, ruled, narrowRuled, grid, smallGrid, dots, cornell, graph

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: return "Blank"
        case .ruled: return "College Ruled"
        case .narrowRuled: return "Narrow Ruled"
        case .grid: return "Grid"
        case .smallGrid: return "Small Grid"
        case .dots: return "Dotted"
        case .cornell: return "Cornell"
        case .graph: return "Graph Paper"
        }
    }

    /// Backgrounds that make sense on a freeform board (Cornell needs page edges).
    static let boardPatterns: [PaperPattern] = [.blank, .ruled, .narrowRuled, .grid, .smallGrid, .dots, .graph]

    var symbol: String {
        switch self {
        case .blank: return "square"
        case .ruled, .narrowRuled, .cornell: return "line.3.horizontal"
        case .grid, .smallGrid, .graph: return "squareshape.split.3x3"
        case .dots: return "circle.grid.3x3"
        }
    }
}

enum PaperColor: String, Codable, CaseIterable, Identifiable {
    case white, ivory, sky, mint, blush, charcoal

    var id: String { rawValue }

    var hex: String {
        switch self {
        case .white: return "#FFFFFF"
        case .ivory: return "#FBF7EC"
        case .sky: return "#F1F6FD"
        case .mint: return "#F0F8F3"
        case .blush: return "#FCF2F2"
        case .charcoal: return "#26272B"
        }
    }

    var lineHex: String {
        switch self {
        case .charcoal: return "#44464D"
        case .ivory: return "#E3D9C0"
        default: return "#D4DCE8"
        }
    }

    var isDark: Bool { self == .charcoal }
}

struct PaperStyle: Codable, Equatable, Hashable {
    var pattern: PaperPattern
    var color: PaperColor

    static let standard = PaperStyle(pattern: .ruled, color: .white)
}

struct PageSize: Codable, Equatable, Hashable {
    var width: CGFloat
    var height: CGFloat

    static let letter = PageSize(width: 816, height: 1056)
    static let a4 = PageSize(width: 816, height: 1154)
}

struct Page: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var paper: PaperStyle
    /// Background from an imported PDF (asset id + page index).
    var pdfAssetID: String?
    var pdfPageIndex: Int?
}

// MARK: - Note content

enum Author: String, Codable {
    case student, tutor
}

struct NoteContent: Codable {
    var version: Int = 1
    /// nil for notes made before freeform boards existed (they are all pages).
    var layout: NoteLayout?
    /// For a freeform board this is the board's size; it grows as content nears the edge.
    var pageSize: PageSize = .letter
    var pages: [Page] = [Page(paper: .standard)]
    var elements: [CanvasElement] = []
    var attachments: [TutorAttachment] = []
    var recordings: [AudioRecording] = []
    var nextElementNumber: Int = 1
    var nextQuestionNumber: Int = 1
}

struct CanvasElement: Codable, Identifiable, Equatable {
    /// Short, model-friendly id like "e12".
    var id: String
    var pageIndex: Int
    /// Frame in page coordinates (points, origin top-left of the page).
    var frame: CGRect
    var author: Author
    var createdAt: Date = Date()
    var kind: ElementKind

    var isTutor: Bool { author == .tutor }

    /// Whether the element sits under the student's ink (graphs, images, question cards) or
    /// on top of it (tutor writing and marks).
    var drawsAboveInk: Bool {
        switch kind {
        case .ink, .text: return true
        case .math: return author == .tutor
        default: return false
        }
    }
}

enum ElementKind: Codable, Equatable {
    case text(TextContent)
    case math(MathContent)
    case ink(InkContent)
    case graph(GraphContent)
    case numberLine(NumberLineContent)
    case table(TableContent)
    case question(QuestionContent)
    case image(ImageContent)

    var typeName: String {
        switch self {
        case .text: return "text"
        case .math: return "math"
        case .ink: return "ink"
        case .graph: return "graph"
        case .numberLine: return "number_line"
        case .table: return "table"
        case .question: return "question"
        case .image: return "image"
        }
    }
}

enum TextStyle: String, Codable, CaseIterable {
    case handwriting, typed, heading, note, sticky
}

struct TextContent: Codable, Equatable {
    var text: String
    var style: TextStyle
    var fontSize: CGFloat
    var colorHex: String
    /// Tutor text understands `$math$` and `**bold**`; student text is literal.
    var rich: Bool
}

struct MathContent: Codable, Equatable {
    /// One LaTeX expression per line; lines are aligned on their first relation (=, <, ≤ ...).
    var lines: [String]
    var fontSize: CGFloat
    var colorHex: String
    var alignRelations: Bool = true
}

struct InkStroke: Codable, Equatable {
    var points: [CGPoint]
    var closed: Bool = false
}

enum InkPurpose: String, Codable {
    case freehand, circle, underline, box, arrow, highlight, strike, tick, cross, partial, bracket, question, star
}

struct InkContent: Codable, Equatable {
    /// Points are relative to the element's frame origin.
    var strokes: [InkStroke]
    var colorHex: String
    var width: CGFloat
    var opacity: CGFloat = 1
    var purpose: InkPurpose = .freehand
    /// Optional handwritten-style label placed next to the mark.
    var label: String?
    var labelOffset: CGPoint?
}

struct GraphFunction: Codable, Equatable {
    var expression: String
    var label: String?
    var colorHex: String
    var dashed: Bool = false
    var domainMin: Double?
    var domainMax: Double?
}

struct GraphPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var label: String?
    var colorHex: String
    var open: Bool = false
}

struct GraphSegment: Codable, Equatable {
    var x1: Double, y1: Double, x2: Double, y2: Double
    var colorHex: String
    var dashed: Bool = false
    var arrow: Bool = false
    var label: String?
}

/// x = value (vertical) or y = value (horizontal) reference line, e.g. an asymptote.
struct GraphGuideLine: Codable, Equatable {
    var x: Double?
    var y: Double?
    var colorHex: String
    var dashed: Bool = true
    var label: String?
}

struct GraphShading: Codable, Equatable {
    /// Region between `upper` and `lower` (expressions; nil means the x-axis) for x in from...to.
    var upper: String?
    var lower: String?
    var from: Double
    var to: Double
    var colorHex: String
}

struct GraphContent: Codable, Equatable {
    var xMin: Double = -10
    var xMax: Double = 10
    var yMin: Double = -10
    var yMax: Double = 10
    var xStep: Double?
    var yStep: Double?
    var showGrid: Bool = true
    var showNumbers: Bool = true
    var xLabel: String = "x"
    var yLabel: String = "y"
    var title: String?
    var functions: [GraphFunction] = []
    var points: [GraphPoint] = []
    var segments: [GraphSegment] = []
    var guides: [GraphGuideLine] = []
    var shadings: [GraphShading] = []
}

struct NumberLinePoint: Codable, Equatable {
    var value: Double
    var label: String?
    var open: Bool = false
    var colorHex: String
}

struct NumberLineInterval: Codable, Equatable {
    var from: Double?   // nil = extends to -∞
    var to: Double?     // nil = extends to +∞
    var openStart: Bool
    var openEnd: Bool
    var colorHex: String
}

struct NumberLineContent: Codable, Equatable {
    var min: Double
    var max: Double
    var step: Double
    var labelEvery: Int = 1
    var points: [NumberLinePoint] = []
    var intervals: [NumberLineInterval] = []
    var colorHex: String = "#1F2328"
}

struct TableContent: Codable, Equatable {
    var rows: [[String]]
    var header: Bool
    var fontSize: CGFloat = 17
    var colorHex: String = "#1F2328"
}

enum QuestionStatus: String, Codable {
    case open, correct, incorrect, partial
}

struct QuestionContent: Codable, Equatable {
    var number: Int
    var prompt: String
    var marks: Int
    /// Height of the prompt block at layout time; the answer area is the rest of the frame.
    var promptHeight: CGFloat
    var answer: String
    var solution: String
    var hint: String?
    var topic: String?
    var difficulty: String?
    var status: QuestionStatus = .open
    var score: String?
    var feedback: String?
    var revealedHint: Bool = false
    var revealedSolution: Bool = false
}

struct ImageContent: Codable, Equatable {
    var assetID: String
}

// MARK: - Attachments & audio

enum AttachmentKind: String, Codable {
    case pdf, image, text
}

struct TutorAttachment: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var kind: AttachmentKind
    var mimeType: String
    var localFile: String
    var sizeBytes: Int
    var addedAt: Date = Date()
    /// Anthropic Files API id once uploaded.
    var remoteFileID: String?
}

struct AudioRecording: Codable, Identifiable, Equatable {
    var id: String
    var fileName: String
    var startedAt: Date
    var duration: TimeInterval
}

// MARK: - Geometry helpers

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    func inset(by amount: CGFloat) -> CGRect { insetBy(dx: amount, dy: amount) }

    func overlapFraction(with other: CGRect) -> CGFloat {
        let i = intersection(other)
        guard !i.isNull, width > 0, height > 0 else { return 0 }
        return (i.width * i.height) / (width * height)
    }

    var roundedForDisplay: String {
        "x\(Int(minX.rounded())) y\(Int(minY.rounded())) w\(Int(width.rounded())) h\(Int(height.rounded()))"
    }
}
