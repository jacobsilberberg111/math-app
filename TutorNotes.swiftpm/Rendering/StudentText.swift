import UIKit

/// The student's formatted text boxes: stored as an archived NSAttributedString in
/// `TextContent.attributed`, edited natively in a UITextView, and drawn exactly as edited.
enum StudentText {
    private static let cache = NSCache<NSData, NSAttributedString>()

    static func archive(_ s: NSAttributedString) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: s, requiringSecureCoding: true)
    }

    static func unarchive(_ data: Data) -> NSAttributedString? {
        if let hit = cache.object(forKey: data as NSData) { return hit }
        guard let s = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSAttributedString.self, NSParagraphStyle.self, UIFont.self, UIColor.self, NSNumber.self, NSString.self, NSDictionary.self, NSArray.self], from: data) as? NSAttributedString else { return nil }
        cache.setObject(s, forKey: data as NSData)
        return s
    }

    /// The formatted text, or the plain text in the box's font and colour for older notes.
    static func attributedString(_ t: TextContent) -> NSAttributedString {
        if let data = t.attributed, let s = unarchive(data) { return s }
        return NSAttributedString(string: t.text, attributes: baseAttributes(style: t.style, size: t.fontSize, colorHex: t.colorHex))
    }

    /// The font a box style starts with: headings are bold and larger.
    static func font(style: TextStyle, size: CGFloat) -> UIFont {
        style == .heading ? UIFont.systemFont(ofSize: size * 1.4, weight: .bold) : UIFont.systemFont(ofSize: size)
    }

    static func baseAttributes(style: TextStyle, size: CGFloat, colorHex: String) -> [NSAttributedString.Key: Any] {
        [.font: font(style: style, size: size), .foregroundColor: UIColor(hex: colorHex)]
    }

    static func size(_ s: NSAttributedString, width: CGFloat) -> CGSize {
        let text = s.length == 0 ? NSAttributedString(string: " ", attributes: [.font: UIFont.systemFont(ofSize: 18)]) : s
        let r = text.boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    static func draw(_ s: NSAttributedString, in rect: CGRect, ctx: CGContext) {
        UIGraphicsPushContext(ctx)
        s.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        UIGraphicsPopContext()
    }

    /// Every font scaled by `k` (resizing a box with the lasso or a handle).
    static func scaled(_ t: TextContent, by k: CGFloat) -> TextContent {
        var out = t
        out.fontSize = max(6, min(240, t.fontSize * k))
        guard let data = t.attributed, let s = unarchive(data) else { return out }
        let m = NSMutableAttributedString(attributedString: s)
        m.enumerateAttribute(.font, in: NSRange(location: 0, length: m.length)) { value, range, _ in
            guard let f = value as? UIFont else { return }
            m.addAttribute(.font, value: f.withSize(max(6, min(240, f.pointSize * k))), range: range)
        }
        out.attributed = archive(m)
        return out
    }

    /// The whole box in one colour (the lasso's recolour).
    static func recolored(_ t: TextContent, hex: String) -> TextContent {
        var out = t
        out.colorHex = hex
        guard let data = t.attributed, let s = unarchive(data) else { return out }
        let m = NSMutableAttributedString(attributedString: s)
        m.addAttribute(.foregroundColor, value: UIColor(hex: hex), range: NSRange(location: 0, length: m.length))
        out.attributed = archive(m)
        return out
    }

    /// The first font and colour in the text, for the box's summary fields.
    static func leading(_ s: NSAttributedString) -> (size: CGFloat, colorHex: String)? {
        guard s.length > 0 else { return nil }
        let a = s.attributes(at: 0, effectiveRange: nil)
        let size = (a[.font] as? UIFont)?.pointSize ?? 18
        let color = (a[.foregroundColor] as? UIColor)?.hexString ?? "#1F2328"
        return (size, color)
    }
}
