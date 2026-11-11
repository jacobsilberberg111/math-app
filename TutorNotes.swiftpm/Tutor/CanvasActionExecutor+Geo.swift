import UIKit

/// The `map`, `chart` and `climate_graph` tools. STUB: replaced by the geo feature.
extension CanvasActionExecutor {
    func mapTool(_ args: ToolArgs) async throws -> Outcome {
        throw ToolInputError(message: "Maps aren't available yet.")
    }

    func chartTool(_ args: ToolArgs) async throws -> Outcome {
        throw ToolInputError(message: "Charts aren't available yet.")
    }

    func climateGraphTool(_ args: ToolArgs) async throws -> Outcome {
        throw ToolInputError(message: "Climate graphs aren't available yet.")
    }
}
