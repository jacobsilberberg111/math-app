import UIKit

/// Draws FlowchartContent.
@MainActor
enum FlowchartRenderer {
    static func draw(_ f: FlowchartContent, rect: CGRect, progress: CGFloat, env: RenderEnvironment, ctx: CGContext) {}

    static func tutorDescription(_ f: FlowchartContent, frame: CGRect) -> String {
        "\(f.nodes.count) boxes"
    }
}
