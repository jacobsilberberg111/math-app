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

    /// Question styles that suit the note's subject.
    var subjectStyles: [String] {
        switch model.tutor.subjectKind {
        case .maths: return PracticeSheet.styles
        case .science, .pdhpe: return ["Mixed", "Short answer", "Exam-style", "Label a diagram", "Interpret data", "Extended response"]
        case .geography: return ["Mixed", "Short answer", "Exam-style", "Map skills", "Interpret data", "Extended response"]
        case .history: return ["Mixed", "Short answer", "Source analysis", "Exam-style", "Extended response"]
        case .english: return ["Mixed", "Short answer", "Text analysis", "Paragraph response", "Creative writing prompt"]
        case .computing: return ["Mixed", "Short answer", "Write code", "Trace the code", "Find the bug", "Algorithm design"]
        case .other: return ["Mixed", "Short answer", "Exam-style", "Extended response"]
        }
    }

    var topicExample: String {
        switch model.tutor.subjectKind {
        case .maths: return "e.g. solving quadratics by factorising"
        case .science: return "e.g. how vaccines protect against disease"
        case .geography: return "e.g. the climate of tropical rainforests"
        case .history: return "e.g. causes of World War I"
        case .english: return "e.g. how the author uses imagery"
        case .computing: return "e.g. while loops and lists in Python"
        case .pdhpe: return "e.g. the effects of exercise on the body"
        case .other: return "e.g. the topic from today's lesson"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(topicExample, text: $topic, axis: .vertical)
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
                        ForEach(subjectStyles, id: \.self) { Text($0).tag($0) }
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
