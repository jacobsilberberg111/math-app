import Foundation

// MARK: - Subject kinds

/// What a subject is, which decides how its notebooks and its tutor behave: the tutor's
/// specialist guidance, the Ask menu, note templates and the Insert menu's tools.
enum SubjectKind: String, Codable, CaseIterable, Identifiable {
    case maths, science, english, geography, history, computing, pdhpe, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .maths: return "Maths"
        case .science: return "Science"
        case .english: return "English"
        case .geography: return "Geography"
        case .history: return "History"
        case .computing: return "Computing Technology"
        case .pdhpe: return "PDHPE"
        case .other: return "Other"
        }
    }

    /// Short name for tight spaces.
    var shortTitle: String {
        switch self {
        case .computing: return "Computing"
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .maths: return "function"
        case .science: return "flask"
        case .english: return "text.book.closed"
        case .geography: return "globe.asia.australia"
        case .history: return "building.columns"
        case .computing: return "chevron.left.forwardslash.chevron.right"
        case .pdhpe: return "figure.run"
        case .other: return "folder"
        }
    }

    var defaultColorHex: String {
        switch self {
        case .maths: return "#5B5BD6"
        case .science: return "#30A46C"
        case .english: return "#D6409F"
        case .geography: return "#0090FF"
        case .history: return "#F76B15"
        case .computing: return "#8E4EC6"
        case .pdhpe: return "#E5484D"
        case .other: return "#12A594"
        }
    }

    /// Guesses the kind from a subject's name, for subjects made before kinds existed.
    static func infer(from name: String) -> SubjectKind {
        let n = name.lowercased()
        let words = Set(n.split { !$0.isLetter }.map(String.init))
        func stem(_ stems: [String]) -> Bool { stems.contains { n.contains($0) } }
        func word(_ list: [String]) -> Bool { !words.isDisjoint(with: list) }
        if stem(["math", "algebra", "calculus", "statistic"]) { return .maths }
        if stem(["comput", "coding", "software", "programming", "digital tech", "comp tech"]) || word(["ist", "it", "ict", "cs"]) { return .computing }
        if stem(["scien", "physic", "chemi", "biolog", "disease"]) || word(["bio", "chem"]) { return .science }
        if stem(["geog"]) || word(["geo"]) { return .geography }
        if stem(["histor"]) || word(["hsie"]) { return .history }
        if stem(["english", "literature", "writing", "essay"]) { return .english }
        if stem(["pdhpe", "health", "physical education"]) || word(["pe", "sport"]) { return .pdhpe }
        return .other
    }
}

// MARK: - Curriculum

/// Where and at what level the student studies, so the tutor pitches work and exam language
/// correctly.
enum Curriculum: String, Codable, CaseIterable, Identifiable {
    case nsw, australia, uk, us, ib, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nsw: return "NSW (NESA)"
        case .australia: return "Australia (other states)"
        case .uk: return "UK"
        case .us: return "US"
        case .ib: return "IB"
        case .other: return "Other"
        }
    }

    var isAustralian: Bool { self == .nsw || self == .australia }

    /// One line describing the student, for the tutor.
    func studentLine(year: Int) -> String {
        switch self {
        case .nsw:
            let stage = year <= 6 ? "Stage \(max(1, (year + 1) / 2))" : year <= 8 ? "Stage 4" : year <= 10 ? "Stage 5" : "Stage 6 (HSC)"
            return "The student is in Year \(year) in New South Wales, Australia (\(stage), NESA syllabus). Use Australian spelling and terms, metric units, and NESA key words in questions. Year 7–10 assessment is school-based (topic tests, assessment tasks, half-yearly and yearly exams); write practice questions the way an NSW teacher would."
        case .australia:
            return "The student is in Year \(year) in Australia (Australian Curriculum). Use Australian spelling and terms and metric units."
        case .uk:
            return "The student is in Year \(year) in the UK. Use British spelling and exam-board style command words."
        case .us:
            return "The student is in grade \(max(1, year - 1)) in the US. Use US spelling and units where the course does."
        case .ib:
            return "The student follows the IB (year \(year)). Use IB command terms."
        case .other:
            return "The student is in year \(year) of school."
        }
    }
}

// MARK: - Note templates

/// A ready-made page layout for a subject's notebooks: a title and headed sections with space
/// to write in, placed as the student's own typed headings.
struct NoteTemplate: Identifiable, Equatable {
    var id: String
    var title: String
    var symbol: String
    var detail: String
    /// PaperPattern raw value.
    var pattern: String
    var sections: [TemplateSection]
    /// Blurt pages: written from memory, then checked against the subject's notes.
    var isBlurt = false
}

struct TemplateSection: Equatable {
    var heading: String
    /// Small grey prompt under the heading.
    var hint: String?
    /// Share of the page's writing height this section gets (the rest of a page is split evenly).
    var weight: Double = 1
}

/// Tools the Insert menu offers first for a subject (all are available everywhere under More).
enum SubjectInsertTool: String, CaseIterable, Identifiable {
    case calculator, map, climateGraph, codeBlock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calculator: return "Calculator"
        case .map: return "Map"
        case .climateGraph: return "Climate Graph"
        case .codeBlock: return "Code Block"
        }
    }

    var symbol: String {
        switch self {
        case .calculator: return "plus.forwardslash.minus"
        case .map: return "map"
        case .climateGraph: return "cloud.sun.rain"
        case .codeBlock: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

// MARK: - Profiles

/// Everything that specialises the app for one kind of subject.
struct SubjectProfile {
    let kind: SubjectKind

    static func of(_ kind: SubjectKind) -> SubjectProfile { SubjectProfile(kind: kind) }

    /// Paper for a plain new notebook (PaperPattern raw value).
    var defaultPattern: String {
        switch kind {
        case .maths: return "grid"
        case .computing: return "dots"
        default: return "ruled"
        }
    }

    /// Ask-menu actions (TutorQuickAction raw values), eight of them.
    var quickActions: [String] {
        switch kind {
        case .maths: return ["check", "hint", "nextStep", "explain", "solve", "graphIt", "similar", "flashcards"]
        case .science: return ["check", "explain", "diagram", "processChart", "keyTerms", "examQuestion", "dataChart", "flashcards"]
        case .geography: return ["check", "explain", "mapIt", "climate", "keyTerms", "examQuestion", "summarise", "flashcards"]
        case .history: return ["check", "explain", "sourceAnalysis", "timeline", "keyTerms", "examQuestion", "summarise", "flashcards"]
        case .english: return ["feedback", "techniques", "explain", "paragraphPlan", "keyTerms", "examQuestion", "summarise", "flashcards"]
        case .computing: return ["checkCode", "debug", "hint", "explain", "traceTable", "processChart", "similar", "flashcards"]
        case .pdhpe: return ["check", "explain", "diagram", "keyTerms", "examQuestion", "processChart", "summarise", "flashcards"]
        case .other: return ["check", "hint", "explain", "summarise", "keyTerms", "examQuestion", "similar", "flashcards"]
        }
    }

    var insertTools: [SubjectInsertTool] {
        switch kind {
        case .maths: return [.calculator]
        case .geography: return [.map, .climateGraph]
        case .science, .pdhpe: return [.map]
        case .history: return [.map]
        case .computing: return [.codeBlock]
        default: return []
        }
    }

    // MARK: Templates

    var templates: [NoteTemplate] {
        var list: [NoteTemplate] = []
        switch kind {
        case .maths:
            list.append(NoteTemplate(id: "maths.worked", title: "Worked Examples", symbol: "function", detail: "Rule, example, then your turn",
                                     pattern: "grid", sections: [
                                        TemplateSection(heading: "Key idea / formula", hint: "The rule in your own words", weight: 0.7),
                                        TemplateSection(heading: "Worked example", hint: "Every step, one per line", weight: 1.3),
                                        TemplateSection(heading: "My turn", hint: "Try a similar one", weight: 1.3),
                                     ]))
        case .science:
            list.append(NoteTemplate(id: "science.prac", title: "Practical Report", symbol: "testtube.2", detail: "Aim, hypothesis, method, results, conclusion",
                                     pattern: "ruled", sections: [
                                        TemplateSection(heading: "Aim", hint: "To investigate the effect of … on …", weight: 0.45),
                                        TemplateSection(heading: "Hypothesis", hint: "If … then … because …", weight: 0.5),
                                        TemplateSection(heading: "Variables", hint: "Independent · Dependent · Controlled", weight: 0.6),
                                        TemplateSection(heading: "Materials & risk assessment", hint: "Equipment, hazards and how you'll manage them", weight: 0.7),
                                        TemplateSection(heading: "Method", hint: "Numbered steps someone else could repeat", weight: 1.0),
                                        TemplateSection(heading: "Results", hint: "Table with units in the headings, then a graph", weight: 1.2),
                                        TemplateSection(heading: "Discussion", hint: "Trends, errors, validity, reliability, improvements", weight: 1.0),
                                        TemplateSection(heading: "Conclusion", hint: "Answer the aim. Was the hypothesis supported?", weight: 0.5),
                                     ]))
            list.append(NoteTemplate(id: "science.concept", title: "Concept Notes", symbol: "atom", detail: "Key terms, diagram, explanation",
                                     pattern: "ruled", sections: [
                                        TemplateSection(heading: "Key terms", hint: "Term — definition", weight: 0.9),
                                        TemplateSection(heading: "Diagram", hint: "Draw and label it (or ask your tutor for one)", weight: 1.3),
                                        TemplateSection(heading: "How it works", hint: "Explain the process step by step", weight: 1.0),
                                        TemplateSection(heading: "Real-world example", hint: nil, weight: 0.5),
                                     ]))
        case .geography:
            list.append(NoteTemplate(id: "geo.casestudy", title: "Case Study", symbol: "globe.asia.australia", detail: "Place, causes, impacts, management",
                                     pattern: "ruled", sections: [
                                        TemplateSection(heading: "Location", hint: "Where is it? Map it, with BOLTSS", weight: 1.1),
                                        TemplateSection(heading: "Causes / processes", hint: nil, weight: 0.8),
                                        TemplateSection(heading: "Impacts", hint: "Social · Economic · Environmental (with data)", weight: 1.0),
                                        TemplateSection(heading: "Responses & management", hint: "Who did what? How sustainable is it?", weight: 0.8),
                                        TemplateSection(heading: "Key statistics", hint: "Numbers with sources", weight: 0.5),
                                     ]))
            list.append(NoteTemplate(id: "geo.biome", title: "Biome Profile", symbol: "leaf", detail: "Climate, vegetation, soils, people",
                                     pattern: "ruled", sections: [
                                        TemplateSection(heading: "Where it's found", hint: "Describe the distribution: pattern, examples, anomalies", weight: 1.0),
                                        TemplateSection(heading: "Climate", hint: "Insert a climate graph for a place in this biome", weight: 1.2),
                                        TemplateSection(heading: "Vegetation, animals & soils", hint: "Adaptations to the climate", weight: 0.8),
                                        TemplateSection(heading: "How people use it", hint: "Food, resources, threats", weight: 0.7),
                                        TemplateSection(heading: "Sustainability", hint: "Management and the future", weight: 0.6),
                                     ]))
        case .history:
            list.append(NoteTemplate(id: "history.source", title: "Source Analysis", symbol: "doc.text.magnifyingglass", detail: "Origin, purpose, perspective, usefulness",
                                     pattern: "ruled", sections: [
                                        TemplateSection(heading: "The source", hint: "Paste, scan or describe it", weight: 1.2),
                                        TemplateSection(heading: "Origin", hint: "Who made it, when, where, what type", weight: 0.5),
                                        TemplateSection(heading: "Purpose & audience", hint: "Why was it made? For whom?", weight: 0.5),
                                        TemplateSection(heading: "Perspective", hint: "Whose point of view? What's left out?", weight: 0.6),
                                        TemplateSection(heading: "Usefulness & reliability", hint: "Useful for what? Can it be trusted? Why?", weight: 0.8),
                                     ]))
            list.append(NoteTemplate(id: "history.event", title: "Event Notes", symbol: "calendar", detail: "Causes, events, consequences, significance",
                                     pattern: "ruled", sections: [
                                        TemplateSection(heading: "Context", hint: "When and where; what led up to it", weight: 0.7),
                                        TemplateSection(heading: "Causes", hint: "Short-term and long-term", weight: 0.8),
                                        TemplateSection(heading: "Key events", hint: "Timeline with dates", weight: 1.0),
                                        TemplateSection(heading: "Consequences", hint: nil, weight: 0.8),
                                        TemplateSection(heading: "Significance", hint: "Why does it matter? Different perspectives", weight: 0.6),
                                     ]))
        case .english:
            list.append(NoteTemplate(id: "english.teel", title: "TEEL Paragraph", symbol: "text.alignleft", detail: "Topic, explanation, evidence, link",
                                     pattern: "ruled", sections: [
                                        TemplateSection(heading: "Question", hint: "Copy the question; underline its key words", weight: 0.5),
                                        TemplateSection(heading: "Topic sentence", hint: "Your argument for this paragraph", weight: 0.5),
                                        TemplateSection(heading: "Explanation", hint: "Unpack the idea", weight: 0.7),
                                        TemplateSection(heading: "Evidence", hint: "Quote + technique + effect on the reader", weight: 1.0),
                                        TemplateSection(heading: "Link", hint: "Back to the question", weight: 0.4),
                                     ]))
            list.append(NoteTemplate(id: "english.text", title: "Text Study", symbol: "book", detail: "Themes, characters, techniques, quotes",
                                     pattern: "ruled", sections: [
                                        TemplateSection(heading: "Context", hint: "Author, time, purpose", weight: 0.6),
                                        TemplateSection(heading: "Themes", hint: nil, weight: 0.8),
                                        TemplateSection(heading: "Characters", hint: nil, weight: 0.8),
                                        TemplateSection(heading: "Key quotes", hint: "Quote · technique · effect", weight: 1.2),
                                     ]))
        case .computing:
            list.append(NoteTemplate(id: "computing.lab", title: "Code Lab", symbol: "chevron.left.forwardslash.chevron.right", detail: "Problem, algorithm, code, testing",
                                     pattern: "dots", sections: [
                                        TemplateSection(heading: "Problem", hint: "Inputs, processing, outputs", weight: 0.6),
                                        TemplateSection(heading: "Algorithm", hint: "Pseudocode or a flowchart", weight: 1.0),
                                        TemplateSection(heading: "Code", hint: "Insert → Code Block to write and run Python", weight: 1.3),
                                        TemplateSection(heading: "Testing", hint: "Test data: normal, boundary, erroneous — expected vs actual", weight: 0.8),
                                     ]))
            list.append(NoteTemplate(id: "computing.trace", title: "Desk Check", symbol: "tablecells", detail: "Trace an algorithm step by step",
                                     pattern: "grid", sections: [
                                        TemplateSection(heading: "Algorithm", hint: "Copy or scan it", weight: 1.0),
                                        TemplateSection(heading: "Trace table", hint: "One column per variable, plus output", weight: 1.5),
                                        TemplateSection(heading: "What it does", hint: "In one sentence", weight: 0.4),
                                     ]))
        case .pdhpe:
            list.append(NoteTemplate(id: "pdhpe.topic", title: "Topic Notes", symbol: "heart.text.square", detail: "Key terms, factors, strategies",
                                     pattern: "ruled", sections: [
                                        TemplateSection(heading: "Key terms", hint: nil, weight: 0.8),
                                        TemplateSection(heading: "Factors", hint: "What influences it?", weight: 0.9),
                                        TemplateSection(heading: "Strategies & actions", hint: nil, weight: 0.9),
                                        TemplateSection(heading: "Examples", hint: nil, weight: 0.6),
                                     ]))
        case .other:
            break
        }
        list.append(NoteTemplate(id: "\(kind.rawValue).cornell", title: "Cornell Notes", symbol: "rectangle.split.2x1", detail: "Cues, notes and a summary",
                                 pattern: "cornell", sections: []))
        list.append(NoteTemplate(id: "\(kind.rawValue).blurt", title: "Blurt", symbol: "brain.head.profile", detail: "Write everything you remember, then check it against your notes",
                                 pattern: kind == .maths ? "grid" : "ruled", sections: [
                                    TemplateSection(heading: "Everything I remember", hint: "No notes! Write it all down, then tap Check Blurt", weight: 1),
                                 ], isBlurt: true))
        return list
    }

    // MARK: Tutor guidance

    /// The subject-specific part of the tutor's system prompt. Fixed for a conversation, so it is
    /// cached after the shared base prompt.
    func tutorGuidance(curriculum: Curriculum, year: Int, subjectName: String) -> String {
        var s = "Subject: \(subjectName)"
        if subjectName.lowercased() != kind.title.lowercased() && kind != .other { s += " (\(kind.title))" }
        s += "\n" + curriculum.studentLine(year: year) + "\n\n"
        s += specialist
        if curriculum == .nsw { s += "\n\n" + SubjectProfile.nesaKeyWords }
        return s
    }

    /// NESA's glossary of key words, which NSW questions are built on.
    static let nesaKeyWords = """
    NESA key words (use them in questions; teach the student to answer to the key word):
    identify (recognise and name) · outline (sketch in general terms) · describe (provide characteristics and features) · explain (relate cause and effect; make the relationships between things evident; provide why and/or how) · compare (show how things are similar and different) · contrast (show how things are different or opposite) · discuss (identify issues and provide points for and/or against) · analyse (identify components and the relationship between them; draw out and relate implications) · assess (make a judgement of value, quality, outcomes, results or size) · evaluate (make a judgement based on criteria; determine the value of) · justify (support an argument or conclusion) · account for (state reasons for, report on) · predict (suggest what may happen based on available information) · calculate (ascertain/determine from given facts, figures or information).
    """

    var specialist: String {
        switch kind {
        case .maths:
            return """
            You are a specialist maths tutor.
            - Show every step and keep working aligned (write_math). Be exact; re-check arithmetic and algebra before marking anything wrong.
            - Graph functions accurately with `graph`; use `geometry` for figures with labelled sides and angles; `number_line` for inequalities; `table` for tables of values.
            - Practice questions start easy and build to exam level, with full worked solutions in the hidden solution. Mark method as well as answer: say which step earned or lost marks.
            - Encourage estimation and checking answers (substitute back, check units, does it make sense?).
            """
        case .science:
            return """
            You are a specialist science tutor (biology, chemistry, physics, earth and space). The course includes disease: pathogens (bacteria, viruses, fungi, protists, parasites), how disease spreads, the body's defences (first, second and third lines of defence), immunity and vaccination, antibiotics and resistance, and non-infectious disease, as well as body systems and coordination.
            - Be scientifically precise and use the right terms (then define them simply). Correct misconceptions explicitly (e.g. antibiotics don't kill viruses; vaccines train the immune system, they don't cure).
            - Use visuals: `find_diagram` for a real diagram (cells, organs, pathogens, body systems, apparatus) then `label_diagram` to label it — or to turn it into a labelling quiz; `flowchart` for processes and sequences (immune response, disease transmission, stimulus → response, the scientific method); `map` with real data for where diseases occur (malaria, TB, HIV, vaccination rates); `chart` for experimental results (line graph for continuous variables, column graph for categories); `write_math` for calculations, always with units.
            - Working scientifically: help plan fair tests (independent, dependent and controlled variables), hypotheses as "If … then … because …", risk assessments, results tables with units in the column headings, graphs with labelled axes and a line of best fit, and discussions of validity, reliability and accuracy. Use the Practical Report template's structure.
            - Exam answers: answer to the key word; "explain" needs a because/therefore chain; use data from the question as evidence.
            """
        case .geography:
            return """
            You are a specialist geography tutor. Geographical concepts: place, space, environment, interconnection, scale, sustainability, change. Stage 5 topics include sustainable biomes, changing places (urbanisation, migration), environmental change and management, and human wellbeing.
            - Use real maps and data: `map` with a real dataset (population, GDP, life expectancy, HDI, CO2, forest cover, urbanisation, disease…) or climate zones, never invented numbers; `climate_graph` for any place's real climate (biomes!); `chart` for other statistics. Always say where data comes from and its year.
            - Maps follow BOLTSS: border, orientation (north arrow), legend, title, scale, source. Teach latitude and longitude, area and grid references, direction and distance, and reading topographic maps when relevant.
            - Describing a distribution or pattern: General trend, specific Examples with data, and Anomalies. Describing a climate graph: total annual rainfall, wettest/driest months, temperature range and maximum/minimum, and the season pattern.
            - Push for specific places and statistics as evidence, interconnections between people and environments, and judgements about sustainability.
            """
        case .history:
            return """
            You are a specialist history tutor (The Making of the Modern World: e.g. the Industrial Revolution, movement of peoples, Australia and Asia, World War I and II, rights and freedoms).
            - Historical concepts: continuity and change, cause and effect, perspectives, empathetic understanding, significance, contestability. Ask the student to use them.
            - Source analysis: origin, purpose, audience, perspective, context, and usefulness versus reliability (a biased source can still be useful). Annotate sources on the page; ask questions rather than writing the analysis for them.
            - Timelines with `flowchart` (direction right) or `table`; causes and consequences with `flowchart`. Maps from `map` show today's borders: say so when it matters.
            - Extended responses: a clear argument (thesis), TEEL/PEEL paragraphs, specific evidence (dates, names, statistics, quotes from sources), and a judgement that answers the key word.
            - Be accurate with dates and facts; if unsure, say so rather than guess.
            """
        case .english:
            return """
            You are a specialist English tutor. Work with the student's own writing; never write their essay, paragraph or creative piece for them.
            - Feedback like a teacher with a pen: underline or bracket specific phrases and add short margin comments (what works and why, what to improve), then one clear next step. Use `annotate` and short `write` notes; keep rewrites to a few words as an example.
            - Analytical writing: a thesis that answers the question, TEEL paragraphs (Topic sentence, Explanation, Evidence — quote + technique + effect on the responder, Link), embedded quotations, analysis of how meaning is shaped, sophisticated vocabulary, and a strong conclusion.
            - Know techniques and their effects (imagery, metaphor, symbolism, motif, juxtaposition, tone, characterisation, narrative voice, structure, rhetorical devices, film techniques).
            - Creative writing: show don't tell, purposeful structure, vivid detail, varied sentences. Persuasive writing: audience, purpose, appeals and devices.
            - Correct spelling, grammar and punctuation sparingly and specifically (circle the error, name the rule).
            """
        case .computing:
            return """
            You are a specialist Computing Technology tutor: programming in Python, algorithms (pseudocode and flowcharts), data (binary, hexadecimal, ASCII, data types), networks, the web, user experience, privacy and security, and project work (designing, building, testing, evaluating).
            - Code blocks are on the page as typed code with line numbers. Read the student's code exactly; run it with `run_code` before claiming what it outputs or where it fails.
            - Teach debugging: point at the line (annotate) and ask a question that leads to the fix; explain the error message in plain words. Don't rewrite the student's whole program; give a small example of the idea instead.
            - Use `code` for short examples (keep them small and runnable), `flowchart` for algorithms (decision diamonds for IF/WHILE), `table` for trace tables (desk checks) and truth tables, and NESA-style pseudocode (BEGIN/END, IF … THEN … ELSE … ENDIF, WHILE … ENDWHILE, FOR … NEXT, DISPLAY, GET) when asked.
            - Encourage good habits: meaningful names, comments, testing with normal, boundary and erroneous data, and breaking problems into functions.
            """
        case .pdhpe:
            return """
            You are a specialist PDHPE tutor (personal development, health and physical education): health and wellbeing, body systems and movement, nutrition, mental health, relationships, safety and risk, and health promotion.
            - Be accurate and sensitive. Use diagrams for body systems (`find_diagram` + `label_diagram`) and flowcharts for processes.
            - Extended responses: answer to the key word, use specific examples and strategies, and link factors to outcomes.
            """
        case .other:
            return """
            Adapt to the subject from the student's notes: use its vocabulary, teach the key ideas clearly, check understanding with questions, and use diagrams, tables and flowcharts where they help.
            """
        }
    }
}
