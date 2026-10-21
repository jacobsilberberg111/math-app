import Foundation

/// A math expression in one variable (x), used to plot functions on graph elements.
///
/// Accepts everyday notation (`2x^2 - 3x + 1`, `sin(x)/x`, `|x-2|`, `y = e^(-x)`) and the common
/// LaTeX spellings the tutor tends to use (`\frac{1}{x}`, `\sqrt{x}`, `x^{2}`, `\pi`, `\cdot`).
indirect enum MathExpr {
    case number(Double)
    case variable(String)
    case unary(String, MathExpr)
    case binary(Character, MathExpr, MathExpr)
    case call(String, [MathExpr])

    func evaluate(_ vars: [String: Double]) -> Double {
        switch self {
        case .number(let n): return n
        case .variable(let name):
            if let v = vars[name] { return v }
            switch name {
            case "pi", "π": return Double.pi
            case "e": return exp(1.0)
            case "tau", "τ": return 2 * Double.pi
            default: return vars["x"] ?? .nan
            }
        case .unary(let op, let a):
            let v = a.evaluate(vars)
            switch op {
            case "-": return -v
            case "!": return MathExpr.factorial(v)
            default: return v
            }
        case .binary(let op, let a, let b):
            let l = a.evaluate(vars), r = b.evaluate(vars)
            switch op {
            case "+": return l + r
            case "-": return l - r
            case "*": return l * r
            case "/": return l / r
            case "^": return MathExpr.power(l, r)
            default: return .nan
            }
        case .call(let name, let args):
            let v = args.map { $0.evaluate(vars) }
            guard let a = v.first else { return .nan }
            switch name {
            case "sin": return sin(a)
            case "cos": return cos(a)
            case "tan": return tan(a)
            case "sec": return 1 / cos(a)
            case "csc", "cosec": return 1 / sin(a)
            case "cot": return 1 / tan(a)
            case "asin", "arcsin": return asin(a)
            case "acos", "arccos": return acos(a)
            case "atan", "arctan": return v.count > 1 ? atan2(a, v[1]) : atan(a)
            case "sinh": return sinh(a)
            case "cosh": return cosh(a)
            case "tanh": return tanh(a)
            case "sqrt": return a < 0 ? .nan : a.squareRoot()
            case "cbrt": return cbrt(a)
            case "abs": return abs(a)
            case "ln": return a <= 0 ? .nan : log(a)
            case "log":
                if v.count > 1 { return log(a) / log(v[1]) }
                return a <= 0 ? .nan : log10(a)
            case "log2": return a <= 0 ? .nan : log2(a)
            case "exp": return exp(a)
            case "floor": return floor(a)
            case "ceil": return ceil(a)
            case "round": return a.rounded()
            case "sign", "sgn": return a > 0 ? 1 : (a < 0 ? -1 : 0)
            case "min": return v.min() ?? .nan
            case "max": return v.max() ?? .nan
            case "pow": return v.count > 1 ? MathExpr.power(a, v[1]) : .nan
            case "root": return v.count > 1 ? MathExpr.power(a, 1 / v[1]) : a.squareRoot()
            default: return .nan
            }
        }
    }

    func evaluate(x: Double) -> Double { evaluate(["x": x]) }

    static func power(_ base: Double, _ exponent: Double) -> Double {
        // Real odd roots of negative numbers, e.g. x^(1/3) for x < 0.
        if base < 0, exponent != exponent.rounded() {
            let inv = 1 / exponent
            if abs(inv - inv.rounded()) < 1e-9, Int(inv.rounded()) % 2 != 0 {
                return -pow(-base, exponent)
            }
        }
        return pow(base, exponent)
    }

    static func factorial(_ n: Double) -> Double {
        guard n >= 0, n == n.rounded(), n <= 170 else { return tgamma(n + 1) }
        var r = 1.0
        var i = 2.0
        while i <= n { r *= i; i += 1 }
        return r
    }
}

enum ExpressionError: Error, CustomStringConvertible {
    case unexpected(String)
    case empty

    var description: String {
        switch self {
        case .unexpected(let s): return s
        case .empty: return "Empty expression"
        }
    }
}

enum ExpressionParser {
    static let functions: Set<String> = [
        "sin", "cos", "tan", "sec", "csc", "cosec", "cot", "asin", "acos", "atan", "arcsin", "arccos", "arctan",
        "sinh", "cosh", "tanh", "sqrt", "cbrt", "abs", "ln", "log", "log2", "exp", "floor", "ceil", "round",
        "sign", "sgn", "min", "max", "pow", "root",
    ]

    static func parse(_ input: String) throws -> MathExpr {
        let normalized = normalize(input)
        let tokens = try tokenize(normalized)
        guard !tokens.isEmpty else { throw ExpressionError.empty }
        var p = TokenParser(tokens: tokens)
        let expr = try p.parseExpression()
        if p.index < tokens.count {
            throw ExpressionError.unexpected("Unexpected '\(tokens[p.index].text)'")
        }
        return expr
    }

    /// Strips "y =", "f(x) =" prefixes and rewrites LaTeX into plain notation.
    static func normalize(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("$") && s.hasSuffix("$") && s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        if let eq = s.lastIndex(of: "=") {
            s = String(s[s.index(after: eq)...])
        }
        // \frac{a}{b} -> ((a)/(b)), applied repeatedly for nesting.
        s = rewriteFrac(s)
        let replacements: [(String, String)] = [
            ("\\left", ""), ("\\right", ""), ("\\cdot", "*"), ("\\times", "*"), ("\\div", "/"),
            ("\\pi", "pi"), ("\\sqrt", "sqrt"), ("\\ln", "ln"), ("\\log", "log"),
            ("\\exp", "exp"), ("\\sin", "sin"), ("\\cos", "cos"), ("\\tan", "tan"), ("\\sec", "sec"),
            ("\\csc", "csc"), ("\\cot", "cot"), ("\\arcsin", "asin"), ("\\arccos", "acos"), ("\\arctan", "atan"),
            ("\\sinh", "sinh"), ("\\cosh", "cosh"), ("\\tanh", "tanh"), ("\\,", ""), ("\\;", ""), ("\\!", ""),
            ("{", "("), ("}", ")"), ("[", "("), ("]", ")"), ("−", "-"), ("–", "-"), ("×", "*"), ("·", "*"),
            ("÷", "/"), ("²", "^2"), ("³", "^3"), ("√", "sqrt"), ("**", "^"), ("π", "pi"),
        ]
        for (a, b) in replacements { s = s.replacingOccurrences(of: a, with: b) }
        return s
    }

    private static func rewriteFrac(_ input: String) -> String {
        var s = input
        while let range = s.range(of: "\\frac") {
            let afterCmd = range.upperBound
            guard let (num, afterNum) = bracedGroup(in: s, from: afterCmd),
                  let (den, afterDen) = bracedGroup(in: s, from: afterNum) else {
                s.replaceSubrange(range, with: "")
                continue
            }
            s.replaceSubrange(range.lowerBound..<afterDen, with: "((\(num))/(\(den)))")
        }
        return s
    }

    /// Reads `{...}` (with nesting) starting at `from`, skipping spaces. A single non-brace character
    /// is accepted too, as in `\frac12`.
    static func bracedGroup(in s: String, from: String.Index) -> (String, String.Index)? {
        var i = from
        while i < s.endIndex, s[i] == " " { i = s.index(after: i) }
        guard i < s.endIndex else { return nil }
        if s[i] != "{" {
            return (String(s[i]), s.index(after: i))
        }
        var depth = 0
        var j = i
        while j < s.endIndex {
            if s[j] == "{" { depth += 1 }
            if s[j] == "}" {
                depth -= 1
                if depth == 0 {
                    let inner = String(s[s.index(after: i)..<j])
                    return (inner, s.index(after: j))
                }
            }
            j = s.index(after: j)
        }
        return nil
    }

    struct Token {
        enum Kind { case number, identifier, op, lparen, rparen, comma, bar }
        let kind: Kind
        let text: String
        var value: Double = 0
    }

    static func tokenize(_ s: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                var sawDot = false
                var sawExp = false
                while j < chars.count {
                    let d = chars[j]
                    if d.isNumber { j += 1; continue }
                    if d == "." && !sawDot && !sawExp { sawDot = true; j += 1; continue }
                    if (d == "e" || d == "E") && !sawExp, j + 1 < chars.count,
                       chars[j + 1].isNumber || ((chars[j + 1] == "-" || chars[j + 1] == "+") && j + 2 < chars.count && chars[j + 2].isNumber) {
                        // Only treat as exponent when followed by digits, so "2e" stays 2·e.
                        sawExp = true
                        j += 2
                        continue
                    }
                    break
                }
                let text = String(chars[i..<j])
                guard let v = Double(text) else { throw ExpressionError.unexpected("Bad number \(text)") }
                tokens.append(Token(kind: .number, text: text, value: v))
                i = j
                continue
            }
            if c.isLetter || c == "\\" || c == "_" {
                var j = i
                if c == "\\" { j += 1 }
                while j < chars.count, chars[j].isLetter { j += 1 }
                var word = String(chars[i..<j]).replacingOccurrences(of: "\\", with: "")
                if word.isEmpty { i = j; continue }
                // log2 is a single function name.
                if word == "log", j < chars.count, chars[j] == "2", !(j + 1 < chars.count && chars[j + 1].isNumber) {
                    word = "log2"; j += 1
                }
                tokens.append(contentsOf: splitIdentifier(word))
                i = j
                continue
            }
            switch c {
            case "+", "-", "*", "/", "^", "!": tokens.append(Token(kind: .op, text: String(c)))
            case "(": tokens.append(Token(kind: .lparen, text: "("))
            case ")": tokens.append(Token(kind: .rparen, text: ")"))
            case ",": tokens.append(Token(kind: .comma, text: ","))
            case "|": tokens.append(Token(kind: .bar, text: "|"))
            default: throw ExpressionError.unexpected("Unexpected '\(c)'")
            }
            i += 1
        }
        return tokens
    }

    /// Splits letter runs like "xsinx" or "2pix" into known names and single-letter variables.
    static func splitIdentifier(_ word: String) -> [Token] {
        let known = functions.union(["pi", "tau"])
        if known.contains(word) || word.count == 1 { return [Token(kind: .identifier, text: word)] }
        var result: [Token] = []
        var rest = Substring(word)
        let sortedNames = known.sorted { $0.count > $1.count }
        while !rest.isEmpty {
            if let name = sortedNames.first(where: { rest.hasPrefix($0) }) {
                result.append(Token(kind: .identifier, text: name))
                rest = rest.dropFirst(name.count)
            } else {
                result.append(Token(kind: .identifier, text: String(rest.first!)))
                rest = rest.dropFirst()
            }
        }
        return result
    }

    struct TokenParser {
        let tokens: [Token]
        var index = 0
        var barDepth = 0

        var current: Token? { index < tokens.count ? tokens[index] : nil }

        mutating func parseExpression() throws -> MathExpr {
            var lhs = try parseTerm()
            while let t = current, t.kind == .op, t.text == "+" || t.text == "-" {
                index += 1
                let rhs = try parseTerm()
                lhs = .binary(Character(t.text), lhs, rhs)
            }
            return lhs
        }

        mutating func parseTerm() throws -> MathExpr {
            var lhs = try parseUnary()
            while let t = current {
                if t.kind == .op, t.text == "*" || t.text == "/" {
                    index += 1
                    let rhs = try parseUnary()
                    lhs = .binary(Character(t.text), lhs, rhs)
                } else if startsImplicitFactor(t) {
                    let rhs = try parsePower()
                    lhs = .binary("*", lhs, rhs)
                } else {
                    break
                }
            }
            return lhs
        }

        func startsImplicitFactor(_ t: Token) -> Bool {
            switch t.kind {
            case .number, .identifier, .lparen: return true
            case .bar: return barDepth == 0
            default: return false
            }
        }

        mutating func parseUnary() throws -> MathExpr {
            if let t = current, t.kind == .op, t.text == "-" || t.text == "+" {
                index += 1
                let operand = try parseUnary()
                return t.text == "-" ? .unary("-", operand) : operand
            }
            return try parsePower()
        }

        mutating func parsePower() throws -> MathExpr {
            let base = try parsePostfix()
            if let t = current, t.kind == .op, t.text == "^" {
                index += 1
                let exponent = try parseUnary()
                return .binary("^", base, exponent)
            }
            return base
        }

        mutating func parsePostfix() throws -> MathExpr {
            var e = try parsePrimary()
            while let t = current, t.kind == .op, t.text == "!" {
                index += 1
                e = .unary("!", e)
            }
            return e
        }

        mutating func parsePrimary() throws -> MathExpr {
            guard let t = current else { throw ExpressionError.unexpected("Expression ended early") }
            switch t.kind {
            case .number:
                index += 1
                return .number(t.value)
            case .identifier:
                index += 1
                if ExpressionParser.functions.contains(t.text) {
                    // f(x) power: "sin^2(x)" means (sin x)^2.
                    var outerPower: MathExpr?
                    if let n = current, n.kind == .op, n.text == "^" {
                        index += 1
                        outerPower = try parsePrimary()
                    }
                    var args: [MathExpr] = []
                    if let n = current, n.kind == .lparen {
                        index += 1
                        if let c = current, c.kind != .rparen {
                            args.append(try parseExpression())
                            while let c2 = current, c2.kind == .comma {
                                index += 1
                                args.append(try parseExpression())
                            }
                        }
                        guard let close = current, close.kind == .rparen else {
                            throw ExpressionError.unexpected("Missing ')' after \(t.text)")
                        }
                        index += 1
                        // "sqrt(x)^2" style powers bind to the call result.
                    } else {
                        args.append(try parsePower())
                    }
                    var call = MathExpr.call(t.text, args)
                    if let p = outerPower { call = .binary("^", call, p) }
                    return call
                }
                return .variable(t.text)
            case .lparen:
                index += 1
                let e = try parseExpression()
                guard let close = current, close.kind == .rparen else {
                    throw ExpressionError.unexpected("Missing ')'")
                }
                index += 1
                return e
            case .bar:
                index += 1
                barDepth += 1
                let e = try parseExpression()
                barDepth -= 1
                guard let close = current, close.kind == .bar else {
                    throw ExpressionError.unexpected("Missing closing '|'")
                }
                index += 1
                return .call("abs", [e])
            default:
                throw ExpressionError.unexpected("Unexpected '\(t.text)'")
            }
        }
    }
}

/// Samples a function into drawable polyline segments, breaking at discontinuities and asymptotes.
enum FunctionSampler {
    static func sample(_ expr: MathExpr, xMin: Double, xMax: Double, yMin: Double, yMax: Double,
                       domain: ClosedRange<Double>? = nil, samples: Int = 480) -> [[CGPoint]] {
        guard xMax > xMin, yMax > yMin, samples > 2 else { return [] }
        let lo = max(xMin, domain?.lowerBound ?? xMin)
        let hi = min(xMax, domain?.upperBound ?? xMax)
        guard hi > lo else { return [] }
        let yRange = yMax - yMin
        let clipLow = yMin - yRange * 4
        let clipHigh = yMax + yRange * 4
        var segments: [[CGPoint]] = []
        var current: [CGPoint] = []
        var prevY: Double?
        let step = (hi - lo) / Double(samples)
        for i in 0...samples {
            let x = lo + Double(i) * step
            let y = expr.evaluate(x: x)
            if !y.isFinite || y < clipLow || y > clipHigh {
                if current.count > 1 { segments.append(current) }
                current = []
                prevY = nil
                continue
            }
            if let p = prevY, abs(y - p) > yRange * 1.5 {
                // A jump this large between neighbouring samples is an asymptote, not a steep curve.
                let mid = expr.evaluate(x: x - step / 2)
                let monotone = mid.isFinite && ((mid - p) * (y - mid) >= 0) && abs(mid - p) < yRange * 1.5 && abs(y - mid) < yRange * 1.5
                if !monotone {
                    if current.count > 1 { segments.append(current) }
                    current = []
                }
            }
            current.append(CGPoint(x: x, y: y))
            prevY = y
        }
        if current.count > 1 { segments.append(current) }
        return segments
    }
}
