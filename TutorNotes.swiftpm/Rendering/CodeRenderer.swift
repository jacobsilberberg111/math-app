import UIKit

/// Draws CodeContent. STUB: replaced by the code feature.
@MainActor
enum CodeRenderer {
    static func draw(_ c: CodeContent, rect: CGRect, progress: CGFloat, env: RenderEnvironment, ctx: CGContext) {
        ctx.setStrokeColor(UIColor.systemGray3.cgColor)
        ctx.stroke(rect)
    }

    /// The block's natural size at a given width (code lines plus the output panel).
    static func size(for c: CodeContent, width: CGFloat) -> CGSize {
        CGSize(width: width, height: 120)
    }

    static func tutorDescription(_ c: CodeContent, frame: CGRect) -> String {
        "code block (\(c.language))"
    }
}
