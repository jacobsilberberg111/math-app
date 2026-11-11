import UIKit

/// The `code` and `run_code` tools. STUB: replaced by the code feature.
extension CanvasActionExecutor {
    func codeTool(_ args: ToolArgs) async throws -> Outcome {
        throw ToolInputError(message: "Code blocks aren't available yet.")
    }

    func runCodeTool(_ args: ToolArgs) async throws -> Outcome {
        throw ToolInputError(message: "Running code isn't available yet.")
    }
}
