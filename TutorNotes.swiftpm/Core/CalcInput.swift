import Foundation

// What the student types, in Natural Display form: a line of tokens and templates (fractions,
// roots, powers…), each template holding its own lines. The same structure also describes results
// on screen, so one renderer draws both.

enum CalcBinary: String, Codable, Hashable {
    case plus, minus, times, divide, nPr, nCr

    var label: String {
        switch self {
        case .plus: return "+"
        case .minus: return "−"
        case .times: return "×"
        case .divide: return "÷"
        case .nPr: return "P"
        case .nCr: return "C"
        }
    }
}

/// Functions typed with their opening bracket, like the calculator's "sin(".
enum CalcFunction: String, Codable, Hashable, CaseIterable {
    case sin, cos, tan, asin, acos, atan
    case sinh, cosh, tanh, asinh, acosh, atanh
    case log, ln, abs, pol, rec, rnd, ranInt, gcd, lcm

    var label: String {
        switch self {
        case .asin: return "sin⁻¹("
        case .acos: return "cos⁻¹("
        case .atan: return "tan⁻¹("
        case .asinh: return "sinh⁻¹("
        case .acosh: return "cosh⁻¹("
        case .atanh: return "tanh⁻¹("
        case .abs: return "Abs("
        case .pol: return "Pol("
        case .rec: return "Rec("
        case .rnd: return "Rnd("
        case .ranInt: return "RanInt#("
        case .gcd: return "GCD("
        case .lcm: return "LCM("
        default: return rawValue + "("
        }
    }

    var latex: String {
        switch self {
        case .sin, .cos, .tan, .sinh, .cosh, .tanh, .log, .ln: return "\\" + rawValue + "("
        case .asin: return "\\sin^{-1}("
        case .acos: return "\\cos^{-1}("
        case .atan: return "\\tan^{-1}("
        case .asinh: return "\\sinh^{-1}("
        case .acosh: return "\\cosh^{-1}("
        case .atanh: return "\\tanh^{-1}("
        default: return "\\text{" + String(label.dropLast()) + "}("
        }
    }

    var argumentCount: Int {
        switch self {
        case .pol, .rec, .ranInt, .gcd, .lcm: return 2
        default: return 1
        }
    }
}

enum CalcPostfix: String, Codable, Hashable {
    case square, cube, inverse, factorial, percent
    /// The °'" key typed after a number: degrees, minutes, seconds.
    case dms
    /// DRG▶ marks: the value is in that unit and is converted to the current one.
    case degMark, radMark, gradMark

    var label: String {
        switch self {
        case .square: return "²"
        case .cube: return "³"
        case .inverse: return "⁻¹"
        case .factorial: return "!"
        case .percent: return "%"
        case .dms: return "°"
        case .degMark: return "°"
        case .radMark: return "ʳ"
        case .gradMark: return "ᵍ"
        }
    }
}

enum CalcRelation: String, Codable, Hashable, CaseIterable {
    case eq, ne, gt, lt, ge, le

    var label: String {
        switch self {
        case .eq: return "="
        case .ne: return "≠"
        case .gt: return ">"
        case .lt: return "<"
        case .ge: return "≥"
        case .le: return "≤"
        }
    }
}

/// STAT mode results, used as values (n, x̄…) or, for the estimates, after a value (5ŷ).
enum CalcStatVar: String, Codable, Hashable, CaseIterable {
    case n, xMean, sigmaX, sX, yMean, sigmaY, sY
    case sumX2, sumX, sumY2, sumY, sumXY, sumX3, sumX2Y, sumX4
    case minX, maxX, minY, maxY, q1, med, q3
    case regA, regB, regC, regR
    case xHat, yHat, xHat1, xHat2

    var label: String {
        switch self {
        case .n: return "n"
        case .xMean: return "x̄"
        case .sigmaX: return "σx"
        case .sX: return "sx"
        case .yMean: return "ȳ"
        case .sigmaY: return "σy"
        case .sY: return "sy"
        case .sumX2: return "Σx²"
        case .sumX: return "Σx"
        case .sumY2: return "Σy²"
        case .sumY: return "Σy"
        case .sumXY: return "Σxy"
        case .sumX3: return "Σx³"
        case .sumX2Y: return "Σx²y"
        case .sumX4: return "Σx⁴"
        case .minX: return "minX"
        case .maxX: return "maxX"
        case .minY: return "minY"
        case .maxY: return "maxY"
        case .q1: return "Q1"
        case .med: return "med"
        case .q3: return "Q3"
        case .regA: return "A"
        case .regB: return "B"
        case .regC: return "C"
        case .regR: return "r"
        case .xHat: return "x̂"
        case .yHat: return "ŷ"
        case .xHat1: return "x̂₁"
        case .xHat2: return "x̂₂"
        }
    }

    /// x̂, ŷ, x̂₁ and x̂₂ take the value typed before them.
    var isEstimate: Bool { [.xHat, .yHat, .xHat1, .xHat2].contains(self) }
}

enum CalcToken: Hashable, Codable {
    case digit(Int)
    case point
    case binary(CalcBinary)
    /// The (−) key.
    case negative
    case openParen, closeParen, comma, colon
    case function(CalcFunction)
    case postfix(CalcPostfix)
    case pi, e
    /// A, B, C, D, E, F, M, X, Y.
    case variable(String)
    case ans, ranNum
    case stat(CalcStatVar)
    case relation(CalcRelation)
    /// Display only (results and messages).
    case text(String)

    var label: String {
        switch self {
        case .digit(let d): return String(d)
        case .point: return "."
        case .binary(let b): return b.label
        case .negative: return "−"
        case .openParen: return "("
        case .closeParen: return ")"
        case .comma: return ","
        case .colon: return ":"
        case .function(let f): return f.label
        case .postfix(let p): return p.label
        case .pi: return "π"
        case .e: return "e"
        case .variable(let v): return v
        case .ans: return "Ans"
        case .ranNum: return "Ran#"
        case .stat(let s): return s.label
        case .relation(let r): return r.label
        case .text(let t): return t
        }
    }
}

enum CalcTemplate: String, Codable, Hashable {
    /// □/□
    case fraction
    /// □ □/□
    case mixed
    /// √□
    case sqrt
    /// ∛□
    case cbrt
    /// ˣ√□ (index, radicand)
    case root
    /// x^□, attached to what comes before it.
    case power
    /// 10^□
    case tenPower
    /// e^□
    case ePower
    /// log□(□)
    case logBase
    /// |□|
    case abs
    /// ×10^□ in a number (the ×10ˣ key).
    case exp10

    var slotCount: Int {
        switch self {
        case .fraction, .root, .logBase: return 2
        case .mixed: return 3
        default: return 1
        }
    }
}

indirect enum CalcNode: Hashable, Codable {
    case token(CalcToken)
    case template(CalcTemplate, [CalcLine])
}

struct CalcLine: Hashable, Codable {
    var nodes: [CalcNode] = []

    init(_ nodes: [CalcNode] = []) { self.nodes = nodes }

    static func tokens(_ t: [CalcToken]) -> CalcLine { CalcLine(t.map { .token($0) }) }
    static func text(_ s: String) -> CalcLine { CalcLine([.token(.text(s))]) }

    var isEmpty: Bool { nodes.isEmpty }
}

// MARK: - Cursor and editing

/// A position: which slot of which template (from the outside in), then an index in that line.
struct CalcCursor: Hashable, Codable {
    struct Step: Hashable, Codable { var node: Int; var slot: Int }
    var path: [Step] = []
    var index: Int = 0
}

struct CalcEditor: Hashable, Codable {
    var line = CalcLine()
    var cursor = CalcCursor()

    static let maxNesting = 6

    // Reading and writing the line the cursor is in.

    private func line(at path: ArraySlice<CalcCursor.Step>, in l: CalcLine) -> CalcLine {
        guard let step = path.first else { return l }
        guard step.node < l.nodes.count, case .template(_, let slots) = l.nodes[step.node], step.slot < slots.count else { return l }
        return line(at: path.dropFirst(), in: slots[step.slot])
    }

    private static func modify(_ l: inout CalcLine, _ path: ArraySlice<CalcCursor.Step>, _ f: (inout CalcLine) -> Void) {
        guard let step = path.first else { f(&l); return }
        guard step.node < l.nodes.count, case .template(let kind, var slots) = l.nodes[step.node], step.slot < slots.count else { return }
        modify(&slots[step.slot], path.dropFirst(), f)
        l.nodes[step.node] = .template(kind, slots)
    }

    var currentLine: CalcLine { line(at: cursor.path[...], in: line) }

    private mutating func editCurrent(_ f: (inout CalcLine) -> Void) {
        CalcEditor.modify(&line, cursor.path[...], f)
    }

    /// The template the cursor is inside (innermost), if any.
    private var enclosingTemplate: (kind: CalcTemplate, slots: Int, slot: Int, node: Int)? {
        guard let last = cursor.path.last else { return nil }
        let parent = line(at: cursor.path.dropLast(), in: line)
        guard last.node < parent.nodes.count, case .template(let kind, let slots) = parent.nodes[last.node] else { return nil }
        return (kind, slots.count, last.slot, last.node)
    }

    mutating func clear() {
        line = CalcLine()
        cursor = CalcCursor()
    }

    mutating func moveToEnd() {
        cursor = CalcCursor(path: [], index: line.nodes.count)
    }

    mutating func insert(_ token: CalcToken) {
        let i = cursor.index
        editCurrent { $0.nodes.insert(.token(token), at: min(i, $0.nodes.count)) }
        cursor.index += 1
    }

    /// Inserts a template and puts the cursor in its first empty slot.
    mutating func insert(_ template: CalcTemplate) {
        guard cursor.path.count < CalcEditor.maxNesting else { return }
        let i = cursor.index
        let slots = Array(repeating: CalcLine(), count: template.slotCount)
        editCurrent { $0.nodes.insert(.template(template, slots), at: min(i, $0.nodes.count)) }
        cursor.path.append(.init(node: i, slot: 0))
        cursor.index = 0
    }

    /// Inserts a template whose first slot is already filled (x³ as x^3), cursor after it.
    mutating func insert(_ template: CalcTemplate, filled first: CalcLine) {
        let i = cursor.index
        var slots = Array(repeating: CalcLine(), count: template.slotCount)
        slots[0] = first
        editCurrent { $0.nodes.insert(.template(template, slots), at: min(i, $0.nodes.count)) }
        if template.slotCount > 1 {
            cursor.path.append(.init(node: i, slot: 1))
            cursor.index = 0
        } else {
            cursor.index = i + 1
        }
    }

    mutating func moveRight() {
        let current = currentLine
        if cursor.index < current.nodes.count {
            if case .template = current.nodes[cursor.index] {
                cursor.path.append(.init(node: cursor.index, slot: 0))
                cursor.index = 0
            } else {
                cursor.index += 1
            }
            return
        }
        guard let t = enclosingTemplate else {
            cursor = CalcCursor()  // wraps round to the start, like the calculator
            return
        }
        if t.slot + 1 < t.slots {
            cursor.path[cursor.path.count - 1].slot += 1
            cursor.index = 0
        } else {
            cursor.path.removeLast()
            cursor.index = t.node + 1
        }
    }

    mutating func moveLeft() {
        let current = currentLine
        if cursor.index > 0 {
            if case .template(_, let slots) = current.nodes[cursor.index - 1] {
                cursor.path.append(.init(node: cursor.index - 1, slot: slots.count - 1))
                cursor.index = slots[slots.count - 1].nodes.count
            } else {
                cursor.index -= 1
            }
            return
        }
        guard let t = enclosingTemplate else {
            moveToEnd()
            return
        }
        if t.slot > 0 {
            cursor.path[cursor.path.count - 1].slot -= 1
            cursor.index = currentLine.nodes.count
        } else {
            cursor.path.removeLast()
            cursor.index = t.node
        }
    }

    /// Up and down move between a fraction's numerator and denominator. Returns false when the
    /// cursor isn't in one (so the caller can use the key for history).
    mutating func moveVertically(up: Bool) -> Bool {
        var depth = cursor.path.count - 1
        while depth >= 0 {
            let parent = line(at: cursor.path.prefix(depth), in: line)
            let step = cursor.path[depth]
            if step.node < parent.nodes.count, case .template(let kind, let slots) = parent.nodes[step.node],
               kind == .fraction || kind == .mixed {
                let target: Int?
                switch (kind, step.slot, up) {
                case (.fraction, 1, true): target = 0
                case (.fraction, 0, false): target = 1
                case (.mixed, 2, true): target = 1
                case (.mixed, 1, false): target = 2
                default: target = nil
                }
                if let target {
                    cursor.path = Array(cursor.path.prefix(depth)) + [.init(node: step.node, slot: target)]
                    cursor.index = min(cursor.index, slots[target].nodes.count)
                    return true
                }
            }
            depth -= 1
        }
        return false
    }

    /// DEL: removes what's before the cursor. An empty template is removed whole; a filled one is
    /// entered so its contents go first.
    mutating func deleteBackward() {
        let current = currentLine
        if cursor.index > 0 {
            if case .template(_, let slots) = current.nodes[cursor.index - 1] {
                if slots.allSatisfy(\.isEmpty) {
                    let i = cursor.index - 1
                    editCurrent { $0.nodes.remove(at: i) }
                    cursor.index -= 1
                } else {
                    moveLeft()
                }
            } else {
                let i = cursor.index - 1
                editCurrent { $0.nodes.remove(at: i) }
                cursor.index -= 1
            }
            return
        }
        guard let t = enclosingTemplate else { return }
        // At the start of a slot: remove the template if it's empty, else step out of this slot.
        let parentPath = cursor.path.dropLast()
        let parent = line(at: parentPath, in: line)
        if case .template(_, let slots) = parent.nodes[t.node], slots.allSatisfy(\.isEmpty) {
            cursor.path.removeLast()
            cursor.index = t.node
            editCurrent { $0.nodes.remove(at: t.node) }
        } else {
            moveLeft()
        }
    }
}

// MARK: - LaTeX (for putting a calculation on the page)

enum CalcLatex {
    static func latex(_ line: CalcLine) -> String {
        var out = ""
        var open = 0
        for node in line.nodes {
            switch node {
            case .token(let t):
                out += latex(t)
                switch t {
                case .openParen, .function: open += 1
                case .closeParen: open = max(0, open - 1)
                default: break
                }
            case .template(let kind, let s):
                let a = s.indices.contains(0) ? latex(s[0]) : ""
                let b = s.indices.contains(1) ? latex(s[1]) : ""
                let c = s.indices.contains(2) ? latex(s[2]) : ""
                switch kind {
                case .fraction: out += "\\frac{\(a)}{\(b)}"
                case .mixed: out += "\(a)\\frac{\(b)}{\(c)}"
                case .sqrt: out += "\\sqrt{\(a)}"
                case .cbrt: out += "\\sqrt[3]{\(a)}"
                case .root: out += "\\sqrt[\(a)]{\(b)}"
                case .power: out += "^{\(a)}"
                case .tenPower: out += "10^{\(a)}"
                case .ePower: out += "e^{\(a)}"
                case .logBase: out += "\\log_{\(a)}(\(b))"
                case .abs: out += "\\left|\(a)\\right|"
                case .exp10: out += "\\times10^{\(a)}"
                }
            }
        }
        // The calculator closes brackets left open at the end; the page should show them.
        return out + String(repeating: ")", count: open)
    }

    static func latex(_ t: CalcToken) -> String {
        switch t {
        case .binary(.times): return "\\times "
        case .binary(.divide): return "\\div "
        case .binary(.minus), .negative: return "-"
        case .binary(.nPr): return "\\,\\text{P}\\,"
        case .binary(.nCr): return "\\,\\text{C}\\,"
        case .function(let f): return f.latex
        case .postfix(.square): return "^{2}"
        case .postfix(.cube): return "^{3}"
        case .postfix(.inverse): return "^{-1}"
        case .postfix(.dms), .postfix(.degMark): return "^{\\circ}"
        case .postfix(.radMark): return "^{r}"
        case .postfix(.gradMark): return "^{g}"
        case .pi: return "\\pi "
        case .stat(let s): return "\\text{\(s.label)}"
        case .relation(.ne): return "\\neq "
        case .relation(.ge): return "\\geq "
        case .relation(.le): return "\\leq "
        case .text("−"): return "-"
        case .text(let s): return s.contains(where: \.isLetter) ? "\\text{\(s)}" : s
        case .ans: return "\\text{Ans}"
        case .ranNum: return "\\text{Ran#}"
        default: return t.label
        }
    }
}
