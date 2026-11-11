import UIKit

/// Draws ChartContent. STUB: replaced by the geo feature.
@MainActor
enum ChartRenderer {
    static func draw(_ c: ChartContent, rect: CGRect, progress: CGFloat, env: RenderEnvironment, ctx: CGContext) {
        ctx.setStrokeColor(UIColor.systemGray3.cgColor)
        ctx.stroke(rect)
    }

    static func tutorDescription(_ c: ChartContent, frame: CGRect) -> String {
        "chart: \(c.title ?? "untitled")"
    }
}
