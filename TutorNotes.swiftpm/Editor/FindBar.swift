import SwiftUI

/// The strip under the toolbar while finding text in the note: search field, match count,
/// previous/next, and whether handwriting is still being read.
@MainActor
struct FindBar: View {
    @Bindable var find: FindController
    @Environment(\.horizontalSizeClass) private var sizeClass
    @FocusState private var focused: Bool

    var body: some View {
        if find.isOpen {
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color(uiColor: .secondarySystemBackground))
                .overlay(alignment: .bottom) { Divider() }
                .transition(.opacity)
                .onChange(of: find.document.revision) { _, _ in find.documentChanged() }
                .onChange(of: find.focusTick) { _, _ in focused = true }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            field
            if !summary.isEmpty {
                Text(summary)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if find.isReading { reading }
            Spacer(minLength: 8)
            Button { find.previous() } label: {
                Image(systemName: "chevron.up").frame(width: 30, height: 30)
            }
            .disabled(find.matches.isEmpty)
            .accessibilityLabel("Previous match")
            Button { find.next() } label: {
                Image(systemName: "chevron.down").frame(width: 30, height: 30)
            }
            .disabled(find.matches.isEmpty)
            .accessibilityLabel("Next match")
            // Escape closes the bar too.
            Button("Done") { find.close() }
                .keyboardShortcut(.cancelAction)
        }
        .font(.subheadline)
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in note", text: $find.query)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit {
                    find.next()
                    focused = true
                }
                // Focusing in the same update that inserts the field is unreliable; do it once it's there.
                .onAppear { focused = true }
            if !find.query.isEmpty {
                Button { find.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(uiColor: .tertiarySystemFill)))
        .frame(maxWidth: 360)
    }

    private var reading: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            if sizeClass != .compact {
                Text("Reading handwriting…").foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reading handwriting")
    }

    private var summary: String {
        guard !find.query.trimmed.isEmpty else { return "" }
        guard let i = find.currentIndex else { return "No results" }
        return "\(i + 1) of \(find.matches.count)"
    }
}
