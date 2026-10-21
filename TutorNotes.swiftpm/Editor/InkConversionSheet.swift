import SwiftUI

/// Confirms a handwriting conversion: the ink at the top for comparison, what was read below it
/// to correct, and Convert to swap the strokes for the typed version.
struct InkConversionSheet: View {
    @Bindable var conversion: InkConversion
    let model: EditorModel
    @EnvironmentObject var settings: AppSettings

    private var isText: Bool { conversion.kind == .text }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inkCard
                    phaseContent
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(isText ? "Convert to Text" : "Convert to Math")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelInkConversion() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Convert") { model.finishInkConversion(conversion) }
                        .fontWeight(.semibold)
                        .disabled(!conversion.canConvert)
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Swiping the sheet away cancels too; a reading still in flight must not land afterwards.
        .onDisappear { conversion.cancel() }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var inkCard: some View {
        Image(uiImage: conversion.snapshot.image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 150)
            .padding(10)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .accessibilityLabel("Your handwriting")
    }

    @ViewBuilder private var phaseContent: some View {
        switch conversion.phase {
        case .working: working
        case .needsConnection: connectionPrompt
        case .failed(let message): failure(message)
        case .ready: result
        }
    }

    private var working: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(isText ? "Reading your handwriting…" : "Reading your maths…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var connectionPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Converting maths uses your tutor connection", systemImage: "key")
                .font(.headline)
            Text("Connect Claude below (or in Settings), then read your maths.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ConnectionForm(compact: true)
            Button("Read my maths") { conversion.start() }
                .buttonStyle(.borderedProminent)
                .disabled(!settings.isTutorConfigured)
        }
        .padding(14)
        .background(card)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Retry") { conversion.start() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(isText ? "Recognised text" : "LaTeX, one line per line")
                if isText { textEditor } else { latexEditor }
            }
            if !isText { preview }
        }
    }

    /// Tall enough for what was read, within reason (longer text scrolls).
    private var editorHeight: CGFloat {
        min(320, max(110, CGFloat(conversion.text.components(separatedBy: "\n").count) * 26 + 32))
    }

    private var textEditor: some View {
        TextEditor(text: $conversion.text)
            .font(.system(size: 17))
            .scrollContentBackground(.hidden)
            .frame(height: editorHeight)
            .padding(8)
            .background(card)
    }

    private var latexEditor: some View {
        TextEditor(text: $conversion.text)
            .font(.system(size: 16, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .frame(height: editorHeight)
            .padding(8)
            .background(card)
    }

    /// The math typeset on white, the way it will look on the page.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Preview")
            Group {
                if let image = conversion.mathPreview() {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: image.size.width, alignment: .leading)
                } else {
                    Text("Nothing to show yet")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}
