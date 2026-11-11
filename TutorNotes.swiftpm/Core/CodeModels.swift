import Foundation

/// A code block on the page: typed code with its last run's output (owned by the computing
/// feature). Rendered by CodeRenderer.
/// STUB: the code feature replaces this with the full model.
struct CodeContent: Codable, Equatable {
    var language: String = "python"
    var code: String
    var output: String?
}
