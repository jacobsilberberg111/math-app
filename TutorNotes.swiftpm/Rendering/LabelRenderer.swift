import UIKit

/// Draws LabelSetContent.
@MainActor
enum LabelRenderer {
    static func draw(_ l: LabelSetContent, rect: CGRect, progress: CGFloat, env: RenderEnvironment, ctx: CGContext) {}

    static func tutorDescription(_ l: LabelSetContent, frame: CGRect) -> String {
        "\(l.labels.count) labels"
    }
}
