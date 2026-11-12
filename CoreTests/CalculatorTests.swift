import Foundation

/// The fx-82AU PLUS II replica: exact numbers, parsing and priority, functions, display formats,
/// memories, STAT and VERIF, driven key by key the way a student would press them.
func runCalculatorTests() {
    calcValueTests()
    calcBasicKeyTests()
    calcNaturalDisplayTests()
    calcFunctionTests()
    calcFormatTests()
    calcMemoryTests()
    calcStatTests()
    calcVerifyAndErrorTests()
    calcEditorTests()
}

/// Flattens a line to text: fractions as (a)/(b), roots as √(x), powers as ^(n).
private func flat(_ line: CalcLine?) -> String {
    guard let line else { return "nil" }
    return line.nodes.map { n -> String in
        switch n {
        case .token(let t): return t.label
        case .template(let k, let s):
            let parts = s.map { flat($0) }
            switch k {
            case .fraction: return "(\(parts[0]))/(\(parts[1]))"
            case .mixed: return "\(parts[0])⌟\(parts[1])⌟\(parts[2])"
            case .sqrt: return "√(\(parts[0]))"
            case .cbrt: return "∛(\(parts[0]))"
            case .root: return "(\(parts[0]))√(\(parts[1]))"
            case .power: return "^(\(parts[0]))"
            case .tenPower: return "10^(\(parts[0]))"
            case .ePower: return "e^(\(parts[0]))"
            case .logBase: return "log_(\(parts[0]))(\(parts[1]))"
            case .abs: return "|\(parts[0])|"
            case .exp10: return "×10^(\(parts[0]))"
            }
        }
    }.joined()
}

private func machine(_ io: CalcIOMode = .mathO) -> CalcMachine {
    var mem = CalcMemory()
    mem.settings.io = io
    var m = CalcMachine(memory: mem)
    m.random = { 0.5 }
    return m
}

private func press(_ m: inout CalcMachine, _ keys: [CalcKey]) {
    for k in keys { m.press(k) }
}

private func shown(_ m: CalcMachine) -> String {
    switch m.display.content {
    case .calc(_, _, let result, _, _): return flat(result)
    case .message(let lines): return lines.first ?? ""
    case .menu(let items, _): return "menu:" + items.joined(separator: ",")
    case .statEditor: return "editor"
    }
}

private func run(_ keys: [CalcKey], io: CalcIOMode = .mathO) -> String {
    var m = machine(io)
    press(&m, keys)
    return shown(m)
}

private func calcValueTests() {
    let half = CalcRational(1, 2)!, third = CalcRational(1, 3)!
    check(half.adding(third) == CalcRational(5, 6), "1/2 + 1/3")
    check(CalcRational(6, -4) == CalcRational(-3, 2), "sign and reduction")
    check(CalcRational.decimal("12.375") == CalcRational(99, 8), "decimal literal")
    check(CalcRational(Int64.max / 2)!.multiplying(CalcRational(4)!) == nil, "overflow gives nil")
    check(CalcRational.approximating(0.333333333333333) == CalcRational(1, 3), "approximate 1/3")
    check(CalcRational.approximating(Double.pi) == nil, "π isn't a small fraction")

    // 1/√2 = √2/2, and (1 + √2)(1 − √2) = −1
    let r2 = try! CalcMath.sqrt(.int(2))
    check(try! CalcMath.div(.int(1), r2) == .surd(.zero, half, 2), "1/√2 rationalised")
    let a = try! CalcMath.add(.int(1), r2), b = try! CalcMath.sub(.int(1), r2)
    check(try! CalcMath.mul(a, b) == .int(-1), "conjugates multiply to −1")
    check(try! CalcMath.mul(r2, try! CalcMath.sqrt(.int(6))) == .surd(.zero, CalcRational(2)!, 3), "√2√6 = 2√3")
    check(try! CalcMath.sqrt(.rational(CalcRational(9, 4)!)) == .rational(CalcRational(3, 2)!), "√(9/4)")
    check(try! CalcMath.pow(.rational(CalcRational(-8)!), .rational(third)) == .int(-2), "(−8)^(1/3)")
    check(try! CalcMath.pow(.int(2), .int(-3)) == .rational(CalcRational(1, 8)!), "2⁻³")
    check((try? CalcMath.pow(.zero, .zero)) == nil, "0⁰ is a Math ERROR")
    check((try? CalcMath.div(.int(1), .zero)) == nil, "÷0 is a Math ERROR")
    check(try! CalcMath.add(.pi(half), .pi(half)) == .pi(.one), "π/2 + π/2")
    if case .real(let d) = try! CalcMath.add(.pi(.one), .int(1)) { check(approx(d, Double.pi + 1), "π + 1 is a decimal") } else { check(false, "π + 1 should be a decimal") }
}

private func calcBasicKeyTests() {
    check(run([.d1, .plus, .d2, .times, .d3, .equals]) == "7", "1+2×3")
    check(run([.negative, .d2, .square, .equals]) == "−4", "(−)2² = −4: squares bind tighter")
    check(run([.openParen, .negative, .d2, .closeParen, .square, .equals]) == "4", "((−)2)²")
    check(run([.d2, .openParen, .d3, .plus, .d4, .equals]) == "14", "implied ×, bracket closed at the end")
    check(run([.d5, .shift, .divide, .d2, .equals]) == "10", "5C2")
    check(run([.d5, .shift, .times, .d2, .equals]) == "20", "5P2")
    check(run([.d6, .shift, .inverse, .equals]) == "720", "6!")
    check(run([.d2, .d0, .shift, .inverse, .equals]) == "2.432902008×10^(18)", "20! in exponent form")
    // Typing an operator after a result carries on from Ans.
    var m = machine()
    press(&m, [.d7, .equals, .times, .d2, .equals])
    check(shown(m) == "14", "Ans × 2")
    if case .calc(let input, _, _, _, _) = m.display.content { check(flat(input) == "Ans×2", "input shows Ans×2") }
    // = again repeats with the new Ans.
    m.press(.equals)
    check(shown(m) == "28", "= repeats Ans×2")
    check(run([.d1, .d5, .d0, .times, .d2, .d0, .shift, .openParen, .equals]) == "30", "150×20%")
    check(run([.d1, .divide, .d2, .shift, .exp, .equals], io: .lineO) == "0.1591549431", "1÷2π: implied × binds tighter")
}

private func calcNaturalDisplayTests() {
    // 1/2 + 1/3 = 5/6, typed with the fraction template.
    check(run([.fraction, .d1, .down, .d2, .right, .plus, .fraction, .d1, .down, .d3, .equals]) == "(5)/(6)", "fraction template sum")
    check(run([.sqrt, .d8, .equals]) == "2√(2)", "√8 = 2√2")
    check(run([.sin, .d4, .d5, .equals]) == "(√(2))/(2)", "sin 45° exact")
    check(run([.cos, .d1, .d2, .d0, .equals]) == "−(1)/(2)", "cos 120° exact")
    check(run([.openParen, .d1, .plus, .sqrt, .d2, .right, .closeParen, .square, .equals]) == "3+2√(2)", "(1+√2)²")
    check(run([.shift, .exp, .divide, .d3, .equals]) == "(π)/(3)", "π÷3 stays exact")
    // S⇔D toggles to the decimal and back.
    var m = machine()
    press(&m, [.sin, .d4, .d5, .equals, .sd])
    check(shown(m) == "0.7071067812", "S⇔D to decimal")
    m.press(.sd)
    check(shown(m) == "(√(2))/(2)", "S⇔D back")
    // Mixed fractions: SHIFT S⇔D toggles a b/c and d/c.
    press(&m, [.d7, .divide, .d3, .equals])
    check(shown(m) == "(7)/(3)", "7/3 improper by default")
    press(&m, [.shift, .sd])
    check(shown(m) == "2⌟1⌟3", "a b/c toggle")
    // LineO (the factory default) shows fractions linearly.
    check(run([.d1, .divide, .d2, .d0, .d0, .equals], io: .lineO) == "1⌟200", "LineO fraction")
    check(run([.sqrt, .d2, .equals], io: .lineO) == "1.414213562", "LineO surd as decimal")
    // A decimal result's S⇔D finds the fraction.
    var d = machine(.lineO)
    press(&d, [.d0, .point, .d1, .d2, .d5, .equals])
    check(shown(d) == "1⌟8", "0.125 shown as 1⌟8 in LineO")
}

private func calcFunctionTests() {
    check(run([.logBase, .d2, .right, .d8, .equals]) == "3", "log₂8")
    check(run([.log, .d1, .d0, .d0, .d0, .equals]) == "3", "log 1000")
    check(run([.shift, .log, .d3, .equals]) == "1000", "10³ via 10^□")
    check(run([.d2, .power, .d1, .d0, .equals]) == "1024", "2^10")
    check(run([.shift, .power, .d3, .right, .d2, .d7, .equals]) == "3", "³√27 via ˣ√")
    check(run([.shift, .sqrt, .negative, .d8, .equals]) == "−2", "∛(−8)")
    check(run([.shift, .sin, .d1, .divide, .d2, .equals]) == "30", "sin⁻¹(1/2) = 30°")
    check(run([.shift, .tan, .d1, .equals]) == "45", "tan⁻¹ 1")
    check(run([.shift, .hyp, .negative, .d5, .equals]) == "5", "Abs(−5)")
    check(run([.alpha, .times, .d1, .d2, .shift, .closeParen, .d1, .d8, .equals]) == "6", "GCD(12,18)")
    check(run([.alpha, .divide, .d4, .shift, .closeParen, .d6, .equals]) == "12", "LCM(4,6)")
    check(run([.hyp, .d1, .d1, .equals], io: .lineO) == "1.175201194", "sinh 1 via the hyp menu")
    // Radians: sin(π/6) = 1/2 exactly.
    var m = machine()
    press(&m, [.shift, .mode, .d4])
    press(&m, [.sin, .shift, .exp, .divide, .d6, .equals])
    check(shown(m) == "(1)/(2)", "sin(π÷6) in Rad")
    press(&m, [.shift, .cos, .d0, .equals])
    check(shown(m) == "(π)/(2)", "cos⁻¹ 0 = π/2 in Rad")
    // DRG▶: 180° typed in Rad mode is π.
    press(&m, [.d1, .d8, .d0, .shift, .ans, .d1, .equals])
    check(shown(m) == "π", "180° in Rad")
    // Pol and Rec.
    check(run([.shift, .plus, .d1, .shift, .closeParen, .d1, .closeParen, .equals]) == "r=1.414213562, θ=45", "Pol(1,1)")
    check(run([.shift, .minus, .d2, .shift, .closeParen, .d6, .d0, .closeParen, .equals]) == "X=1, Y=1.732050808", "Rec(2,60)")
    // Sexagesimal input and the °'" display toggle.
    var s = machine()
    press(&s, [.d2, .dms, .d3, .d0, .dms, .equals])
    check(shown(s) == "(5)/(2)", "2°30° is 2.5")
    s.press(.dms)
    check(shown(s) == "2°30'0\"", "°'\" toggle")
    // Prime factorisation.
    var f = machine()
    press(&f, [.d1, .d2, .d0, .equals, .shift, .dms])
    check(shown(f) == "2^(3)×3×5", "FACT 120")
    // Random numbers use the injected source (0.5).
    check(run([.shift, .point, .equals]) == "(1)/(2)", "Ran# with 0.5")
    check(run([.alpha, .point, .d1, .shift, .closeParen, .d6, .equals]) == "4", "RanInt#(1,6) with 0.5")
}

private func calcFormatTests() {
    check(CalcFormat.decimalParts(123456789012, format: .norm(1)).0 == "1.23456789", "big mantissa")
    check(CalcFormat.decimalParts(123456789012, format: .norm(1)).1 == 11, "big exponent")
    check(CalcFormat.decimalParts(0.005, format: .norm(1)).1 == -3, "Norm 1 uses ×10 below 0.01")
    check(CalcFormat.decimalParts(0.005, format: .norm(2)) == ("0.005", nil), "Norm 2 doesn't")
    check(CalcFormat.decimalParts(1.0 / 3, format: .fix(2)) == ("0.33", nil), "Fix 2")
    check(CalcFormat.decimalParts(1.0 / 3, format: .sci(3)) == ("3.33", -1), "Sci 3")
    check(CalcFormat.decimalParts(2.0 / 3, format: .norm(1)).0 == "0.6666666667", "10 significant digits")
    var m = machine(.lineO)
    press(&m, [.d1, .d2, .d3, .d4, .equals, .eng])
    check(shown(m) == "1.234×10^(3)", "ENG")
    m.press(.eng)
    check(shown(m) == "0.001234×10^(6)", "ENG again")
    press(&m, [.shift, .eng, .shift, .eng])
    check(shown(m) == "1234×10^(0)", "←ENG")
    // Fix 2 via SETUP, then S⇔D shows the rounded decimal.
    var f = machine(.lineO)
    press(&f, [.shift, .mode, .d6, .d2, .d1, .divide, .d3, .equals])
    check(shown(f) == "1⌟3", "fraction kept in Fix")
    f.press(.sd)
    check(shown(f) == "0.33", "Fix 2 decimal")
    if case .calc = f.display.content { check(f.display.indicators.fix, "FIX indicator") }
    check(CalcFormat.factorLine(2 * 1009)! == CalcLine([.token(.digit(2)), .token(.binary(.times)), .token(.openParen), .token(.digit(1)), .token(.digit(0)), .token(.digit(0)), .token(.digit(9)), .token(.closeParen)]), "FACT leaves primes over 997 in brackets")
}

private func calcMemoryTests() {
    var m = machine()
    press(&m, [.d5, .shift, .rcl, .negative])
    check(m.memory.variables["A"] == .int(5), "STO A")
    press(&m, [.alpha, .negative, .times, .d2, .equals])
    check(shown(m) == "10", "A×2")
    press(&m, [.rcl, .negative])
    check(shown(m) == "5", "RCL A")
    press(&m, [.ac, .d3, .mPlus, .d4, .mPlus, .alpha, .mPlus, .equals])
    check(shown(m) == "7", "M+ twice then M")
    check(m.display.indicators.memory, "M indicator")
    press(&m, [.d2, .shift, .mPlus])
    check(m.memory.variables["M"] == .int(5), "M−")
    // History: ▲ shows the previous calculation.
    var h = machine()
    press(&h, [.d1, .plus, .d1, .equals, .d2, .plus, .d2, .equals, .up])
    check(shown(h) == "2", "▲ shows the previous result")
    h.press(.down)
    check(shown(h) == "4", "▼ back to the newest")
    // Memory survives "switching off" (a new machine from the saved memory).
    let saved = m.memory
    let data = try! JSONEncoder().encode(saved)
    let restored = try! JSONDecoder().decode(CalcMemory.self, from: data)
    check(restored == saved, "memory round-trips through JSON")
    // CLR All resets.
    press(&m, [.shift, .d9, .d3, .equals])
    check(m.memory.variables.isEmpty && m.memory.ans == .zero, "CLR All")
}

private func enterColumn(_ m: inout CalcMachine, _ values: [[CalcKey]]) {
    for v in values { press(&m, v + [.equals]) }
}

private func calcStatTests() {
    // Linear regression: y = 2x.
    var m = machine(.lineO)
    press(&m, [.mode, .d2, .d2])
    check(shown(m) == "editor", "STAT A+BX opens the editor")
    enterColumn(&m, [[.d1], [.d2], [.d3]])
    press(&m, [.up, .up, .up, .right])
    enterColumn(&m, [[.d2], [.d4], [.d6]])
    check(m.memory.statRows.map(\.y) == [2, 4, 6], "Y column entered")
    press(&m, [.ac, .shift, .d1])
    check(shown(m) == "menu:1:Type,2:Data,3:Sum,4:Var,5:Reg,6:MinMax", "STAT menu")
    press(&m, [.d5, .d2, .equals])
    check(shown(m) == "2", "B = 2")
    press(&m, [.shift, .d1, .d5, .d3, .equals])
    check(shown(m) == "1", "r = 1")
    press(&m, [.d5, .shift, .d1, .d5, .d5, .equals])
    check(shown(m) == "10", "5ŷ = 10")
    press(&m, [.shift, .d1, .d4, .d2, .equals])
    check(shown(m) == "2", "x̄ = 2")

    // One variable: 1..5, quartiles by halves.
    var o = machine(.lineO)
    press(&o, [.mode, .d2, .d1])
    enterColumn(&o, [[.d1], [.d2], [.d3], [.d4], [.d5]])
    press(&o, [.ac, .shift, .d1, .d5, .d3, .equals])
    check(shown(o) == "1.5", "Q1")
    press(&o, [.shift, .d1, .d5, .d4, .equals])
    check(shown(o) == "3", "median")
    press(&o, [.shift, .d1, .d4, .d3, .equals])
    check(shown(o) == "1.414213562", "σx")
    press(&o, [.shift, .d1, .d4, .d4, .equals])
    check(shown(o) == "1.58113883", "sx")

    // Quadratic regression recovers y = 1 + 2x + 3x².
    let rows = (0...3).map { x -> CalcStatRow in CalcStatRow(x: Double(x), y: 1 + 2 * Double(x) + 3 * Double(x * x)) }
    let q = try! CalcStatistics(type: .quadratic, rows: rows)
    check(approx(try! q.value(.regA), 1) && approx(try! q.value(.regB), 2) && approx(try! q.value(.regC), 3), "quadratic fit")
    check(approx(try! q.estimate(.xHat1, x: 6), 1) && approx(try! q.estimate(.xHat2, x: 6), -5.0 / 3), "x̂₁, x̂₂")
    // Exponential and power fits.
    let e = try! CalcStatistics(type: .abExponential, rows: [1, 2, 3].map { CalcStatRow(x: $0, y: 3 * pow(2, $0)) })
    check(approx(try! e.value(.regA), 3) && approx(try! e.value(.regB), 2), "A•B^X")
    let p = try! CalcStatistics(type: .power, rows: [1, 2, 4].map { CalcStatRow(x: $0, y: 5 * pow($0, 1.5)) })
    check(approx(try! p.value(.regA), 5) && approx(try! p.value(.regB), 1.5), "A•X^B")
    check((try? CalcStatistics(type: .oneVar, rows: [])) == nil, "no data is a Math ERROR")
}

private func calcVerifyAndErrorTests() {
    var v = machine()
    press(&v, [.mode, .d3, .d1, .plus, .d1, .shift, .d6, .d1, .d2, .equals])
    check(shown(v) == "TRUE", "VERIF 1+1=2")
    press(&v, [.d3, .shift, .d6, .d4, .d2, .equals])
    check(shown(v) == "FALSE", "VERIF 3<2")
    check(run([.d1, .plus, .equals]) == "Syntax ERROR", "1+ is a Syntax ERROR")
    check(run([.d1, .divide, .d0, .equals]) == "Math ERROR", "÷0 is a Math ERROR")
    check(run([.tan, .d9, .d0, .equals]) == "Math ERROR", "tan 90°")
    check(run([.shift, .sin, .d2, .equals]) == "Math ERROR", "sin⁻¹ 2")
    check(run([.d7, .d0, .shift, .inverse, .equals]) == "Math ERROR", "70!")
    // ◀ after an error goes back to editing.
    var m = machine()
    press(&m, [.d1, .plus, .equals, .left, .d2, .equals])
    check(shown(m) == "3", "fix the expression after an error")
}

private func calcEditorTests() {
    var e = CalcEditor()
    e.insert(.fraction)
    e.insert(.digit(1))
    e.moveRight()
    e.insert(.digit(2))
    e.moveRight()
    check(e.cursor.path.isEmpty && e.cursor.index == 1, "cursor leaves the fraction")
    e.deleteBackward()
    check(!e.cursor.path.isEmpty, "DEL steps into a filled template")
    for _ in 0..<4 { e.deleteBackward() }
    check(e.line.isEmpty, "DEL removes the emptied template")
    // Wrapping round: ◀ at the start goes to the end.
    var w = CalcEditor()
    w.insert(.digit(1)); w.insert(.digit(2))
    w.cursor = CalcCursor()
    w.moveLeft()
    check(w.cursor.index == 2, "◀ wraps to the end")
    // LaTeX for putting a calculation on the page.
    var l = CalcEditor()
    l.insert(.fraction); l.insert(.digit(1)); l.moveRight(); l.insert(.digit(2)); l.moveRight()
    l.insert(.binary(.times)); l.insert(.pi)
    check(CalcLatex.latex(l.line) == "\\frac{1}{2}\\times \\pi ", "LaTeX export")
}
