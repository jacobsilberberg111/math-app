import SwiftUI

/// Page Size choices for the Pages sheet's toolbar. Disabled when the note's pages can't be resized.
struct PageSizeMenu: View {
    let model: EditorModel

    var body: some View {
        let current = model.document.content.pageSize
        Menu {
            ForEach(PageSize.options, id: \.self) { size in
                Button { model.setPageSize(size) } label: {
                    Label(size.title, systemImage: size == current ? "checkmark" : (size.isLandscape ? "rectangle" : "rectangle.portrait"))
                }
            }
        } label: {
            Label("Page Size", systemImage: "aspectratio")
        }
        .disabled(!model.document.canChangePageSize)
    }
}

/// The Page Size section of the paper picker: the choice is applied with the rest of the picker.
struct PageSizeSection: View {
    let document: NoteDocument
    @Binding var selection: PageSize

    var body: some View {
        Section {
            Picker("Page Size", selection: $selection) {
                ForEach(PageSize.options, id: \.self) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(!document.canChangePageSize)
        } header: {
            Text("Page Size")
        } footer: {
            Text(document.pageSizeLockReason ?? "Applies to every page in the note.")
        }
    }
}

/// Asks before clearing a page's ink and items (the paper or PDF background stays).
private struct ClearPageDialog: ViewModifier {
    let model: EditorModel
    @Binding var page: Int?

    func body(content: Content) -> some View {
        content.confirmationDialog("Clear this page? Its ink and items will be removed; the paper stays. You can undo this.",
                                   isPresented: Binding(get: { page != nil }, set: { if !$0 { page = nil } }),
                                   titleVisibility: .visible) {
            Button("Clear Page", role: .destructive) {
                if let i = page { model.clearPage(i) }
                page = nil
            }
        }
    }
}

extension View {
    /// Shows the clear-page confirmation whenever `page` is set to a page index.
    func clearPageDialog(model: EditorModel, page: Binding<Int?>) -> some View {
        modifier(ClearPageDialog(model: model, page: page))
    }
}
