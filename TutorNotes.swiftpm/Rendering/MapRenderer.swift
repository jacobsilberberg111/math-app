import UIKit

/// Draws MapContent. STUB: replaced by the geo feature.
@MainActor
enum MapRenderer {
    static func draw(_ m: MapContent, rect: CGRect, progress: CGFloat, env: RenderEnvironment, ctx: CGContext) {
        ctx.setStrokeColor(UIColor.systemGray3.cgColor)
        ctx.stroke(rect)
    }

    /// One line (or a few) for the tutor's canvas state: what the map shows and how lon/lat map
    /// onto page coordinates, so it can annotate places precisely.
    static func tutorDescription(_ m: MapContent, frame: CGRect) -> String {
        "map: \(m.title ?? "untitled")"
    }
}
