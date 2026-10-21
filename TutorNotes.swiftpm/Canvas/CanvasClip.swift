import UIKit

/// Selected ink and items packaged for the pasteboard, so they paste into other notes (and, as a
/// picture, into other apps).
struct CanvasClip: Codable {
    static let pasteboardType = "com.jacobsilberberg.margin.canvas-clip"

    /// The strokes as `PKDrawing.dataRepresentation()`, translated so the selection's top-left is the origin.
    var strokes: Data
    /// Items with frames relative to that origin (all on page 0).
    var elements: [CanvasElement]
    /// Bytes of the images the items use, keyed by asset id.
    var assets: [String: Data]
    var size: CGSize
}

extension CanvasClip {
    init?(data: Data) {
        guard let clip = try? PropertyListDecoder().decode(CanvasClip.self, from: data) else { return nil }
        self = clip
    }

    func encoded() -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(self)
    }

    /// Whether the pasteboard holds a clip, an image or text. These checks don't read the contents, so
    /// they don't trigger the system's paste prompt.
    static var pasteboardHasContent: Bool {
        let board = UIPasteboard.general
        return board.contains(pasteboardTypes: [pasteboardType]) || board.hasImages || board.hasStrings
    }

    /// Replaces the pasteboard with the clip, plus a PNG of it for other apps.
    @discardableResult
    func copyToPasteboard(picture: UIImage?) -> Bool {
        guard let data = encoded() else { return false }
        var item: [String: Any] = [CanvasClip.pasteboardType: data]
        if let png = picture?.pngData() { item["public.png"] = png }
        UIPasteboard.general.setItems([item], options: [:])
        return true
    }
}
