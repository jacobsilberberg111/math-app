import Foundation

func runSubjectTests() {
    runSubjectTestsBody()
}

func runSubjectTestsBody() {
    // Kinds from names (subjects made before kinds existed).
    check(SubjectKind.infer(from: "Maths") == .maths, "maths")
    check(SubjectKind.infer(from: "Physics") == .science, "physics → science")
    check(SubjectKind.infer(from: "History") == .history, "history isn't computing")
    check(SubjectKind.infer(from: "Chemistry") == .science, "chemistry isn't computing")
    check(SubjectKind.infer(from: "IST") == .computing, "IST")
    check(SubjectKind.infer(from: "Computing Technology") == .computing, "computing")
    check(SubjectKind.infer(from: "Geography") == .geography, "geography")
    check(SubjectKind.infer(from: "English") == .english, "english")
    check(SubjectKind.infer(from: "PDHPE") == .pdhpe, "pdhpe")
    check(SubjectKind.infer(from: "French") == .other, "french → other")
    check(SubjectKind.infer(from: "Biology") == .science, "biology")

    // Every kind has 8 Ask-menu actions, guidance and a blurt template.
    for k in SubjectKind.allCases {
        let p = SubjectProfile.of(k)
        check(p.quickActions.count == 8, "\(k) has 8 actions")
        check(Set(p.quickActions).count == 8, "\(k) actions unique")
        let g = p.tutorGuidance(curriculum: .nsw, year: 9, subjectName: k.title)
        check(g.contains("Year 9") && g.contains("Stage 5"), "\(k) guidance mentions year/stage")
        check(g.contains("NESA key words"), "\(k) NSW guidance has key words")
        check(p.templates.contains { $0.isBlurt }, "\(k) has blurt")
        check(p.templates.contains { $0.pattern == "cornell" }, "\(k) has cornell")
    }
    check(!SubjectProfile.of(.science).tutorGuidance(curriculum: .uk, year: 9, subjectName: "Science").contains("NESA"), "no NESA outside NSW")
    check(Curriculum.nsw.studentLine(year: 11).contains("Stage 6"), "stage 6")

    // Template slots: an 8-section practical report spreads over two pages, snapped to lines.
    let weights = SubjectProfile.of(.science).templates[0].sections.map(\.weight)
    let slots = TemplateLayout.slots(weights: weights, firstTop: 126, top: 96, bottom: 1010, lineSpacing: 30, lineOrigin: 96)
    check(slots.count == 8, "8 slots")
    check(Set(slots.map(\.page)) == [0, 1], "two pages: \(slots.map(\.page))")
    check(slots.allSatisfy { Int($0.top - 96) % 30 == 0 }, "snapped to ruled lines: \(slots.map(\.top))")
    check(slots.allSatisfy { $0.top + $0.height <= 1010.5 }, "within page")
    for i in 1..<slots.count where slots[i].page == slots[i - 1].page {
        check(slots[i].top >= slots[i - 1].top + slots[i - 1].height - 0.5, "slots don't overlap")
    }
    let one = TemplateLayout.slots(weights: [1], firstTop: 100, top: 96, bottom: 1000)
    check(one == [TemplateLayout.Slot(page: 0, top: 100, height: 900)], "single slot \(one)")
}
