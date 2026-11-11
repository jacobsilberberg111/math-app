import Foundation

/// A data chart on the page: bar, line, scatter, pie or climate graph (owned by the geography
/// feature, also used by science). Rendered by ChartRenderer.
/// STUB: the geo feature replaces this with the full model.
struct ChartContent: Codable, Equatable {
    var title: String?
    var source: String?
}
