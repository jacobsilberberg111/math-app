import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r, g, b, a: CGFloat
        switch s.count {
        case 8:
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        case 6:
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        case 3:
            r = CGFloat((value >> 8) & 0xF) / 15
            g = CGFloat((value >> 4) & 0xF) / 15
            b = CGFloat(value & 0xF) / 15
            a = 1
        default:
            r = 0; g = 0; b = 0; a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let resolved = resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int((r * 255).rounded()), gi = Int((g * 255).rounded()), bi = Int((b * 255).rounded())
        if a < 0.999 {
            return String(format: "#%02X%02X%02X%02X", ri, gi, bi, Int((a * 255).rounded()))
        }
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }
}

extension Color {
    init(hex: String) { self.init(uiColor: UIColor(hex: hex)) }
}

/// Tutor palette names the model can use, mapped to colours that read well on paper.
enum InkPalette {
    static let named: [String: String] = [
        "red": "#E03131", "blue": "#1C64F2", "green": "#2F9E44", "purple": "#7048E8", "orange": "#F76707",
        "black": "#1F2328", "teal": "#0C8599", "pink": "#D6336C", "gray": "#6B7280", "yellow": "#F2C200",
    ]

    static func hex(for name: String?, default fallback: String) -> String {
        guard let name = name?.lowercased().trimmingCharacters(in: .whitespaces), !name.isEmpty else { return fallback }
        if name.hasPrefix("#") { return name }
        return named[name] ?? fallback
    }

    static let highlighterYellow = "#FFE066"
}

extension CGPoint {
    func offset(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
    func distance(to p: CGPoint) -> CGFloat { hypot(p.x - x, p.y - y) }
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
}

extension CGSize {
    static func * (a: CGSize, s: CGFloat) -> CGSize { CGSize(width: a.width * s, height: a.height * s) }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension String {
    func truncated(_ n: Int) -> String {
        count > n ? String(prefix(n - 1)) + "…" : self
    }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Date {
    var shortRelative: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: Date())
    }
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func snap() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.8) }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

extension View {
    @ViewBuilder func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}
