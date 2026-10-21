import SwiftUI

/// Generates practice questions as answerable cards on the page.
struct PracticeSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var topic = ""
    @State private var count = 4
    @State private var difficulty = "medium"
    @State private var style = "Mixed"
    @State private var newPage = true

    static let styles = ["Mixed", "Short answer", "Multi-step working", "Exam-style", "Word problems", "Graph sketching"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. solving quadratics by factorising", text: $topic, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Topic")
                } footer: {
                    Text("Leave blank to practise whatever is on this page.")
                }
                Section("Questions") {
                    Stepper("\(count) question\(count == 1 ? "" : "s")", value: $count, in: 1...10)
                    Picker("Difficulty", selection: $difficulty) {
                        Text("Easy").tag("easy")
                        Text("Medium").tag("medium")
                        Text("Hard").tag("hard")
                        Text("Exam").tag("exam")
                    }
                    .pickerStyle(.segmented)
                    Picker("Style", selection: $style) {
                        ForEach(PracticeSheet.styles, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Start on a new page", isOn: $newPage)
                }
                Section {
                    Text("Write your answers in the answer spaces. Your tutor marks them as you finish (with Watching on), or tap Check on a question.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Practice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let t = topic.trimmed.isEmpty ? "the topic on the page I'm looking at (\(model.document.meta.title))" : topic.trimmed
                        model.showPanelIfNoKey()
                        model.tutor.practice(PracticeRequest(topic: t, count: count, difficulty: difficulty,
                                                             style: style == "Mixed" ? "" : style, newPage: newPage))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
