import Foundation

/// A real-data map on the page (owned by the geography feature). Rendered by MapRenderer.
/// STUB: the geo feature replaces this with the full model.
struct MapContent: Codable, Equatable {
    var title: String?
    /// "Source: … (year)" caption for any real data shown.
    var source: String?
}
