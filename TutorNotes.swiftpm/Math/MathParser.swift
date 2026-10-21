import Foundation

/// Parsed form of the LaTeX subset the tutor writes with: fractions, roots, scripts, big operators,
/// delimiters, accents, matrices, Greek letters and the usual relations/operators.
indirect enum MathNode: Equatable {
    case row([MathNode])
    /// A single symbol. `italic` is used for Latin variables.
    case symbol(String, MathAtomClass, italic: Bool)
    /// Upright text (\text{...}, \mathrm{...}, function names).
    case text(String, MathAtomClass)
    case frac(MathNode, MathNode)
    case sqrt(MathNode, index: MathNode?)
    case scripts(base: MathNode, sup: MathNode?, sub: MathNode?)
    /// ∑ ∏ ∫ lim etc. `limitsAbove` puts sub/sup under/over rather than to the side.
    case bigOp(String, lower: MathNode?, upper: MathNode?, limitsAbove: Bool, isText: Bool)
    case delimited(left: String, MathNode, right: String)
    case accent(MathNode, MathAccent)
    case matrix([[MathNode]], left: String, right: String)
    case space(Double) // in em
    case color(String, MathNode)
}

enum MathAtomClass: Equatable {
    case ordinary, binary, relation, open, close, punct, op
}

enum MathAccent: Equatable {
    case vec, bar, hat, dot, ddot, tilde, underline, overbrace
}

enum MathParser {
    static func parse(_ latex: String) -> MathNode {
        var p = Parser(Array(latex))
        return p.parseRow(until: nil)
    }

    static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
        "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
        "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
        "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]

    static let relations: [String: String] = [
        "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠", "approx": "≈", "equiv": "≡",
        "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝", "in": "∈", "notin": "∉", "subset": "⊂",
        "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇", "to": "→", "rightarrow": "→", "leftarrow": "←",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "iff": "⇔", "Leftrightarrow": "⇔", "implies": "⇒",
        "mapsto": "↦", "ll": "≪", "gg": "≫", "perp": "⊥", "parallel": "∥", "mid": "∣", "therefore": "∴",
        "because": "∵",
    ]

    static let binaries: [String: String] = [
        "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓", "cup": "∪", "cap": "∩", "setminus": "∖",
        "circ": "∘", "ast": "∗", "star": "⋆", "oplus": "⊕", "otimes": "⊗", "wedge": "∧", "vee": "∨",
    ]

    static let ordinaries: [String: String] = [
        "infty": "∞", "partial": "∂", "nabla": "∇", "forall": "∀", "exists": "∃", "emptyset": "∅",
        "varnothing": "∅", "angle": "∠", "triangle": "△", "degree": "°", "circ_deg": "°", "ldots": "…",
        "cdots": "⋯", "dots": "…", "vdots": "⋮", "ddots": "⋱", "prime": "′", "hbar": "ℏ", "ell": "ℓ",
        "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "neg": "¬", "lnot": "¬", "square": "□", "checkmark": "✓",
        "R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "percent": "%", "%": "%", "$": "$", "#": "#",
        "&": "&", "_": "_", "{": "{", "}": "}", "backslash": "\\", "lbrace": "{", "rbrace": "}",
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
    ]

    static let functionNames: Set<String> = [
        "sin", "cos", "tan", "sec", "csc", "cot", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
        "ln", "log", "exp", "det", "dim", "deg", "gcd", "arg", "ker", "Pr", "mod", "bmod",
    ]

    static let limitOps: [String: (String, Bool)] = [
        // name: (symbol, isText)
        "sum": ("∑", false), "prod": ("∏", false), "coprod": ("∐", false), "bigcup": ("⋃", false),
        "bigcap": ("⋂", false), "lim": ("lim", true), "max": ("max", true), "min": ("min", true),
        "sup": ("sup", true), "inf": ("inf", true), "limsup": ("lim sup", true), "liminf": ("lim inf", true),
    ]

    static let integralOps: [String: String] = [
        "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
    ]

    struct Parser {
        let chars: [Character]
        var i = 0

        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool { i >= chars.count }
        var peek: Character? { i < chars.count ? chars[i] : nil }

        mutating func skipSpaces() {
            while let c = peek, c == " " || c == "\n" || c == "\t" { i += 1 }
        }

        /// Parses until the given terminator command/character (not consumed) or end of input.
        mutating func parseRow(until terminator: String?) -> MathNode {
            var items: [MathNode] = []
            while !atEnd {
                skipSpaces()
                guard let c = peek else { break }
                if let t = terminator {
                    if t == "}" && c == "}" { break }
                    if t == "]" && c == "]" { break }
                    if t.hasPrefix("\\") && lookingAtCommand(String(t.dropFirst())) { break }
                    if t == "&\\\\" && (c == "&" || lookingAtLineBreak()) { break }
                    if t == "&\\\\" && lookingAtCommand("end") { break }
                }
                if c == "}" { i += 1; continue } // stray close brace
                if c == "^" || c == "_" {
                    i += 1
                    let script = parseScriptArgument()
                    let base = items.popLast() ?? .row([])
                    items.append(attach(script: script, isSup: c == "^", to: base))
                    continue
                }
                if c == "'" {
                    i += 1
                    var primes = "′"
                    while peek == "'" { i += 1; primes += "′" }
                    let base = items.popLast() ?? .row([])
                    items.append(attach(script: .symbol(primes, .ordinary, italic: false), isSup: true, to: base))
                    continue
                }
                if let node = parseAtom() {
                    items.append(node)
                }
            }
            return items.count == 1 ? items[0] : .row(items)
        }

        func lookingAtCommand(_ name: String) -> Bool {
            guard i < chars.count, chars[i] == "\\" else { return false }
            let nameChars = Array(name)
            guard i + 1 + nameChars.count <= chars.count else { return false }
            for (k, ch) in nameChars.enumerated() where chars[i + 1 + k] != ch { return false }
            let after = i + 1 + nameChars.count
            if after < chars.count, chars[after].isLetter, nameChars.last?.isLetter == true { return false }
            return true
        }

        func lookingAtLineBreak() -> Bool {
            i + 1 < chars.count && chars[i] == "\\" && chars[i + 1] == "\\"
        }

        func attach(script: MathNode, isSup: Bool, to base: MathNode) -> MathNode {
            switch base {
            case .scripts(let b, let sup, let sub):
                if isSup && sup == nil { return .scripts(base: b, sup: script, sub: sub) }
                if !isSup && sub == nil { return .scripts(base: b, sup: sup, sub: script) }
                return .scripts(base: base, sup: isSup ? script : nil, sub: isSup ? nil : script)
            case .bigOp(let s, let lower, let upper, let above, let isText):
                if isSup && upper == nil { return .bigOp(s, lower: lower, upper: script, limitsAbove: above, isText: isText) }
                if !isSup && lower == nil { return .bigOp(s, lower: script, upper: upper, limitsAbove: above, isText: isText) }
                return .scripts(base: base, sup: isSup ? script : nil, sub: isSup ? nil : script)
            default:
                return .scripts(base: base, sup: isSup ? script : nil, sub: isSup ? nil : script)
            }
        }

        mutating func parseScriptArgument() -> MathNode {
            skipSpaces()
            guard let c = peek else { return .row([]) }
            if c == "{" {
                i += 1
                let inner = parseRow(until: "}")
                if peek == "}" { i += 1 }
                return inner
            }
            if c == "\\" {
                return parseAtom() ?? .row([])
            }
            i += 1
            return symbolNode(for: c)
        }

        /// Parses a required argument: `{...}` or a single token.
        mutating func parseGroup() -> MathNode {
            skipSpaces()
            guard let c = peek else { return .row([]) }
            if c == "{" {
                i += 1
                let inner = parseRow(until: "}")
                if peek == "}" { i += 1 }
                return inner
            }
            if c == "\\" { return parseAtom() ?? .row([]) }
            i += 1
            return symbolNode(for: c)
        }

        mutating func readRawGroup() -> String {
            skipSpaces()
            guard peek == "{" else {
                if let c = peek { i += 1; return String(c) }
                return ""
            }
            i += 1
            var depth = 1
            var out = ""
            while let c = peek {
                i += 1
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                out.append(c)
            }
            return out
        }

        mutating func readCommandName() -> String {
            // Assumes current char is "\"
            i += 1
            guard let c = peek else { return "" }
            if !c.isLetter {
                i += 1
                return String(c)
            }
            var name = ""
            while let d = peek, d.isLetter {
                name.append(d)
                i += 1
            }
            return name
        }

        func symbolNode(for c: Character) -> MathNode {
            let s = String(c)
            switch c {
            case "+", "−", "×", "÷", "±", "·", "∓":
                return .symbol(c == "-" ? "−" : s, .binary, italic: false)
            case "-":
                return .symbol("−", .binary, italic: false)
            case "*":
                return .symbol("∗", .binary, italic: false)
            case "=", "<", ">", "≤", "≥", "≠", "≈", "→", "⇒", "∈":
                return .symbol(s, .relation, italic: false)
            case "(", "[":
                return .symbol(s, .open, italic: false)
            case ")", "]":
                return .symbol(s, .close, italic: false)
            case ",", ";":
                return .symbol(s, .punct, italic: false)
            case "!", "?", ".", ":", "/", "|", "%", "°":
                return .symbol(s, .ordinary, italic: false)
            default:
                if c.isLetter && c.isASCII { return .symbol(s, .ordinary, italic: true) }
                if let g = c.unicodeScalars.first, (0x3B1...0x3C9).contains(g.value) {
                    return .symbol(s, .ordinary, italic: true)
                }
                return .symbol(s, .ordinary, italic: false)
            }
        }

        mutating func parseNumber() -> MathNode {
            var s = ""
            while let c = peek, c.isNumber || c == "." {
                // Stop at a trailing "." that is really punctuation.
                if c == "." {
                    let nextIsDigit = i + 1 < chars.count && chars[i + 1].isNumber
                    if !nextIsDigit { break }
                }
                s.append(c)
                i += 1
            }
            return .text(s, .ordinary)
        }

        mutating func parseAtom() -> MathNode? {
            skipSpaces()
            guard let c = peek else { return nil }
            if c == "{" {
                i += 1
                let inner = parseRow(until: "}")
                if peek == "}" { i += 1 }
                return inner
            }
            if c.isNumber {
                return parseNumber()
            }
            if c == "&" {
                i += 1
                return .space(0.5)
            }
            if c == "~" {
                i += 1
                return .space(0.33)
            }
            if c == "\\" {
                if lookingAtLineBreak() {
                    i += 2
                    return .space(1)
                }
                return parseCommand()
            }
            i += 1
            return symbolNode(for: c)
        }

        mutating func parseCommand() -> MathNode? {
            let name = readCommandName()
            if name.isEmpty { return nil }
            switch name {
            case "frac", "dfrac", "tfrac", "cfrac":
                let num = parseGroup()
                let den = parseGroup()
                return .frac(num, den)
            case "binom":
                let n = parseGroup()
                let k = parseGroup()
                return .delimited(left: "(", .matrix([[n], [k]], left: "", right: ""), right: ")")
            case "sqrt":
                skipSpaces()
                var index: MathNode?
                if peek == "[" {
                    i += 1
                    index = parseRow(until: "]")
                    if peek == "]" { i += 1 }
                }
                let radicand = parseGroup()
                return .sqrt(radicand, index: index)
            case "left":
                skipSpaces()
                let left = readDelimiter()
                let inner = parseRow(until: "\\right")
                var right = ""
                if lookingAtCommand("right") {
                    _ = readCommandName()
                    skipSpaces()
                    right = readDelimiter()
                }
                return .delimited(left: left, inner, right: right)
            case "right":
                skipSpaces()
                _ = readDelimiter()
                return nil
            case "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr":
                skipSpaces()
                let d = readDelimiter()
                return .symbol(d, name.hasSuffix("r") ? .close : .open, italic: false)
            case "text", "textrm", "mathrm", "operatorname", "textbf", "mathbf", "textit", "mbox":
                let raw = readRawGroup()
                if name == "operatorname" { return .text(raw, .op) }
                return .text(raw, .ordinary)
            case "mathbb":
                let raw = readRawGroup()
                let map: [String: String] = ["R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ"]
                return .symbol(map[raw] ?? raw, .ordinary, italic: false)
            case "vec", "overrightarrow":
                return .accent(parseGroup(), .vec)
            case "bar", "overline":
                return .accent(parseGroup(), .bar)
            case "hat", "widehat":
                return .accent(parseGroup(), .hat)
            case "dot":
                return .accent(parseGroup(), .dot)
            case "ddot":
                return .accent(parseGroup(), .ddot)
            case "tilde", "widetilde":
                return .accent(parseGroup(), .tilde)
            case "underline":
                return .accent(parseGroup(), .underline)
            case "overbrace", "underbrace":
                return .accent(parseGroup(), .overbrace)
            case "color", "textcolor":
                let colorName = readRawGroup()
                return .color(colorName, parseGroup())
            case "boxed":
                return parseGroup()
            case "begin":
                let env = readRawGroup()
                return parseEnvironment(env)
            case "end":
                _ = readRawGroup()
                return nil
            case "quad": return .space(1)
            case "qquad": return .space(2)
            case ",", "thinspace": return .space(0.17)
            case ":", ">", "medspace": return .space(0.22)
            case ";", "thickspace": return .space(0.28)
            case "!": return .space(-0.17)
            case " ": return .space(0.33)
            case "displaystyle", "textstyle", "limits", "nolimits", "rm", "it", "bf": return nil
            case "circ":
                // ^\circ means degrees; elsewhere a ring operator.
                return .symbol("∘", .binary, italic: false)
            default:
                break
            }
            if let g = MathParser.greek[name] {
                let upper = name.first?.isUppercase ?? false
                return .symbol(g, .ordinary, italic: !upper)
            }
            if let r = MathParser.relations[name] { return .symbol(r, .relation, italic: false) }
            if let b = MathParser.binaries[name] { return .symbol(b, .binary, italic: false) }
            if let o = MathParser.ordinaries[name] { return .symbol(o, .ordinary, italic: false) }
            if MathParser.functionNames.contains(name) { return .text(name, .op) }
            if let (sym, isText) = MathParser.limitOps[name] {
                return .bigOp(sym, lower: nil, upper: nil, limitsAbove: true, isText: isText)
            }
            if let sym = MathParser.integralOps[name] {
                return .bigOp(sym, lower: nil, upper: nil, limitsAbove: false, isText: false)
            }
            // Unknown command: show its name rather than dropping content silently.
            return .text(name, .ordinary)
        }

        mutating func readDelimiter() -> String {
            guard let c = peek else { return "" }
            if c == "\\" {
                let name = readCommandName()
                switch name {
                case "{", "lbrace": return "{"
                case "}", "rbrace": return "}"
                case "|", "Vert": return "‖"
                case "langle": return "⟨"
                case "rangle": return "⟩"
                case "lfloor": return "⌊"
                case "rfloor": return "⌋"
                case "lceil": return "⌈"
                case "rceil": return "⌉"
                default: return ""
                }
            }
            i += 1
            return c == "." ? "" : String(c)
        }

        mutating func parseEnvironment(_ env: String) -> MathNode {
            let delims: (String, String)
            switch env {
            case "pmatrix": delims = ("(", ")")
            case "bmatrix": delims = ("[", "]")
            case "vmatrix": delims = ("|", "|")
            case "Bmatrix": delims = ("{", "}")
            case "cases": delims = ("{", "")
            default: delims = ("", "")
            }
            var rows: [[MathNode]] = []
            var currentRow: [MathNode] = []
            while !atEnd {
                if lookingAtCommand("end") {
                    _ = readCommandName()
                    _ = readRawGroup()
                    break
                }
                let cell = parseRow(until: "&\\\\")
                currentRow.append(cell)
                if peek == "&" {
                    i += 1
                } else if lookingAtLineBreak() {
                    i += 2
                    rows.append(currentRow)
                    currentRow = []
                } else if lookingAtCommand("end") {
                    continue
                } else if !atEnd {
                    i += 1
                }
            }
            if !currentRow.isEmpty && !(currentRow.count == 1 && currentRow[0] == .row([])) {
                rows.append(currentRow)
            }
            return .matrix(rows, left: delims.0, right: delims.1)
        }
    }
}

/// Splits rich tutor text into plain runs and `$...$` math runs. `$$...$$` is treated the same.
/// `**bold**` runs are marked so the renderer can embolden them.
enum RichTextSegment: Equatable {
    case text(String, bold: Bool)
    case math(String)
    case newline
}

enum RichTextParser {
    static func segments(_ input: String) -> [RichTextSegment] {
        var result: [RichTextSegment] = []
        var buffer = ""
        var bold = false
        let chars = Array(input)
        var i = 0
        func flush() {
            if !buffer.isEmpty {
                result.append(.text(buffer, bold: bold))
                buffer = ""
            }
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count && chars[i + 1] == "$" {
                buffer.append("$")
                i += 2
                continue
            }
            if c == "$" {
                var start = i + 1
                var double = false
                if start < chars.count && chars[start] == "$" { start += 1; double = true }
                var j = start
                while j < chars.count {
                    if chars[j] == "$" && chars[j - 1] != "\\" { break }
                    j += 1
                }
                if j < chars.count {
                    flush()
                    result.append(.math(String(chars[start..<j])))
                    i = j + 1
                    if double && i < chars.count && chars[i] == "$" { i += 1 }
                    continue
                }
                // Unmatched: literal dollar sign.
                buffer.append(c)
                i += 1
                continue
            }
            if c == "*" && i + 1 < chars.count && chars[i + 1] == "*" {
                flush()
                bold.toggle()
                i += 2
                continue
            }
            if c == "\n" {
                flush()
                result.append(.newline)
                i += 1
                continue
            }
            buffer.append(c)
            i += 1
        }
        flush()
        return result
    }

    /// Plain-text rendering for speech, search and accessibility.
    static func plainText(_ input: String) -> String {
        segments(input).map { seg -> String in
            switch seg {
            case .text(let t, _): return t
            case .newline: return "\n"
            case .math(let m): return MathSpeech.readable(m)
            }
        }.joined()
    }
}

enum MathSpeech {
    /// Converts LaTeX to compact readable Unicode, e.g. `\frac{1}{2}x^2` -> `(1)/(2)x²`.
    static func readable(_ latex: String) -> String {
        flatten(MathParser.parse(latex))
    }

    static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "n": "ⁿ", "i": "ⁱ", "(": "⁽", ")": "⁾", "x": "ˣ", "′": "′",
    ]

    static func flatten(_ node: MathNode) -> String {
        switch node {
        case .row(let items): return items.map(flatten).joined()
        case .symbol(let s, let cls, _):
            return (cls == .binary || cls == .relation) ? " \(s) " : s
        case .text(let t, let cls): return cls == .op ? t + " " : t
        case .frac(let n, let d): return "(\(flatten(n)))/(\(flatten(d)))"
        case .sqrt(let r, let idx):
            if let idx { return "\(flatten(idx))√(\(flatten(r)))" }
            return "√(\(flatten(r)))"
        case .scripts(let base, let sup, let sub):
            var s = flatten(base)
            if let sub { s += "_" + flatten(sub) }
            if let sup {
                let raw = flatten(sup)
                let mapped = raw.compactMap { superscripts[$0] }
                s += mapped.count == raw.count ? String(mapped) : "^(\(raw))"
            }
            return s
        case .bigOp(let sym, let lower, let upper, _, _):
            var s = sym
            if let lower { s += "_(\(flatten(lower)))" }
            if let upper { s += "^(\(flatten(upper)))" }
            return s + " "
        case .delimited(let l, let inner, let r): return l + flatten(inner) + r
        case .accent(let inner, _): return flatten(inner)
        case .matrix(let rows, let l, let r):
            return l + rows.map { $0.map(flatten).joined(separator: ", ") }.joined(separator: "; ") + r
        case .space(let em): return em > 0.4 ? " " : ""
        case .color(_, let inner): return flatten(inner)
        }
    }
}
