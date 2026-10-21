import SwiftUI
import UniformTypeIdentifiers

/// Sets up a past paper to work through: the paper (PDF or scanned), its mark scheme, and the time
/// allowed. The tutor then maps the questions and marks against the scheme.
struct PastPaperSetupView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    var subjectID: UUID?
    var onCreated: (NoteMeta) -> Void

    private enum Target { case paper, markScheme }

    @State private var paperURL: URL?
    @State private var schemeURL: URL?
    @State private var title = ""
    @State private var subject: UUID?
    @State private var minutes = 0
    // fileImporter clears its isPresented binding before calling back, so the target is kept
    // separately from the flag.
    @State private var showImporter = false
    @State private var importTarget: Target = .paper
    @State private var scanTarget: Target?
    @State private var failed = false

    static let timings = [0, 30, 45, 60, 75, 90, 105, 120, 150, 180]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    fileRow(title: "Paper", url: paperURL, target: .paper, required: true)
                    fileRow(title: "Mark scheme", url: schemeURL, target: .markScheme, required: false)
                } footer: {
                    Text("Your tutor reads both, maps out every question, and marks your answers against the mark scheme. The mark scheme stays hidden unless you ask for a solution.")
                }
                Section {
                    TextField("Title, e.g. June 2023 Paper 1", text: $title)
                    Picker("Subject", selection: $subject) {
                        Text("None").tag(UUID?.none)
                        ForEach(library.subjects) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                }
                Section {
                    Picker("Time allowed", selection: $minutes) {
                        ForEach(PastPaperSetupView.timings, id: \.self) { m in
                            Text(m == 0 ? "Untimed" : PaperBar.minutes(m)).tag(m)
                        }
                    }
                } footer: {
                    Text(minutes == 0
                         ? "Work at your own pace and get each question marked as you go."
                         : "Exam conditions: the clock starts when you tap Start, and your tutor stays quiet until you finish or ask.")
                }
            }
            .navigationTitle("Past Paper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { create() }
                        .fontWeight(.semibold)
                        .disabled(paperURL == nil)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result else { return }
                set(url, for: importTarget)
            }
            .fullScreenCover(isPresented: Binding(get: { scanTarget != nil }, set: { if !$0 { scanTarget = nil } })) {
                DocumentScanner(onFinish: { pages in
                    let target = scanTarget
                    scanTarget = nil
                    let name = target == .markScheme ? "Scanned mark scheme" : "Scanned paper"
                    if let target, let url = DocumentScanner.pdf(from: pages, name: name) { set(url, for: target) }
                }, onCancel: { scanTarget = nil })
                .ignoresSafeArea()
            }
            .alert("Couldn't open that paper", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Choose a PDF (or scan the pages) and try again.")
            }
            .onAppear { subject = subjectID }
        }
    }

    private func fileRow(title: String, url: URL?, target: Target, required: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: url == nil ? (required ? "doc.badge.plus" : "doc.badge.ellipsis") : "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(url == nil ? Color.secondary : Color.green)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(url?.deletingPathExtension().lastPathComponent ?? (required ? "Required" : "Optional, but it makes marking exact"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Button {
                    importTarget = target
                    showImporter = true
                } label: { Label("Choose PDF", systemImage: "folder") }
                if DocumentScanner.isAvailable {
                    Button { scanTarget = target } label: { Label("Scan Pages", systemImage: "doc.viewfinder") }
                }
                if url != nil {
                    Button(role: .destructive) { clear(target) } label: { Label("Remove", systemImage: "trash") }
                }
            } label: {
                Text(url == nil ? "Add" : "Change")
            }
        }
    }

    private func set(_ url: URL, for target: Target) {
        switch target {
        case .paper:
            paperURL = url
            if title.trimmed.isEmpty { title = url.deletingPathExtension().lastPathComponent }
        case .markScheme:
            schemeURL = url
        }
    }

    private func clear(_ target: Target) {
        switch target {
        case .paper: paperURL = nil
        case .markScheme: schemeURL = nil
        }
    }

    private func create() {
        guard let paperURL else { return }
        guard let meta = library.createPastPaper(paper: paperURL, markScheme: schemeURL, title: title, subjectID: subject,
                                                 timeLimitMinutes: minutes == 0 ? nil : minutes) else {
            failed = true
            return
        }
        dismiss()
        onCreated(meta)
    }
}
