import SwiftUI

/// Page thumbnails: jump, add, duplicate, clear, delete, reorder by dragging, and change the page size.
/// (Explicitly main-actor, as in EditorTopBar: the helper methods below touch the main-actor model.)
@MainActor
struct PageNavigator: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    /// Thumbnails by page id, so a page keeps its picture when it moves.
    @State private var thumbs: [UUID: UIImage] = [:]
    @State private var pendingDelete: Int?
    @State private var pendingClear: Int?
    /// The page a dragged page is currently over.
    @State private var dropTarget: UUID?

    private var pages: [Page] { model.document.content.pages }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], spacing: 22) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { i, page in
                        cell(i, page)
                    }
                }
                .padding(20)
            }
            .clearPageDialog(model: model, page: $pendingClear)
            .safeAreaInset(edge: .bottom) { lockNote }
            .navigationTitle("Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { PageSizeMenu(model: model) }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.document.appendPage()
                        refresh()
                    } label: { Label("Add Page", systemImage: "plus") }
                }
            }
            // The pages change shape: don't show the old thumbnails while the new ones render.
            .onChange(of: model.document.content.pageSize) { refresh() }
            .confirmationDialog("Delete this page? Its ink and items will be removed. This can't be undone.",
                                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete Page", role: .destructive) {
                    if let i = pendingDelete { model.document.deletePage(i) }
                    pendingDelete = nil
                    // The canvas only reports page changes on scroll; don't leave "Page 5 of 4"
                    // (or make Paper "this page" fall through to every page).
                    model.currentPage = min(model.currentPage, model.pageCount - 1)
                    refresh()
                }
            }
        }
    }

    private func cell(_ i: Int, _ page: Page) -> some View {
        PageCell(number: i + 1, thumb: thumbs[page.id],
                 aspect: model.document.pageSize.width / model.document.pageSize.height,
                 isCurrent: i == model.currentPage, isDropTarget: dropTarget == page.id)
            .onTapGesture {
                model.canvas?.scrollToPage(i)
                dismiss()
            }
            .contextMenu { menu(for: i) }
            .draggable(page.id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                drop(items, onto: page.id)
            } isTargeted: { targeted in
                if targeted {
                    dropTarget = page.id
                } else if dropTarget == page.id {
                    dropTarget = nil
                }
            }
            .task(id: model.document.revision) {
                thumbs[page.id] = PageRenderer.thumbnail(model.document, page: i, width: 220)
            }
    }

    @ViewBuilder private func menu(for i: Int) -> some View {
        Button { model.document.insertPage(after: i); refresh() } label: { Label("Insert Page After", systemImage: "doc.badge.plus") }
        Button { model.document.duplicatePage(i); refresh() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button(role: .destructive) { pendingClear = i } label: { Label("Clear Page", systemImage: "eraser") }
        if pages.count > 1 {
            Button(role: .destructive) { pendingDelete = i } label: { Label("Delete Page", systemImage: "trash") }
        }
    }

    /// Why the page size is greyed out, when it is.
    @ViewBuilder private var lockNote: some View {
        if let reason = model.document.pageSizeLockReason {
            Text("Page size can't be changed. " + reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
    }

    /// A dragged page was dropped on another: it takes that page's place and the rest shuffle along.
    private func drop(_ items: [String], onto target: UUID) -> Bool {
        dropTarget = nil
        guard let id = items.first.flatMap({ UUID(uuidString: $0) }),
              let from = pages.firstIndex(where: { $0.id == id }),
              let to = pages.firstIndex(where: { $0.id == target }), from != to else { return false }
        withAnimation(.snappy) { model.movePage(from: from, to: to) }
        Haptics.tap()
        return true
    }

    private func refresh() {
        thumbs.removeAll()
    }
}

/// One page in the Pages sheet: its thumbnail and number, outlined when it's the page being
/// viewed or a dragged page is over it.
private struct PageCell: View {
    let number: Int
    let thumb: UIImage?
    let aspect: CGFloat
    let isCurrent: Bool
    let isDropTarget: Bool

    var body: some View {
        VStack(spacing: 6) {
            thumbnail
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(outline, lineWidth: isCurrent || isDropTarget ? 3 : 1))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            Text("\(number)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .scaleEffect(isDropTarget ? 1.05 : 1)
        .animation(.snappy(duration: 0.15), value: isDropTarget)
    }

    @ViewBuilder private var thumbnail: some View {
        if let thumb {
            Image(uiImage: thumb).resizable().scaledToFit()
        } else {
            Rectangle().fill(Color(uiColor: .secondarySystemBackground)).aspectRatio(aspect, contentMode: .fit)
        }
    }

    private var outline: Color {
        isCurrent || isDropTarget ? Color.accentColor : Color.secondary.opacity(0.25)
    }
}
