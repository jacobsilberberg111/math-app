import UIKit

/// The `flowchart`, `label_diagram` and `find_diagram` tools.
extension CanvasActionExecutor {
    func flowchartTool(_ args: ToolArgs) throws -> Outcome {
        throw ToolInputError(message: "Flowcharts aren't available yet.")
    }

    func labelDiagramTool(_ args: ToolArgs) throws -> Outcome {
        throw ToolInputError(message: "Labelling isn't available yet.")
    }

    func findDiagramTool(_ args: ToolArgs) async throws -> Outcome {
        throw ToolInputError(message: "Finding diagrams isn't available yet.")
    }
}
