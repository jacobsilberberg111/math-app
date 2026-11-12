import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Decides whether a new finger touch belongs to the hand holding Apple Pencil (to be ignored)
/// or is a deliberate finger (to scroll, zoom or tap).
///
/// Earlier every finger that landed while the pencil was down, hovering, or a palm was resting
/// counted as the writing hand, so scrolling with the other hand stopped working whenever the
/// writing hand rested on the glass. Now the writing hand is located: a finger only counts as part
/// of it when it lands close to the pencil, its hover point or a resting palm, or when its contact
/// is palm-sized. A finger on the other side of the screen scrolls as normal.
enum PalmClassifier {
    /// Fingertips report a major radius of roughly 8–25 pt (more when pressed flat); a resting palm
    /// or the side of a hand is larger.
    static let palmContactRadius: CGFloat = 34
    /// How far (screen points) from the pencil or a resting palm the rest of the writing hand can
    /// land: the heel of the hand and the curled fingers sit within a few centimetres of the tip.
    static let handReach: CGFloat = 300

    struct Context {
        /// Where the pencil is touching the glass, if it is.
        var pencilPoints: [CGPoint] = []
        /// Where the pencil is hovering, if it is (or where it just lifted, during the grace period).
        var hoverPoint: CGPoint?
        /// Touches already taken as the writing hand.
        var palmPoints: [CGPoint] = []
        /// Within the short grace period after the pencil or the hand lifted.
        var inGrace = false
        /// Finger drawing is on: fingers are pens, so contact size says nothing.
        var fingerDrawing = false
    }

    static func isPalmSized(majorRadius: CGFloat, fingerDrawing: Bool) -> Bool {
        !fingerDrawing && majorRadius >= palmContactRadius
    }

    /// Whether a finger touch landing at `point` is part of the writing hand.
    static func isWritingHand(point: CGPoint, majorRadius: CGFloat, context c: Context) -> Bool {
        if isPalmSized(majorRadius: majorRadius, fingerDrawing: c.fingerDrawing) { return true }
        let anchors = c.pencilPoints + c.palmPoints + (c.hoverPoint.map { [$0] } ?? [])
        guard !anchors.isEmpty else {
            // The pencil just lifted but we don't know where: be cautious only during the grace.
            return c.inGrace && !c.fingerDrawing
        }
        // With finger drawing on, only an actual pencil nearby makes a finger part of the hand.
        if c.fingerDrawing && c.pencilPoints.isEmpty && c.hoverPoint == nil { return false }
        return anchors.contains { hypot($0.x - point.x, $0.y - point.y) <= handReach }
    }
}
