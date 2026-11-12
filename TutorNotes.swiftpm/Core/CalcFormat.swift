import Foundation

// Turning a value into what the result line shows, under the SETUP options.

enum CalcNumberFormat: Codable, Hashable {
    /// Norm 1 or Norm 2: when results switch to exponent display.
    case norm(Int)
    /// Fixed decimal places, 0–9.
    case fix(Int)
    /// Significant digits, 0–9 (0 means 10).
    case sci(Int)
}

enum CalcIOMode: String, Codable {
    /// MthIO, MathO: textbook input and output.
    case mathO
    /// MthIO, LineO: textbook input, linear output.
    case lineO
    /// LineIO: linear input and output.
    case lineIO

    var naturalInput: Bool { self != .lineIO }
    var naturalOutput: Bool { self == .mathO }
}

enum CalcFractionStyle: String, Codable {
    case mixed, improper
}

struct CalcDisplayOptions {
    var format: CalcNumberFormat = .norm(1)
    var io: CalcIOMode = .mathO
    var fractions: CalcFractionStyle = .improper
}

enum CalcFormat {
    /// The line for a result. `decimal` is the S⇔D state; `eng` an ENG shift; `dms` the °'" toggle.
    static func line(_ value: CalcValue, options o: CalcDisplayOptions, decimal: Bool = false, eng: Int? = nil, dms: Bool = false) -> CalcLine {
        if dms, let l = dmsLine(value.double) { return l }
        if let eng { return decimalLine(value.double, format: o.format, eng: eng) }
        if !decimal, let exact = exactLine(value, options: o) { return exact }
        return decimalLine(value.double, format: o.format, eng: nil)
    }

    /// Whether S⇔D would change how this value is shown.
    static func hasExactForm(_ value: CalcValue, options o: CalcDisplayOptions) -> Bool {
        guard let exact = exactLine(value, options: o) else { return false }
        return exact != decimalLine(value.double, format: o.format, eng: nil)
    }

    // MARK: Exact forms

    private static func digits(_ n: Int64) -> [CalcNode] {
        String(Swift.abs(n)).compactMap { $0.wholeNumberValue }.map { .token(.digit($0)) }
    }

    private static func digitCount(_ n: Int64) -> Int { String(Swift.abs(n)).count }

    private static let minus = CalcNode.token(.text("−"))

    static func exactLine(_ value: CalcValue, options o: CalcDisplayOptions) -> CalcLine? {
        switch value {
        case .real:
            return nil
        case .rational(let q):
            if q.isInteger {
                guard digitCount(q.num) <= 10 else { return nil }
                return CalcLine((q.isNegative ? [minus] : []) + digits(q.num))
            }
            return fractionLine(q, options: o)
        case .surd(let a, let b, let r):
            guard o.io.naturalOutput else { return nil }
            return surdLine(a, b, r)
        case .pi(let c):
            guard o.io.naturalOutput, digitCount(c.num) + digitCount(c.den) <= 10 else { return nil }
            var numerator: [CalcNode] = Swift.abs(c.num) == 1 ? [] : digits(c.num)
            numerator.append(.token(.pi))
            let sign: [CalcNode] = c.isNegative ? [minus] : []
            if c.den == 1 { return CalcLine(sign + numerator) }
            return CalcLine(sign + [.template(.fraction, [CalcLine(numerator), CalcLine(digits(c.den))])])
        }
    }

    private static func fractionLine(_ q: CalcRational, options o: CalcDisplayOptions) -> CalcLine? {
        let sign: [CalcNode] = q.isNegative ? [minus] : []
        let num = Swift.abs(q.num), den = q.den
        let whole = num / den, rest = num % den
        let mixed = o.fractions == .mixed && whole > 0
        let total = mixed ? digitCount(whole) + digitCount(rest) + digitCount(den) : digitCount(num) + digitCount(den)
        guard total <= 10 else { return nil }
        if o.io.naturalOutput {
            if mixed {
                return CalcLine(sign + [.template(.mixed, [CalcLine(digits(whole)), CalcLine(digits(rest)), CalcLine(digits(den))])])
            }
            return CalcLine(sign + [.template(.fraction, [CalcLine(digits(num)), CalcLine(digits(den))])])
        }
        // Linear output: 3⌟4 and 1⌟1⌟2.
        let mark = CalcNode.token(.text("⌟"))
        if mixed { return CalcLine(sign + digits(whole) + [mark] + digits(rest) + [mark] + digits(den)) }
        return CalcLine(sign + digits(num) + [mark] + digits(den))
    }

    /// (P + Q√r) / L.
    private static func surdLine(_ a: CalcRational, _ b: CalcRational, _ r: Int64) -> CalcLine? {
        let g = CalcRational.gcd(a.den, b.den)
        let (l, o) = (a.den / g).multipliedReportingOverflow(by: b.den)
        guard !o else { return nil }
        let (p, o1) = a.num.multipliedReportingOverflow(by: l / a.den)
        let (qq, o2) = b.num.multipliedReportingOverflow(by: l / b.den)
        guard !o1, !o2, digitCount(p) + digitCount(qq) + digitCount(r) + digitCount(l) <= 10 else { return nil }
        func rootTerm(_ coef: Int64) -> [CalcNode] {
            (Swift.abs(coef) == 1 ? [] : digits(coef)) + [.template(.sqrt, [CalcLine(digits(r))])]
        }
        var numerator: [CalcNode] = []
        if p != 0 {
            numerator = (p < 0 ? [minus] : []) + digits(p)
            numerator.append(.token(.text(qq < 0 ? "−" : "+")))
            numerator += rootTerm(qq)
        } else {
            numerator = rootTerm(qq)
            if l == 1 && qq < 0 { numerator.insert(minus, at: 0) }
        }
        if l == 1 { return CalcLine(numerator) }
        if p == 0 && qq < 0 {
            return CalcLine([minus, .template(.fraction, [CalcLine(numerator), CalcLine(digits(l))])])
        }
        return CalcLine([.template(.fraction, [CalcLine(numerator), CalcLine(digits(l))])])
    }

    // MARK: Decimals

    /// Mantissa text and exponent (nil when not in exponent form).
    static func decimalParts(_ d: Double, format: CalcNumberFormat, eng: Int? = nil) -> (String, Int?) {
        if d == 0 { return ("0", nil) }
        let rounded10 = String(format: "%.9e", d)
        let parts = rounded10.split(separator: "e")
        let exponent = Int(parts[1]) ?? 0
        let value = Double(rounded10) ?? d

        if let eng {
            var e3 = Int((Double(exponent) / 3).rounded(.down)) * 3 + eng * 3
            e3 = min(max(e3, -99), 99)
            let mantissa = value / Foundation.pow(10, Double(e3))
            return (trimmed(String(format: "%.\(max(0, 9 - Int(Foundation.log10(Swift.abs(mantissa)).rounded(.down))))f", mantissa)), e3)
        }

        switch format {
        case .norm(let k):
            let small = k == 1 ? 0.01 : 1e-9
            if Swift.abs(value) < small || exponent >= 10 {
                return (trimmed(String(parts[0])), exponent)
            }
            let decimals = max(0, 9 - exponent)
            return (trimmed(String(format: "%.\(decimals)f", value)), nil)
        case .fix(let k):
            if Swift.abs(value) >= 1e10 {
                let s = String(format: "%.\(k)e", d).split(separator: "e")
                return (String(s[0]), Int(s[1]) ?? 0)
            }
            return (String(format: "%.\(k)f", d), nil)
        case .sci(let k):
            let digits = k == 0 ? 10 : k
            let s = String(format: "%.\(digits - 1)e", d).split(separator: "e")
            return (String(s[0]), Int(s[1]) ?? 0)
        }
    }

    private static func trimmed(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t == "-0" ? "0" : t
    }

    static func decimalLine(_ d: Double, format: CalcNumberFormat, eng: Int?) -> CalcLine {
        let (mantissa, exponent) = decimalParts(d, format: format, eng: eng)
        var nodes = textNodes(mantissa)
        if let exponent {
            nodes.append(.template(.exp10, [CalcLine(textNodes(String(exponent)))]))
        }
        return CalcLine(nodes)
    }

    private static func textNodes(_ s: String) -> [CalcNode] {
        s.map { ch -> CalcNode in
            if let d = ch.wholeNumberValue { return .token(.digit(d)) }
            if ch == "." { return .token(.point) }
            if ch == "-" { return minus }
            return .token(.text(String(ch)))
        }
    }

    // MARK: Degrees, minutes, seconds

    static func dmsLine(_ d: Double) -> CalcLine? {
        guard Swift.abs(d) < 10_000_000 else { return nil }
        var totalSeconds = (Swift.abs(d) * 3600 * 100).rounded() / 100
        let degrees = (totalSeconds / 3600).rounded(.down)
        totalSeconds -= degrees * 3600
        let minutes = (totalSeconds / 60).rounded(.down)
        let seconds = totalSeconds - minutes * 60
        var nodes: [CalcNode] = d < 0 ? [minus] : []
        nodes += textNodes(String(Int(degrees))) + [.token(.text("°"))]
        nodes += textNodes(String(Int(minutes))) + [.token(.text("'"))]
        nodes += textNodes(trimmed(String(format: "%.2f", seconds))) + [.token(.text("\""))]
        return CalcLine(nodes)
    }

    // MARK: Prime factorisation (FACT)

    /// Like the calculator: primes up to 997 are found; anything left is shown in brackets.
    static func factorLine(_ n: Int64) -> CalcLine? {
        guard n > 1, n < 10_000_000_000 else { return nil }
        var rest = n
        var nodes: [CalcNode] = []
        var p: Int64 = 2
        while p <= 997 && p * p <= rest {
            var k = 0
            while rest % p == 0 { rest /= p; k += 1 }
            if k > 0 {
                if !nodes.isEmpty { nodes.append(.token(.binary(.times))) }
                nodes += digits(p)
                if k > 1 { nodes.append(.template(.power, [CalcLine(digits(Int64(k)))])) }
            }
            p += p == 2 ? 1 : 2
        }
        if rest > 1 {
            if !nodes.isEmpty { nodes.append(.token(.binary(.times))) }
            if rest > 997 {
                nodes += [.token(.openParen)] + digits(rest) + [.token(.closeParen)]
            } else {
                nodes += digits(rest)
            }
        }
        return CalcLine(nodes)
    }
}
