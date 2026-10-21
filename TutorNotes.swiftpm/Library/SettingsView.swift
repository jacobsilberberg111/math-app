import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var memory = TutorMemoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""
    @State private var keyStatus: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                apiSection
                tutorSection
                proactiveSection
                studentSection
                memorySection
                pencilSection
                pagesSection
                Section {
                    Text("Your notes stay on this iPad. When you use the tutor, the pages you're looking at (as images), the note's text and any files you attach are sent to Anthropic's API to generate a response.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Privacy")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { keyDraft = settings.apiKey }
            // A key typed but not submitted would otherwise be lost on Done / swipe-down.
            .onDisappear {
                if keyDraft.trimmed != settings.apiKey { settings.apiKey = keyDraft.trimmed }
            }
        }
    }

    private var apiSection: some View {
        Section {
            SecureField("Anthropic API key (sk-ant-…)", text: $keyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { settings.apiKey = keyDraft.trimmed }
            HStack {
                Button(testing ? "Checking…" : "Save & Test") {
                    settings.apiKey = keyDraft.trimmed
                    test()
                }
                .disabled(keyDraft.trimmed.isEmpty || testing)
                Spacer()
                if let keyStatus {
                    Text(keyStatus).font(.footnote).foregroundStyle(keyStatus.hasPrefix("✓") ? .green : .red)
                }
            }
            Link("Get an API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
        } header: {
            Text("Claude")
        } footer: {
            Text("Stored in the Keychain. Requests go directly from this iPad to api.anthropic.com and are billed to your Anthropic account.")
        }
    }

    private var tutorSection: some View {
        Section("Tutor") {
            Picker("Model", selection: $settings.tutorModel) {
                ForEach(ClaudeModelOption.all) { option in
                    VStack(alignment: .leading) {
                        Text(option.name)
                        Text(option.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(option.id)
                }
            }
            Picker("Thinking", selection: $settings.effort) {
                ForEach(TutorEffort.allCases) { e in Text(e.title).tag(e) }
            }
            Picker("Tutor's writing", selection: $settings.tutorHand) {
                ForEach(TutorHandStyle.allCases) { Text($0.title).tag($0) }
            }
            ColorPicker("Tutor ink colour", selection: Binding(get: { Color(hex: settings.tutorInkHex) },
                                                                set: { settings.tutorInkHex = UIColor($0).hexString }), supportsOpacity: false)
            Toggle("Read feedback aloud", isOn: $settings.speakFeedback)
        }
    }

    private var proactiveSection: some View {
        Section {
            Toggle("Watch while I work", isOn: $settings.proactive)
            if settings.proactive {
                Picker("Involvement", selection: $settings.proactivity) {
                    ForEach(Proactivity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(settings.proactivity.detail).font(.footnote).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text("Look after I pause for \(String(format: "%.1f", settings.pauseDelay)) s")
                    Slider(value: $settings.pauseDelay, in: 2...10, step: 0.5)
                }
                Picker("Model for glances", selection: $settings.observerModel) {
                    ForEach(ObserverModelChoice.allCases) { Text($0.title).tag($0) }
                }
            }
        } header: {
            Text("Proactive tutor")
        } footer: {
            Text("Glances only happen in notes where you've used the tutor or have practice questions, and each one is a short API request.")
        }
    }

    private var studentSection: some View {
        Section {
            TextField("Level (e.g. Year 11 GCSE Higher, AP Calculus, first-year uni)", text: $settings.studentLevel)
            TextField("Goals (e.g. exam in March, weak on trigonometry)", text: $settings.studentGoals, axis: .vertical)
                .lineLimit(1...3)
        } header: {
            Text("About you")
        }
    }

    private var memorySection: some View {
        Section {
            if memory.entries.isEmpty {
                Text("Nothing yet. Your tutor saves short notes here as it learns how you work.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(memory.entries) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.text)
                    Text(e.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button(role: .destructive) { memory.remove(e) } label: { Label("Delete", systemImage: "trash") }
                }
            }
            if !memory.entries.isEmpty {
                Button("Clear memory", role: .destructive) { memory.clear() }
            }
        } header: {
            Text("What your tutor remembers")
        }
    }

    private var pencilSection: some View {
        Section("Apple Pencil") {
            Picker("Double-tap", selection: $settings.doubleTapAction) {
                ForEach(PencilTapAction.allCases) { Text($0.title).tag($0) }
            }
            Picker("Squeeze (Pencil Pro)", selection: $settings.squeezeAction) {
                ForEach(PencilSqueezeAction.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Hover preview", isOn: $settings.hoverPreview)
            Toggle("Draw and hold to snap shapes", isOn: $settings.shapeRecognition)
            Toggle("Draw with finger", isOn: $settings.fingerDrawing)
            Toggle("Two-finger tap to undo, three to redo", isOn: $settings.gestureUndo)
        }
    }

    private var pagesSection: some View {
        Section("Pages") {
            Picker("Default paper", selection: $settings.defaultPattern) {
                ForEach(PaperPattern.allCases) { Text($0.title).tag($0) }
            }
            Picker("Default colour", selection: $settings.defaultPaperColor) {
                ForEach(PaperColor.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            Toggle("Add pages automatically as I write", isOn: $settings.autoAddPages)
        }
    }

    private func test() {
        testing = true
        keyStatus = nil
        let client = AnthropicClient(apiKey: settings.apiKey.trimmed)
        Task {
            do {
                let models = try await client.listModels()
                let hasDefault = models.contains(settings.tutorModel)
                keyStatus = hasDefault || models.isEmpty ? "✓ Connected" : "✓ Connected (\(settings.modelOption.name) not listed for this key)"
            } catch {
                keyStatus = (error as? AnthropicError)?.errorDescription ?? error.localizedDescription
            }
            testing = false
        }
    }
}
