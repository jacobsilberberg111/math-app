import SwiftUI

/// Creating or editing a subject: what kind it is (which specialises its tutor, templates and
/// tools), its name and colour, and the next exam.
struct SubjectEditorSheet: View {
    /// nil to create a new subject.
    let existing: Subject?
    var onSave: (Subject) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var kind: SubjectKind = .maths
    @State private var name = ""
    /// The name was typed, so picking another kind doesn't replace it.
    @State private var nameEdited = false
    @State private var colorHex = SubjectKind.maths.defaultColorHex
    @State private var colorEdited = false
    @State private var hasExam = false
    @State private var examDate = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
    @State private var examTitle = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10) {
                        ForEach(SubjectKind.allCases) { k in
                            kindTile(k)
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("Subject")
                } footer: {
                    Text(kindFooter)
                }

                Section("Name and colour") {
                    TextField(kind.title, text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Subject.palette, id: \.self) { hex in
                                Button {
                                    colorHex = hex
                                    colorEdited = true
                                } label: {
                                    Circle().fill(Color(hex: hex)).frame(width: 30, height: 30)
                                        .overlay(Circle().stroke(Color.primary.opacity(hex == colorHex ? 0.9 : 0), lineWidth: 2.5).padding(-4))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(LibraryView.colourNames[hex] ?? hex)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                    }
                }

                Section {
                    Toggle("Upcoming exam or test", isOn: $hasExam.animation())
                    if hasExam {
                        DatePicker("Date", selection: $examDate, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                        TextField("What is it? (e.g. Yearly exam, Topic test: Disease)", text: $examTitle)
                    }
                } header: {
                    Text("Exam")
                } footer: {
                    Text("Home counts down to it, and your tutor plans revision and practice around it.")
                }
            }
            .navigationTitle(existing == nil ? "New Subject" : "Edit Subject")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Create" : "Save") { save() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private var kindFooter: String {
        switch kind {
        case .maths: return "Grid paper, worked examples, graphs and step-by-step marking."
        case .science: return "Practical reports, real diagrams to label, process flowcharts, disease maps and results graphs."
        case .english: return "Teacher-style feedback on your writing, TEEL paragraphs and technique spotting."
        case .geography: return "Real maps with real data, climate graphs, case studies and biome profiles."
        case .history: return "Source analysis, timelines, cause-and-effect charts and extended responses."
        case .computing: return "Code blocks that run Python, flowcharts, trace tables and debugging help."
        case .pdhpe: return "Body-system diagrams, key terms and extended responses."
        case .other: return "A general tutor that adapts to your notes."
        }
    }

    private func kindTile(_ k: SubjectKind) -> some View {
        let selected = k == kind
        return Button {
            select(k)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: k.symbol).font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selected ? .white : Color(hex: k.defaultColorHex))
                Text(k.shortTitle).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? .white : .primary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color(hex: k.defaultColorHex) : Color(hex: k.defaultColorHex).opacity(0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func select(_ k: SubjectKind) {
        kind = k
        if !nameEdited { name = k == .other ? "" : k.title }
        if !colorEdited { colorHex = k.defaultColorHex }
    }

    private func load() {
        guard let s = existing else {
            select(.maths)
            return
        }
        kind = s.resolvedKind
        name = s.name
        nameEdited = true
        colorHex = s.colorHex
        colorEdited = true
        if let d = s.examDate {
            hasExam = true
            examDate = d
        }
        examTitle = s.examTitle ?? ""
    }

    private func save() {
        var s = existing ?? Subject(name: "", colorHex: colorHex)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        s.name = trimmed.isEmpty ? kind.title : trimmed
        s.kind = kind
        s.colorHex = colorHex
        s.examDate = hasExam ? examDate : nil
        let title = examTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        s.examTitle = hasExam && !title.isEmpty ? title : nil
        onSave(s)
        dismiss()
    }
}
