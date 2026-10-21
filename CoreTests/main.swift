import Foundation

var failures = 0
var passes = 0
func check(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if cond { passes += 1 } else { failures += 1; print("FAIL [\(line)]: \(msg)") }
}
func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol * max(1, abs(b)) }

// MARK: JSON
do {
    let v = try JSONValue.parse(#"{"a": [1, 2.5, -3e2, true, false, null], "b": "héllo \"q\" \n 😀", "c": {}}"#)
    check(v["a"]?[0] == .number(1), "json int")
    check(v["a"]?[2] == .number(-300), "json exp")
    check(v["a"]?[3] == .bool(true), "json bool")
    check(v["a"]?[5] == .null, "json null")
    check(v["b"]?.stringValue == "héllo \"q\" \n 😀", "json string escapes: \(v["b"]?.stringValue ?? "nil")")
    let s = v.serialized()
    check(s == #"{"a":[1,2.5,-300,true,false,null],"b":"héllo \"q\" \n 😀","c":{}}"#, "serialize: \(s)")
    let round = try JSONValue.parse(s)
    check(round == v, "roundtrip")
} catch { check(false, "json parse threw \(error)") }

do {
    _ = try JSONValue.parse(#"{"a": 1"#)
    check(false, "strict should throw on truncated")
} catch { check(true, "") }

do {
    let p = JSONValue.parsePartial(#"{"page": 1, "x": 40, "y": 120, "text": "Let's fac"#)
    check(p?["text"]?.stringValue == "Let's fac", "partial string: \(String(describing: p))")
    check(p?["x"]?.doubleValue == 40, "partial number")
    let p2 = JSONValue.parsePartial(#"{"page": 1, "te"#)
    check(p2?["page"] == .number(1) && p2?["te"] == nil, "partial dangling key \(String(describing: p2))")
    let p3 = JSONValue.parsePartial(#"{"lines": ["x^2", "2x"#)
    check(p3?["lines"]?.arrayValue?.count == 2, "partial array \(String(describing: p3))")
    let p4 = JSONValue.parsePartial(#"{"text": "abc\"#)
    check(p4?["text"]?.stringValue == "abc", "partial escape \(String(describing: p4))")
    let p5 = JSONValue.parsePartial(#"{"a": tr"#)
    check(p5 != nil && p5?["a"] == nil, "partial literal \(String(describing: p5))")
    let p6 = JSONValue.parsePartial(#"{"x": 12."#)
    check(p6?["x"] == nil || p6?["x"] == .number(12), "partial number dot")
}

check(JSONValue.formatNumber(3) == "3", "fmt int")
check(JSONValue.formatNumber(0.1) == "0.1", "fmt frac")

// MARK: Expressions
func ev(_ s: String, _ x: Double) -> Double {
    do { return try ExpressionParser.parse(s).evaluate(x: x) } catch { print("parse error \(s): \(error)"); return .nan }
}
check(approx(ev("2x^2 - 3x + 1", 2), 3), "poly")
check(approx(ev("y = x^2", 3), 9), "y= prefix")
check(approx(ev("f(x) = 2x+1", 3), 7), "f(x)= prefix")
check(approx(ev("-x^2", 3), -9), "unary minus precedence")
check(approx(ev("2^3^2", 0), 512), "right assoc power")
check(approx(ev("sin(x)/x", 1), sin(1)), "sin")
check(approx(ev("sin x", Double.pi / 2), 1), "sin without parens")
check(approx(ev("2sin(x)cos(x)", 0.3), sin(0.6)), "implicit mult funcs")
check(approx(ev("|x-2|", -1), 3), "abs bars")
check(approx(ev("\\frac{1}{x}", 4), 0.25), "latex frac")
check(approx(ev("\\sqrt{x}+x^{2}", 4), 18), "latex sqrt+braces")
check(approx(ev("e^(-x)", 1), exp(-1)), "e power")
check(approx(ev("2pi x", 1), 2 * Double.pi), "pi implicit")
check(approx(ev("xsinx", 1), sin(1)), "split identifiers")
check(approx(ev("ln(e)", 0), 1), "ln")
check(approx(ev("log(100)", 0), 2), "log10")
check(approx(ev("log2(8)", 0), 3), "log2")
check(approx(ev("x^(1/3)", -8), -2), "odd root negative")
check(approx(ev("3!", 0), 6), "factorial")
check(approx(ev("(x+1)(x-1)", 3), 8), "paren implicit")
check(approx(ev("sin^2(x)+cos^2(x)", 0.7), 1), "sin^2")
check(approx(ev("2.5e2", 0), 250), "sci notation")
check(approx(ev("2e", 0), 2 * exp(1)), "2e means 2*e")
check(approx(ev("x²+1", 2), 5), "unicode square")
check(approx(ev("1/(x-1)", 3), 0.5), "rational")
check((try? ExpressionParser.parse("2 +")) == nil, "error on dangling op")
let segs = FunctionSampler.sample(try! ExpressionParser.parse("1/x"), xMin: -5, xMax: 5, yMin: -5, yMax: 5)
check(segs.count == 2, "asymptote splits 1/x into 2 segments: \(segs.count)")
let tanSegs = FunctionSampler.sample(try! ExpressionParser.parse("tan(x)"), xMin: -6, xMax: 6, yMin: -5, yMax: 5)
check(tanSegs.count >= 4, "tan splits: \(tanSegs.count)")
let smooth = FunctionSampler.sample(try! ExpressionParser.parse("x^3"), xMin: -3, xMax: 3, yMin: -10, yMax: 10)
check(smooth.count >= 1, "x^3 segments \(smooth.count)")

// MARK: Math parser
let m1 = MathParser.parse("\\frac{1}{2}x^2")
if case .row(let items) = m1 {
    check(items.count == 2, "frac row count \(items.count)")
    if case .frac = items[0] { check(true, "") } else { check(false, "frac node") }
    if case .scripts(let base, let sup, _) = items[1] {
        check(base == .symbol("x", .ordinary, italic: true), "script base")
        check(sup == .symbol("2", .ordinary, italic: false), "script sup")
    } else { check(false, "scripts node") }
} else { check(false, "row expected \(m1)") }

let m2 = MathParser.parse("\\sum_{i=1}^{n} i^2")
if case .row(let items) = m2, case .bigOp(let sym, let lower, let upper, let above, _) = items[0] {
    check(sym == "∑" && lower != nil && upper != nil && above, "sum limits")
} else { check(false, "sum parse \(m2)") }

let m3 = MathParser.parse("\\left( \\frac{a}{b} \\right)")
if case .delimited(let l, _, let r) = m3 { check(l == "(" && r == ")", "delims") } else { check(false, "delimited \(m3)") }

let m4 = MathParser.parse("\\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix}")
if case .matrix(let rows, let l, _) = m4 {
    check(rows.count == 2 && rows[0].count == 2 && l == "(", "matrix \(rows)")
} else { check(false, "matrix parse \(m4)") }

let m5 = MathParser.parse("\\sqrt[3]{x+1} \\le \\pi")
if case .row(let items) = m5 {
    if case .sqrt(_, let idx) = items[0] { check(idx != nil, "sqrt index") } else { check(false, "sqrt") }
    check(items.contains(.symbol("≤", .relation, italic: false)), "le relation")
    check(items.contains(.symbol("π", .ordinary, italic: true)), "pi greek")
} else { check(false, "row5") }

let m6 = MathParser.parse("f'(x) = 2x - 3")
check(MathSpeech.readable("f'(x) = 2x - 3").contains("f′"), "prime: \(MathSpeech.readable("f'(x) = 2x - 3"))")
_ = m6
check(MathSpeech.readable("x^2 + \\frac{1}{2}") == "x² + (1)/(2)", "speech: \(MathSpeech.readable("x^2 + \\frac{1}{2}"))")
let m7 = MathParser.parse("\\int_0^1 x\\,dx")
if case .row(let items) = m7, case .bigOp(let sym, let lo, let up, let above, _) = items[0] {
    check(sym == "∫" && lo != nil && up != nil && !above, "integral")
} else { check(false, "integral parse \(m7)") }
let m8 = MathParser.parse("\\begin{cases} x & x > 0 \\\\ -x & x \\le 0 \\end{cases}")
if case .matrix(let rows, let l, let r) = m8 { check(rows.count == 2 && l == "{" && r == "", "cases \(rows.count)") } else { check(false, "cases \(m8)") }

// Rich text
let segsRT = RichTextParser.segments("Solve $x^2 = 4$ **now**\nthen $$y$$ costs \\$5")
check(segsRT == [.text("Solve ", bold: false), .math("x^2 = 4"), .text(" ", bold: false), .text("now", bold: true), .newline, .text("then ", bold: false), .math("y"), .text(" costs $5", bold: false)], "rich segments \(segsRT)")

// Literal "\n" from the model becomes a real line break outside math, but LaTeX inside math is untouched.
check(RichTextParser.normalizingLineBreaks("Step 1\\nStep 2") == "Step 1\nStep 2", "literal \\n")
check(RichTextParser.normalizingLineBreaks("a\\\\ b\\newline c") == "a\nb\nc", "\\\\ and \\newline")
check(RichTextParser.normalizingLineBreaks("so $x \\neq 2$ and $$a \\\\ b$$\\nNext") == "so $x \\neq 2$ and $$a \\\\ b$$\nNext", "math untouched")
check(RichTextParser.normalizingLineBreaks("costs \\$5\\r\\nok") == "costs \\$5\nok", "escaped dollar, CRLF")
check(RichTextParser.segments("One\\nTwo") == [.text("One", bold: false), .newline, .text("Two", bold: false)], "segments with literal \\n")

// MARK: Shapes
func circlePts(_ cx: Double, _ cy: Double, _ r: Double, jitter: Double = 1.5, n: Int = 80) -> [CGPoint] {
    (0...n).map { i in
        let t = Double(i) / Double(n) * 2 * .pi
        let j = sin(Double(i) * 1.7) * jitter
        return CGPoint(x: cx + (r + j) * cos(t), y: cy + (r + j) * sin(t))
    }
}
if case .ellipse(_, let rx, let ry, _) = ShapeRecognizer.recognize(circlePts(100, 100, 50)) {
    check(abs(rx - ry) < 0.6 && abs(rx - 50) < 5, "circle radius \(rx) \(ry)")
} else { check(false, "circle not recognized: \(String(describing: ShapeRecognizer.recognize(circlePts(100, 100, 50))))") }

let linePts = (0...40).map { CGPoint(x: Double($0) * 5, y: 100 + sin(Double($0)) * 1.2) }
if case .line(let a, let b) = ShapeRecognizer.recognize(linePts) {
    check(abs(a.y - b.y) < 0.5, "line snapped horizontal \(a) \(b)")
} else { check(false, "line not recognized \(String(describing: ShapeRecognizer.recognize(linePts)))") }

func polyPts(_ corners: [CGPoint], perEdge: Int = 25, jitter: Double = 1.2) -> [CGPoint] {
    var out: [CGPoint] = []
    var k = 0
    for i in 0..<corners.count {
        let a = corners[i], b = corners[(i + 1) % corners.count]
        for s in 0..<perEdge {
            let t = Double(s) / Double(perEdge)
            k += 1
            out.append(CGPoint(x: a.x + (b.x - a.x) * t + sin(Double(k)) * jitter, y: a.y + (b.y - a.y) * t + cos(Double(k) * 1.3) * jitter))
        }
    }
    out.append(corners[0])
    return out
}
let rect = polyPts([CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 120), CGPoint(x: 0, y: 120)])
if case .polygon(let pts) = ShapeRecognizer.recognize(rect) {
    check(pts.count == 4, "rect corners \(pts.count)")
} else { check(false, "rect not recognized \(String(describing: ShapeRecognizer.recognize(rect)))") }

let tri = polyPts([CGPoint(x: 0, y: 150), CGPoint(x: 90, y: 0), CGPoint(x: 180, y: 150)])
if case .polygon(let pts) = ShapeRecognizer.recognize(tri) {
    check(pts.count == 3, "triangle corners \(pts.count)")
} else { check(false, "triangle not recognized \(String(describing: ShapeRecognizer.recognize(tri)))") }

let squiggle = (0...60).map { CGPoint(x: Double($0) * 4, y: 100 + sin(Double($0) / 3) * 30) }
check(ShapeRecognizer.recognize(squiggle) == nil, "squiggle stays freeform: \(String(describing: ShapeRecognizer.recognize(squiggle)))")

let ell = (0...90).map { i -> CGPoint in let t = Double(i) / 90 * 2 * .pi; return CGPoint(x: 200 + 120 * cos(t), y: 200 + 50 * sin(t)) }
if case .ellipse(_, let rx, let ry, _) = ShapeRecognizer.recognize(ell) {
    check(rx > 100 && ry < 70, "ellipse radii \(rx) \(ry)")
} else { check(false, "ellipse not recognized \(String(describing: ShapeRecognizer.recognize(ell)))") }


// MARK: Study core
do {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let new = ReviewState(due: t0)
    check(new.isNew && new.isDue(at: t0), "new card is due")
    let again = new.reviewed(.again, now: t0)
    check(approx(again.due.timeIntervalSince(t0), 600) && again.lapses == 0, "again on new: 10 min, no lapse")
    let good1 = new.reviewed(.good, now: t0)
    check(approx(good1.interval, 1) && good1.reps == 1, "first good: 1 day (\(good1.interval))")
    let good2 = good1.reviewed(.good, now: good1.due)
    check(approx(good2.interval, 3), "second good: 3 days (\(good2.interval))")
    let good3 = good2.reviewed(.good, now: good2.due)
    check(approx(good3.interval, 7.5), "third good: interval * ease (\(good3.interval))")
    let lapse = good3.reviewed(.again, now: good3.due)
    check(lapse.lapses == 1 && lapse.reps == 0 && approx(lapse.ease, 2.3), "lapse lowers ease, counts")
    let easy = new.reviewed(.easy, now: t0)
    check(approx(easy.interval, 4) && approx(easy.ease, 2.65), "easy on new: 4 days")
    var s = new
    for _ in 0..<20 { s = s.reviewed(.hard, now: s.due) }
    check(s.ease >= ReviewState.minEase - 1e-9, "ease floor \(s.ease)")
    var long = new
    for _ in 0..<30 { long = long.reviewed(.easy, now: long.due) }
    check(long.interval <= ReviewState.maxIntervalDays, "interval cap \(long.interval)")
    check(ReviewState.shortInterval(600) == "10m" && ReviewState.shortInterval(6 * 3600) == "6h" && ReviewState.shortInterval(3 * 86400) == "3d",
          "interval labels")
    check(new.preview(.good, now: t0) == "1d", "preview \(new.preview(.good, now: t0))")

    check(TopicStats.key("  Factorising. ") == "factorising", "topic key")
    check(TopicStats.key("Completing-the square") == "completing the square", "topic key punctuation")
    let day = 86_400.0
    let attempts = [
        TopicAttempt(topic: "Factorising", subjectID: nil, earned: 2, possible: 2, date: t0),
        TopicAttempt(topic: "factorising", subjectID: nil, earned: 1, possible: 2, date: t0.addingTimeInterval(day)),
        TopicAttempt(topic: "Completing the square", subjectID: nil, earned: 0, possible: 3, date: t0.addingTimeInterval(day)),
        TopicAttempt(topic: "Completing the square", subjectID: nil, earned: 1, possible: 3, date: t0.addingTimeInterval(2 * day)),
        TopicAttempt(topic: "Nothing", subjectID: nil, earned: 0, possible: 0, date: t0),
    ]
    let stats = TopicStats.summarize(attempts, now: t0.addingTimeInterval(2 * day))
    check(stats.count == 2, "two topics (zero-mark attempts ignored): \(stats.count)")
    let fac = stats.first { $0.key == "factorising" }
    check(fac?.attempts == 2 && fac?.topic == "factorising" && fac.map { $0.score > 0.5 && $0.score < 1 } == true, "factorising stat \(String(describing: fac))")
    let weak = TopicStats.weakest(stats)
    check(weak.first?.key == "completing the square", "weakest first \(weak.map(\.key))")
    let recent = TopicStats.summarize([TopicAttempt(topic: "a", subjectID: nil, earned: 0, possible: 1, date: t0),
                                       TopicAttempt(topic: "a", subjectID: nil, earned: 1, possible: 1, date: t0.addingTimeInterval(42 * day))],
                                      now: t0.addingTimeInterval(42 * day))
    check(approx(recent[0].score, 0.8, 1e-6), "recency weighting: 6-week-old attempt counts a quarter (\(recent[0].score))")

    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let today = t0
    let keys = Set((0..<3).map { StudyStreak.dayKey(today.addingTimeInterval(-Double($0) * day), calendar: cal) })
    check(StudyStreak.current(days: keys, today: today, calendar: cal) == 3, "streak 3")
    check(StudyStreak.current(days: keys, today: today.addingTimeInterval(day), calendar: cal) == 3, "streak holds until the day ends")
    check(StudyStreak.current(days: keys, today: today.addingTimeInterval(2 * day), calendar: cal) == 0, "streak broken")
    let log = [StudyStreak.dayKey(today, calendar: cal): 1800.0, StudyStreak.dayKey(today.addingTimeInterval(-3 * day), calendar: cal): 3600.0,
               StudyStreak.dayKey(today.addingTimeInterval(-9 * day), calendar: cal): 999.0]
    check(approx(StudyStreak.seconds(in: log, lastDays: 7, today: today, calendar: cal), 5400), "week seconds")
    check(StudyStreak.duration(5400) == "1h 30m" && StudyStreak.duration(120) == "2m" && StudyStreak.duration(7200) == "2h", "durations")
}

// Shape bar resizing scales about the centre.
let triShape = RecognizedShape.polygon([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 100)])
let triBounds = triShape.scaled(by: 2).bounds
check(abs(triBounds.width - 200) < 1 && abs(triBounds.midX - 50) < 1 && abs(triBounds.midY - 50) < 1, "scaled triangle \(triBounds)")
if case .ellipse(_, let rx, let ry, _) = RecognizedShape.ellipse(center: CGPoint(x: 10, y: 10), rx: 20, ry: 10, rotation: 0).scaled(by: 0.5) {
    check(abs(rx - 10) < 0.01 && abs(ry - 5) < 0.01, "scaled ellipse")
}

// Geometry labels: θ goes inside its angle, side labels outside their side, in either winding order.
for tri in [[CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 100), CGPoint(x: 100, y: 300)],
            [CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 300), CGPoint(x: 400, y: 100)]] {
    let poly = tri
    let label = CGSize(width: 18, height: 22)
    let right = poly.firstIndex(of: CGPoint(x: 100, y: 100))!
    check(GeometryLayout.isRightAngle(poly, right), "right angle detected")
    for i in poly.indices {
        let c = GeometryLayout.angleLabelCenter(poly, i, labelSize: label, arcRadius: GeometryLayout.arcRadius(poly, i))
        check(GeometryLayout.isInside(c, poly), "angle label \(i) inside \(c)")
        let v = GeometryLayout.vertexLabelCenter(poly, i, labelSize: label)
        check(!GeometryLayout.isInside(v, poly), "vertex label \(i) outside \(v)")
        let s = GeometryLayout.sideLabelCenter(poly, side: i, labelSize: label)
        check(!GeometryLayout.isInside(s, poly), "side label \(i) outside \(s)")
        let arc = GeometryLayout.angleArc(poly, i, radius: 15)
        let mid = arc[arc.count / 2]
        check(GeometryLayout.isInside(mid, poly), "arc \(i) sweeps inside")
    }
}
// A reflex corner: the label still goes inside the shape.
let arrowhead = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 100), CGPoint(x: 0, y: 200), CGPoint(x: 60, y: 100)]
let reflex = GeometryLayout.interiorBisector(arrowhead, 3)
check(reflex.angle > .pi, "reflex angle \(reflex.angle)")
check(GeometryLayout.isInside(GeometryLayout.angleLabelCenter(arrowhead, 3, labelSize: CGSize(width: 16, height: 20), arcRadius: 10), arrowhead), "reflex label inside")

print("passes: \(passes), failures: \(failures)")
exit(failures == 0 ? 0 : 1)
