import SwiftUI

/// "12 / 33" over the bottom of the canvas while the note scrolls, fading a moment after it
/// stops. Tapping it opens Go to Page (and Fit Width).
struct PageIndicatorPill: View {
    @Bindable var model: EditorModel
    @State private var shown = false
    @State private var showGoTo = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Group {
            if (shown || showGoTo) && !model.document.isFreeform {
                Button { showGoTo = true } label: {
                    Text("\(min(model.currentPage + 1, model.pageCount)) / \(model.pageCount)")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Page \(model.currentPage + 1) of \(model.pageCount). Go to page")
                .popover(isPresented: $showGoTo, arrowEdge: .bottom) {
                    GoToPageView(model: model) { showGoTo = false }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: shown)
        .onReceive(NotificationCenter.default.publisher(for: .canvasDidScroll)) { note in
            guard (note.object as AnyObject?) === model.document else { return }
            reveal()
        }
        .onChange(of: showGoTo) { _, open in
            if !open { reveal() }
        }
    }

    /// Shows the pill and hides it 1.5 s after the last scroll.
    private func reveal() {
        shown = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            shown = false
        }
    }
}

/// A page number to jump to, and Fit Width.
private struct GoToPageView: View {
    @Bindable var model: EditorModel
    var done: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Page").font(.headline)
            HStack {
                TextField("1–\(model.pageCount)", text: $text)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .focused($focused)
                    .onSubmit(go)
                Button("Go", action: go)
                    .buttonStyle(.borderedProminent)
                    .disabled(PageJump.index(from: text, pageCount: model.pageCount) == nil)
            }
            Divider()
            Button {
                model.canvas?.zoomToFit()
                done()
            } label: {
                Label("Fit Width", systemImage: "arrow.left.and.right.square")
            }
        }
        .padding(18)
        .frame(minWidth: 240)
        .onAppear {
            text = "\(model.currentPage + 1)"
            focused = true
        }
    }

    private func go() {
        guard let i = PageJump.index(from: text, pageCount: model.pageCount) else { return }
        model.canvas?.scrollToPage(i)
        done()
    }
}
