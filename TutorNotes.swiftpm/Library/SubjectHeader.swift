import SwiftUI

/// The top of a subject's page in the library: what kind of subject it is, the exam countdown,
/// study actions (quiz from my notes, blurt, plan revision) and the subject's note templates.
struct SubjectHeader: View {
    let subject: Subject
    let noteCount: Int
    var newFromTemplate: (NoteTemplate) -> Void
    var quizMe: () -> Void
    var planRevision: () -> Void
    var edit: () -> Void

    var body: some View {
        let tint = Color(hex: subject.colorHex)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: subject.resolvedKind.symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text(subject.resolvedKind == .other ? "Subject" : subject.resolvedKind.title)
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Text("\(noteCount) note\(noteCount == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                ExamBadge(subject: subject, action: edit)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    StudyChip(symbol: "questionmark.bubble", title: "Quiz me", detail: "Questions from my notes", tint: tint, action: quizMe)
                    if let blurt = subject.profile.templates.first(where: \.isBlurt) {
                        StudyChip(symbol: "brain.head.profile", title: "Blurt", detail: "Write it from memory, then check", tint: tint) { newFromTemplate(blurt) }
                    }
                    StudyChip(symbol: "calendar.badge.clock", title: "Plan revision",
                              detail: subject.daysToExam() != nil ? "A plan up to the exam" : "A two-week plan", tint: tint, action: planRevision)
                }
                .padding(.horizontal, 1)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("New from a template").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(subject.profile.templates.filter { !$0.isBlurt }) { t in
                            TemplateCard(template: t, tint: tint) { newFromTemplate(t) }
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.bottom, 2)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }
}

/// Days to the subject's exam, or a prompt to add one.
struct ExamBadge: View {
    let subject: Subject
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            if let days = subject.daysToExam() {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(days == 0 ? "Today" : days == 1 ? "Tomorrow" : "\(days) days")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(days <= 7 ? Color(hex: "#E5484D") : .primary)
                    Text(subject.examLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Label("Add exam date", systemImage: "calendar.badge.plus")
                    .font(.subheadline.weight(.medium))
            }
        }
        .buttonStyle(.plain)
    }
}

private struct StudyChip: View {
    let symbol: String
    let title: String
    let detail: String
    let tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(tint.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.vertical, 10)
            .padding(.leading, 10)
            .padding(.trailing, 16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        }
        .buttonStyle(PressableStyle())
    }
}

private struct TemplateCard: View {
    let template: NoteTemplate
    let tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: template.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(tint)
                Text(template.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(template.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 170, height: 112, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        }
        .buttonStyle(PressableStyle())
    }
}
