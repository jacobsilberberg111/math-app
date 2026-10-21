import SwiftUI

/// Page thumbnails: jump, add, duplicate, delete.
struct PageNavigator: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var thumbs: [Int: UIImage] = [:]
    @State private var pendingDelete: Int?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], spacing: 22) {
                    ForEach(Array(model.document.content.pages.indices), id: \.self) { i in
                        VStack(spacing: 6) {
                            Group {
                                if let img = thumbs[i] {
                                    Image(uiImage: img).resizable().scaledToFit()
                                } else {
                                    Rectangle().fill(Color(uiColor: .secondarySystemBackground))
                                        .aspectRatio(model.document.pageSize.width / model.document.pageSize.height, contentMode: .fit)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(i == model.currentPage ? Color.accentColor : Color.secondary.opacity(0.25),
                                                                                    lineWidth: i == model.currentPage ? 3 : 1))
                            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                            Text("\(i + 1)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }
                        .onTapGesture {
                            model.canvas?.scrollToPage(i)
                            dismiss()
                        }
                        .contextMenu {
                            Button { model.document.insertPage(after: i); refresh() } label: { Label("Insert Page After", systemImage: "doc.badge.plus") }
                            Button { model.document.duplicatePage(i); refresh() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                            if model.document.content.pages.count > 1 {
                                Button(role: .destructive) { pendingDelete = i } label: { Label("Delete Page", systemImage: "trash") }
                            }
                        }
                        .task(id: model.document.revision) {
                            thumbs[i] = PageRenderer.thumbnail(model.document, page: i, width: 220)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.document.appendPage()
                        refresh()
                    } label: { Label("Add Page", systemImage: "plus") }
                }
            }
            .confirmationDialog("Delete this page? Its ink and items will be removed. This can't be undone.",
                                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete Page", role: .destructive) {
                    if let i = pendingDelete { model.document.deletePage(i) }
                    pendingDelete = nil
                    refresh()
                }
            }
        }
    }

    private func refresh() {
        thumbs.removeAll()
    }
}
