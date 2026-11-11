import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A flowchart or process diagram: boxes joined by arrows, laid out automatically
/// (algorithms in computing, processes in science, cause and effect in history, essay plans).
struct FlowchartContent: Codable, Equatable {
    var title: String?
    var direction: FlowDirection = .down
    var nodes: [FlowNode]
    var edges: [FlowEdge]
    var colorHex: String = "#1F2328"
    var fontSize: CGFloat = 15
}

enum FlowDirection: String, Codable {
    /// Top to bottom (algorithms, processes).
    case down
    /// Left to right (timelines, chains).
    case right
    /// Around a circle, each stage leading to the next (water cycle, life cycles).
    case cycle
}

enum FlowShape: String, Codable, CaseIterable {
    /// Rounded box: a step.
    case process
    /// Diamond: a yes/no question.
    case decision
    /// Pill: start or end.
    case terminal
    /// Parallelogram: input or output.
    case io
    /// Plain text with no border, e.g. an annotation.
    case note
    /// Circle: a stage in a cycle.
    case circle
}

struct FlowNode: Codable, Equatable {
    var id: String
    var text: String
    var shape: FlowShape = .process
    var colorHex: String?
}

struct FlowEdge: Codable, Equatable {
    var from: String
    var to: String
    var label: String?
}
