import UIKit

/// Feature checks for subjects and the subject tools: templates, the subject Ask menus, and the
/// flowchart and labelling tools run through the real executor and renderer.
extension DemoDirector {
    func checkSubjects(_ model: EditorModel, _ library: LibraryStore) async {
        // Subject kinds, menus and guidance.
        let science = Subject(name: "Science", colorHex: SubjectKind.science.defaultColorHex, kind: .science)
        let menu = TutorQuickAction.menu(for: .science)
        FeatureCheck.check("science Ask menu", menu.count == 8 && menu.contains(.diagram) && menu.contains(.processChart), "\(menu.map(\.rawValue))")
        FeatureCheck.check("computing Ask menu", TutorQuickAction.menu(for: .computing).contains(.debug))
        let guidance = SubjectProfile.of(.geography).tutorGuidance(curriculum: .nsw, year: 9, subjectName: "Geography")
        FeatureCheck.check("subject guidance", guidance.contains("Stage 5") && guidance.contains("BOLTSS"))
        FeatureCheck.check("base prompt has tool guidance", TutorPrompts.system.contains("find_diagram") && TutorPrompts.system.contains("`map`"))

        // Templates: a practical report spreads over two pages of headed sections.
        if let prac = science.profile.templates.first(where: { $0.id == "science.prac" }) {
            let meta = library.createNote(from: prac, subject: science, paperColor: .white)
            Storage.ioQueue.sync {}  // the note is written in the background
            let doc = NoteDocument.load(meta: meta)
            let texts = doc.content.elements.filter { if case .text = $0.kind { return true }; return false }
            FeatureCheck.check("practical report template", doc.content.pages.count == 2 && texts.count >= 17,
                               "\(doc.content.pages.count) pages, \(texts.count) text items")
            library.delete(meta)
        } else {
            FeatureCheck.check("practical report template", false, "missing")
        }
        if let blurt = science.profile.templates.first(where: \.isBlurt) {
            let meta = library.createNote(from: blurt, subject: science, paperColor: .white)
            FeatureCheck.check("blurt template", meta.isBlurt)
            library.delete(meta)
        }

        // Tools through the executor, then a snapshot render of the page (draws every element).
        let doc = model.document
        let executor = model.tutor.executor
        func run(_ name: String, _ json: String) async -> CanvasActionExecutor.Outcome? {
            guard let input = try? JSONValue.parse(json) else { return nil }
            return await executor.perform(toolID: "check-\(name)", name: name, input: input)
        }
        let before = doc.content.elements.count
        let flow = await run("flowchart", """
        {"page": 1, "x": 80, "y": 120, "title": "Is it a fever?", "nodes": [
          {"id": "s", "text": "Take temperature", "shape": "terminal"},
          {"id": "q", "text": "Above 38 °C?", "shape": "decision"},
          {"id": "y", "text": "Rest, fluids, see a doctor if it lasts"},
          {"id": "n", "text": "Normal", "shape": "terminal"}],
         "edges": [{"from": "s", "to": "q"}, {"from": "q", "to": "y", "label": "Yes"}, {"from": "q", "to": "n", "label": "No"}, {"from": "y", "to": "s", "label": "next day"}]}
        """)
        let flowEl = doc.content.elements.last
        var isFlow = false
        if case .flowchart(let f) = flowEl?.kind { isFlow = f.nodes.count == 4 && f.edges.count == 4 }
        FeatureCheck.check("flowchart tool", flow?.isError == false && isFlow && doc.content.elements.count == before + 1,
                           flow?.result.prefix(160).description ?? "nil")
        let bad = await run("flowchart", #"{"nodes": [{"id": "a", "text": "A"}], "edges": [{"from": "a", "to": "zz"}]}"#)
        FeatureCheck.check("flowchart rejects unknown ids", bad?.isError == true && bad?.result.contains("zz") == true)
        let cycle = await run("flowchart", #"{"page": 1, "y": 560, "direction": "cycle", "nodes": [{"id": "e", "text": "Evaporation", "shape": "circle"}, {"id": "c", "text": "Condensation", "shape": "circle"}, {"id": "p", "text": "Precipitation", "shape": "circle"}, {"id": "r", "text": "Collection", "shape": "circle"}]}"#)
        FeatureCheck.check("cycle flowchart", cycle?.isError == false, cycle?.result.prefix(120).description ?? "nil")

        let labels = await run("label_diagram", """
        {"page": 1, "x": 300, "y": 760, "width": 200, "height": 160, "quiz": true, "labels": [
          {"text": "Nucleus", "x": 400, "y": 840}, {"text": "Cell membrane", "x": 305, "y": 800}, {"text": "Cytoplasm", "x": 470, "y": 880}]}
        """)
        var quizOK = false
        if case .labels(let l) = doc.content.elements.last?.kind {
            quizOK = l.quiz && l.labels.count == 3 && LabelRenderer.tutorDescription(l, frame: doc.content.elements.last!.frame).contains("hidden answer \"Nucleus\"")
        }
        FeatureCheck.check("label quiz tool", labels?.isError == false && quizOK, labels?.result.prefix(160).description ?? "nil")
        let outside = await run("label_diagram", #"{"page": 1, "x": 300, "y": 760, "width": 200, "height": 160, "labels": [{"text": "Far", "x": 20, "y": 20}]}"#)
        FeatureCheck.check("labels must point at the picture", outside?.isError == true)

        // Code blocks: placed and drawn, then Python itself in the hidden web view (it needs the
        // network the first time; if it can't start, that's reported rather than failed).
        let code = await run("code", #"{"page": 1, "x": 60, "y": 40, "title": "Loop", "code": "for i in range(3):\n    print(i * i)"}"#)
        var codeOK = false
        if case .code(let c) = doc.content.elements.last?.kind { codeOK = c.code.contains("range(3)") && (doc.content.elements.last?.frame.height ?? 0) > 60 }
        FeatureCheck.check("code tool", code?.isError == false && codeOK, code?.result.prefix(160).description ?? "nil")
        let python = await PythonRunner.shared.run("name = input('Name? ')\nprint('Hi', name, 6 * 7)", stdin: ["Sam"], timeout: 60)
        if python.status == .unavailable {
            FeatureCheck.info("python unavailable in the simulator: \(python.error ?? python.detail ?? "")")
        } else {
            FeatureCheck.check("python runs", python.status == .finished && python.output.contains("Hi Sam 42"),
                               "\(python.status.rawValue) in \(String(format: "%.1f", python.seconds))s: \(python.output.prefix(80)) \(python.error ?? "")")
            let loop = await PythonRunner.shared.run("while True:\n    pass", stdin: [], timeout: 2)
            FeatureCheck.check("python stops a stuck loop", loop.status == .timedOut, loop.status.rawValue)
            let err = await PythonRunner.shared.run("x = 1\nprint(y)", stdin: [], timeout: 10)
            FeatureCheck.check("python error is cleaned", err.status == .failed && (err.error ?? "").contains("NameError") && (err.error ?? "").contains("Line 2"),
                               err.error?.prefix(120).description ?? "nil")
        }

        // Maps and charts from bundled data (no network needed).
        let map = await run("map", #"{"page": 2, "region": "australia", "layer": "climate_zones", "markers": [{"place": "Sydney"}, {"place": "Alice Springs"}]}"#)
        var mapOK = false
        if case .map = doc.content.elements.last?.kind { mapOK = true }
        FeatureCheck.check("map tool (Australia climate zones)", map?.isError == false && mapOK, map?.result.prefix(200).description ?? "nil")
        let outline = await run("map", #"{"page": 2, "y": 560, "region": "world", "layer": "outline"}"#)
        FeatureCheck.check("blank world outline map", outline?.isError == false, outline?.result.prefix(120).description ?? "nil")
        let chart = await run("chart", #"{"page": 2, "type": "line", "title": "Cooling water", "x_label": "Time (min)", "y_label": "Temperature (°C)", "categories": ["0", "2", "4", "6"], "series": [{"name": "Beaker A", "values": [80, 66, 55, 47]}], "source": "Class experiment"}"#)
        FeatureCheck.check("chart tool (inline experiment data)", chart?.isError == false, chart?.result.prefix(120).description ?? "nil")
        let mapSnap = PageRenderer.snapshot(doc, page: 1)
        FeatureCheck.check("render maps and charts", mapSnap != nil && (mapSnap?.jpeg.count ?? 0) > 20000, "\(mapSnap?.jpeg.count ?? 0) bytes")
        // Real data over the network: reported, not failed, if the service is down.
        let climate = await run("climate_graph", #"{"page": 2, "place": "Dubbo, NSW"}"#)
        if climate?.isError == false {
            FeatureCheck.check("climate graph (Open-Meteo)", climate?.result.contains("mm") == true, climate?.result.prefix(160).description ?? "")
        } else {
            FeatureCheck.info("climate graph unavailable: \(climate?.result.prefix(160) ?? "nil")")
        }
        let hdi = await run("map", #"{"page": 2, "region": "world", "layer": "data", "dataset": "hdi"}"#)
        if hdi?.isError == false {
            FeatureCheck.check("data map (HDI)", hdi?.result.contains("Australia") == true, hdi?.result.prefix(200).description ?? "")
        } else {
            FeatureCheck.info("data map unavailable: \(hdi?.result.prefix(160) ?? "nil")")
        }

        let snap = PageRenderer.snapshot(doc, page: 0)
        FeatureCheck.check("render subject tools", snap != nil && (snap?.jpeg.count ?? 0) > 5000, "\(snap?.jpeg.count ?? 0) bytes")
        FeatureCheck.info("flowchart: \(FlowchartRenderer.tutorDescription(flowElement(doc) ?? FlowchartContent(nodes: [], edges: []), frame: flowEl?.frame ?? .zero).prefix(200))")

        // Clean up.
        for e in doc.content.elements.dropFirst(before) { doc.remove(e.id) }
        await wait(0.3)
    }

    private func flowElement(_ doc: NoteDocument) -> FlowchartContent? {
        for e in doc.content.elements {
            if case .flowchart(let f) = e.kind { return f }
        }
        return nil
    }
}
