import SwiftUI

/// Colour choices for the current pen, highlighter or text slot: favourites shared by every tool,
/// the tool's presets, a custom colour, and an eyedropper that samples the page.
@MainActor
struct ColorPalettePicker: View {
    @Binding var hex: String
    var highlighter: Bool
    /// Starts sampling a colour from the page. The owner closes the popover; nil hides the button.
    var onEyedropper: (() -> Void)?

    static let pens = ["#1F2328", "#495057", "#868E96", "#FFFFFF", "#1C64F2", "#4DABF7", "#0C8599", "#2F9E44",
                       "#82C91E", "#F2C200", "#F76707", "#E03131", "#D6336C", "#AE3EC9", "#7048E8", "#5C3D2E"]
    static let highlighters = ["#FFE066", "#FFD43B", "#8CE99A", "#69DB7C", "#74C0FC", "#A5D8FF", "#FFA8A8", "#FFC9C9",
                               "#D0BFFF", "#E599F7", "#FFC078", "#C3FAE8"]

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 7)

    private var favorites: ColorFavorites { ColorFavorites.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            favouritesSection
            presetsSection
            customSection
        }
        .padding(16)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ColorSwatch(hex: hex, size: 24)
            Text("Colour").font(.headline)
            Spacer()
            Text(hex.uppercased())
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func isCurrent(_ s: String) -> Bool { s.caseInsensitiveCompare(hex) == .orderedSame }

    // MARK: Favourites

    private var favouritesSection: some View {
        section("Favourites") {
            LazyVGrid(columns: ColorPalettePicker.columns, spacing: 10) {
                ForEach(favorites.colors, id: \.self) { s in
                    favouriteButton(s)
                }
                if !favorites.contains(hex) && !favorites.isFull {
                    addButton
                }
            }
        }
    }

    private func favouriteButton(_ s: String) -> some View {
        Button {
            hex = s
        } label: {
            ColorSwatch(hex: s, selected: isCurrent(s))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Favourite colour \(s)")
        .accessibilityAddTraits(isCurrent(s) ? .isSelected : [])
        .contextMenu {
            if let i = favorites.colors.firstIndex(of: s), i > 0 {
                Button { favorites.move(fromOffsets: IndexSet(integer: i), toOffset: 0) } label: {
                    Label("Move to Front", systemImage: "arrow.left.to.line")
                }
            }
            Button(role: .destructive) { favorites.remove(s) } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private var addButton: some View {
        Button {
            if favorites.add(hex) { Haptics.tap() }
        } label: {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .overlay(Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add this colour to favourites")
    }

    // MARK: Presets

    private var presetsSection: some View {
        let swatches = highlighter ? ColorPalettePicker.highlighters : ColorPalettePicker.pens
        return section(highlighter ? "Highlighters" : "Pens") {
            LazyVGrid(columns: ColorPalettePicker.columns, spacing: 10) {
                ForEach(swatches, id: \.self) { s in
                    Button {
                        hex = s
                    } label: {
                        ColorSwatch(hex: s, selected: isCurrent(s))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Colour \(s)")
                    .accessibilityAddTraits(isCurrent(s) ? .isSelected : [])
                }
            }
        }
    }

    // MARK: Custom & eyedropper

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            ColorPicker("Custom", selection: Binding(get: { Color(hex: hex) }, set: { hex = UIColor($0).hexString }), supportsOpacity: false)
            if let onEyedropper {
                Button(action: onEyedropper) {
                    Label("Eyedropper", systemImage: "eyedropper")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Closes this and picks the colour of whatever you tap on the page")
            }
        }
    }
}

/// A round colour chip, ringed in the accent colour when it's the one in use.
struct ColorSwatch: View {
    let hex: String
    var selected = false
    var size: CGFloat = 30

    var body: some View {
        Circle().fill(Color(hex: hex))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0).padding(-4))
            .frame(width: size, height: size)
    }
}
