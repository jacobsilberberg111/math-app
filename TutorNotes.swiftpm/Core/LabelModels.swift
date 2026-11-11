import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Labels with leader lines pointing at parts of a diagram, image or region of the page. In quiz
/// mode the label text is hidden behind numbered blanks for the student to fill in (the answers
/// are kept for marking), and printed labels on the picture can be covered up.
struct LabelSetContent: Codable, Equatable {
    var title: String?
    var labels: [DiagramLabel]
    /// Rectangles (relative to the element's frame) painted over printed labels on the picture.
    var covers: [CGRect] = []
    var quiz: Bool = false
    var colorHex: String = "#1F2328"
    var fontSize: CGFloat = 15
    /// The element (usually an image) the labels are about, if any.
    var targetElementID: String?
}

struct DiagramLabel: Codable, Equatable {
    var number: Int
    /// The label (in quiz mode, the hidden answer).
    var text: String
    /// The point on the diagram the leader line touches, relative to the element's frame.
    var anchor: CGPoint
    /// Where the label's box sits, relative to the element's frame.
    var box: CGRect
    /// Quiz labels the student has had revealed.
    var revealed: Bool = false
}
