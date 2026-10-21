import SwiftUI

/// The student's favourite colours, shared by the pen, highlighter and text palettes.
/// Hex "#RRGGBB" strings, newest last, persisted across launches.
@MainActor
@Observable
final class ColorFavorites {
    static let shared = ColorFavorites()
    static let maxCount = 16
    static let defaults = ["#1F2328", "#1C64F2", "#E03131", "#2F9E44", "#F76707", "#7048E8"]

    private(set) var colors: [String]

    private static let key = "colorFavorites"

    init() {
        if let stored = UserDefaults.standard.stringArray(forKey: ColorFavorites.key) {
            colors = ColorFavorites.cleaned(stored)
        } else {
            colors = ColorFavorites.defaults
        }
    }

    var isFull: Bool { colors.count >= ColorFavorites.maxCount }

    func contains(_ hex: String) -> Bool {
        guard let h = ColorFavorites.normalized(hex) else { return false }
        return colors.contains(h)
    }

    /// Adds a colour; false when it's invalid, already a favourite, or the list is full.
    @discardableResult
    func add(_ hex: String) -> Bool {
        guard let h = ColorFavorites.normalized(hex), !colors.contains(h), !isFull else { return false }
        colors.append(h)
        save()
        return true
    }

    func remove(_ hex: String) {
        guard let h = ColorFavorites.normalized(hex), let i = colors.firstIndex(of: h) else { return }
        colors.remove(at: i)
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        colors.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func save() {
        UserDefaults.standard.set(colors, forKey: ColorFavorites.key)
    }

    /// "#RRGGBB" in capitals from "#rgb", "#rrggbb" or "#rrggbbaa" (with or without the "#").
    static func normalized(_ hex: String) -> String? {
        var s = hex.trimmed.uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy(\.isHexDigit) else { return nil }
        switch s.count {
        case 3: s = s.map { "\($0)\($0)" }.joined()
        case 6: break
        case 8: s = String(s.prefix(6))
        default: return nil
        }
        return "#" + s
    }

    /// Drops anything invalid or duplicated, and anything past the limit.
    private static func cleaned(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for hex in list {
            guard let h = normalized(hex), seen.insert(h).inserted else { continue }
            out.append(h)
            if out.count == maxCount { break }
        }
        return out
    }
}
