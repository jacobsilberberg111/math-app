import SwiftUI

/// What the Export menu can produce.
enum ExportKind {
    case pdf, images, noteFile, print
}

/// The Export choices, shared by the toolbar's share button and the compact insert menu.
struct ExportMenuItems: View {
    let onExport: (ExportKind) -> Void

    var body: some View {
        Button { onExport(.pdf) } label: { Label("PDF", systemImage: "doc.richtext") }
        Button { onExport(.images) } label: { Label("Images", systemImage: "photo.on.rectangle") }
        Button { onExport(.noteFile) } label: { Label("Note File (.margin)", systemImage: "doc.zipper") }
        Divider()
        Button { onExport(.print) } label: { Label("Print…", systemImage: "printer") }
    }
}

/// The toolbar's share button, opening the Export choices.
struct ExportMenu: View {
    let onExport: (ExportKind) -> Void

    var body: some View {
        Menu {
            ExportMenuItems(onExport: onExport)
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
        }
        .accessibilityLabel("Export")
    }
}
