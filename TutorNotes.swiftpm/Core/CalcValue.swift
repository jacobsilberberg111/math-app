import Foundation

// The calculator's numbers. Like the fx-82AU PLUS II in MathO mode, results stay exact where the
// screen can show them exactly (fractions, a + b√r surd forms and multiples of π) and fall back to
// a decimal otherwise. Exact arithmetic is done in Int64 and drops to Double on overflow.

enum CalcError: Error, Equatable {
    case math, syntax, stack

    var message: String {
        switch self {
        case .math: return "Math ERROR"
        case .syntax: return "Syntax ERROR"
        case .stack: return "Stack ERROR"
        }
    }
}

fileprivate func calcMul(_ a: Int64, _ b: Int64) -> Int64? {
    let (r, o) = a.multipliedReportingOverflow(by: b)
    return o ? nil : r
}

fileprivate func calcAdd(_ a: Int64, _ b: Int64) -> Int64? {
    let (r, o) = a.addingReportingOverflow(b)
    return o ? nil : r
}

/// A reduced fraction with a positive denominator.
struct CalcRational: Hashable, Codable {
    private(set) var num: Int64
    private(set) var den: Int64

    init?(_ n: Int64, _ d: Int64 = 1) {
        guard d != 0, n != .min, d != .min else { return nil }
        var n = n, d = d
        if d < 0 { n = -n; d = -d }
        let g = CalcRational.gcd(Swift.abs(n), d)
        num = n / g
        den = d / g
    }

    static let zero = CalcRational(0)!
    static let one = CalcRational(1)!

    static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a == 0 ? 1 : a
    }

    var double: Double { Double(num) / Double(den) }
    var isInteger: Bool { den == 1 }
    var isZero: Bool { num == 0 }
    var isNegative: Bool { num < 0 }
    var negated: CalcRational { CalcRational(-num, den)! }
    var abs: CalcRational { isNegative ? negated : self }

    func adding(_ o: CalcRational) -> CalcRational? {
        guard let a = calcMul(num, o.den), let b = calcMul(o.num, den), let n = calcAdd(a, b),
              let d = calcMul(den, o.den) else { return nil }
        return CalcRational(n, d)
    }

    func subtracting(_ o: CalcRational) -> CalcRational? { adding(o.negated) }

    func multiplying(_ o: CalcRational) -> CalcRational? {
        let g1 = CalcRational.gcd(Swift.abs(num), o.den), g2 = CalcRational.gcd(Swift.abs(o.num), den)
        guard let n = calcMul(num / g1, o.num / g2), let d = calcMul(den / g2, o.den / g1) else { return nil }
        return CalcRational(n, d)
    }

    func dividing(_ o: CalcRational) -> CalcRational? {
        guard o.num != 0, let inv = CalcRational(o.den, o.num) else { return nil }
        return multiplying(inv)
    }

    func power(_ n: Int) -> CalcRational? {
        if n == 0 { return .one }
        if n < 0 { return CalcRational.one.dividing(self)?.power(-n) }
        var result = CalcRational.one, base = self, e = n
        while e > 0 {
            if e & 1 == 1 { guard let r = result.multiplying(base) else { return nil }; result = r }
            e >>= 1
            if e > 0 { guard let b = base.multiplying(base) else { return nil }; base = b }
        }
        return result
    }

    /// An exact fraction for a decimal literal such as "12.375", when it fits.
    static func decimal(_ s: String) -> CalcRational? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let whole = parts[0].isEmpty ? "0" : String(parts[0])
        let frac = parts.count == 2 ? String(parts[1]) : ""
        guard frac.count <= 18, let n = Int64(whole + frac) else { return nil }
        var d: Int64 = 1
        for _ in 0..<frac.count { guard let nd = calcMul(d, 10) else { return nil }; d = nd }
        return CalcRational(n, d)
    }

    /// The closest fraction with a small denominator, when it matches `x` to about 13 digits.
    static func approximating(_ x: Double, maxDen: Int64 = 100_000) -> CalcRational? {
        guard x.isFinite, Swift.abs(x) < 1e15 else { return nil }
        var h0: Int64 = 0, h1: Int64 = 1, k0: Int64 = 1, k1: Int64 = 0
        var v = x
        for _ in 0..<40 {
            let a = v.rounded(.down)
            guard Swift.abs(a) < 1e15 else { return nil }
            let ai = Int64(a)
            guard let h2a = calcMul(ai, h1), let h2 = calcAdd(h2a, h0), let k2a = calcMul(ai, k1), let k2 = calcAdd(k2a, k0) else { return nil }
            if k2 > maxDen { return nil }
            (h0, h1, k0, k1) = (h1, h2, k1, k2)
            if Swift.abs(Double(h1) / Double(k1) - x) <= 1e-13 * max(1, Swift.abs(x)) { return CalcRational(h1, k1) }
            let rem = v - a
            if rem < 1e-15 { return nil }
            v = 1 / rem
        }
        return nil
    }
}

enum CalcValue: Hashable, Codable {
    case rational(CalcRational)
    /// a + b√r, with r square-free and at least 2, and b ≠ 0.
    case surd(CalcRational, CalcRational, Int64)
    /// c·π, c ≠ 0.
    case pi(CalcRational)
    case real(Double)

    static let zero = CalcValue.rational(.zero)
    static func int(_ n: Int64) -> CalcValue { .rational(CalcRational(n)!) }

    var double: Double {
        switch self {
        case .rational(let q): return q.double
        case .surd(let a, let b, let r): return a.double + b.double * Double(r).squareRoot()
        case .pi(let c): return c.double * Double.pi
        case .real(let d): return d
        }
    }

    var isZero: Bool {
        switch self {
        case .rational(let q): return q.isZero
        case .real(let d): return d == 0
        default: return false
        }
    }

    var rationalValue: CalcRational? {
        if case .rational(let q) = self { return q }
        return nil
    }

    /// The value as an integer, when it is one (exact or a whole-number decimal).
    var integerValue: Int64? {
        switch self {
        case .rational(let q): return q.isInteger ? q.num : nil
        case .real(let d):
            guard d == d.rounded(), Swift.abs(d) < 9.2e18 else { return nil }
            return Int64(d)
        default: return nil
        }
    }

    var isExact: Bool {
        if case .real = self { return false }
        return true
    }
}

/// Exact-where-possible arithmetic.
enum CalcMath {
    /// Rejects results the fx-82 can't hold: anything at or beyond 10^100, and NaN.
    static func checked(_ d: Double) throws -> CalcValue {
        guard d.isFinite, Swift.abs(d) < 1e100 else { throw CalcError.math }
        if Swift.abs(d) < 1e-99 { return .zero }
        return .real(d)
    }

    static func surd(_ a: CalcRational, _ b: CalcRational, _ r: Int64) -> CalcValue {
        if b.isZero { return .rational(a) }
        if r == 1 { if let s = a.adding(b) { return .rational(s) } }
        return .surd(a, b, r)
    }

    static func neg(_ x: CalcValue) -> CalcValue {
        switch x {
        case .rational(let q): return .rational(q.negated)
        case .surd(let a, let b, let r): return .surd(a.negated, b.negated, r)
        case .pi(let c): return .pi(c.negated)
        case .real(let d): return .real(-d)
        }
    }

    static func add(_ x: CalcValue, _ y: CalcValue) throws -> CalcValue {
        if case .rational(let q) = x, q.isZero { return y }
        if case .rational(let q) = y, q.isZero { return x }
        switch (x, y) {
        case let (.rational(a), .rational(b)):
            if let s = a.adding(b) { return .rational(s) }
        case let (.rational(q), .surd(a, b, r)), let (.surd(a, b, r), .rational(q)):
            if let s = a.adding(q) { return surd(s, b, r) }
        case let (.surd(a1, b1, r1), .surd(a2, b2, r2)) where r1 == r2:
            if let a = a1.adding(a2), let b = b1.adding(b2) { return surd(a, b, r1) }
        case let (.pi(c1), .pi(c2)):
            if let c = c1.adding(c2) { return c.isZero ? .zero : .pi(c) }
        default:
            break
        }
        return try checked(x.double + y.double)
    }

    static func sub(_ x: CalcValue, _ y: CalcValue) throws -> CalcValue { try add(x, neg(y)) }

    static func mul(_ x: CalcValue, _ y: CalcValue) throws -> CalcValue {
        if x.isZero || y.isZero { return .zero }
        switch (x, y) {
        case let (.rational(a), .rational(b)):
            if let p = a.multiplying(b) { return .rational(p) }
        case let (.rational(q), .surd(a, b, r)), let (.surd(a, b, r), .rational(q)):
            if let qa = q.multiplying(a), let qb = q.multiplying(b) { return surd(qa, qb, r) }
        case let (.rational(q), .pi(c)), let (.pi(c), .rational(q)):
            if let p = q.multiplying(c) { return .pi(p) }
        case let (.surd(a1, b1, r1), .surd(a2, b2, r2)):
            if r1 == r2 {
                if let aa = a1.multiplying(a2), let bb = b1.multiplying(b2), let rr = CalcRational(r1),
                   let bbr = bb.multiplying(rr), let first = aa.adding(bbr),
                   let ab = a1.multiplying(b2), let ba = a2.multiplying(b1), let second = ab.adding(ba) {
                    return surd(first, second, r1)
                }
            } else if a1.isZero && a2.isZero, let prod = calcMul(r1, r2), let (out, inside) = squareFreeSplit(prod),
                      let coef = b1.multiplying(b2), let o = CalcRational(out), let c = coef.multiplying(o) {
                return surd(.zero, c, inside)
            }
        default:
            break
        }
        return try checked(x.double * y.double)
    }

    static func div(_ x: CalcValue, _ y: CalcValue) throws -> CalcValue {
        guard !y.isZero, y.double != 0 else { throw CalcError.math }
        if x.isZero { return .zero }
        switch (x, y) {
        case let (_, .rational(q)):
            if let inv = CalcRational.one.dividing(q) { return try mul(x, .rational(inv)) }
        case let (.pi(c1), .pi(c2)):
            if let q = c1.dividing(c2) { return .rational(q) }
        case let (.rational, .surd(a, b, r)):
            if let v = try divideBySurd(x, a, b, r) { return v }
        case let (.surd(_, _, r1), .surd(a, b, r2)) where r1 == r2:
            if let v = try divideBySurd(x, a, b, r2) { return v }
        case let (.surd(a1, b1, r1), .surd(a2, b2, r2)) where a1.isZero && a2.isZero:
            // b1√r1 / (b2√r2) = b1√(r1·r2) / (b2·r2)
            if let prod = calcMul(r1, r2), let (out, inside) = squareFreeSplit(prod),
               let o = CalcRational(out), let num = b1.multiplying(o), let r2q = CalcRational(r2),
               let den = b2.multiplying(r2q), let c = num.dividing(den) {
                return surd(.zero, c, inside)
            }
        default:
            break
        }
        return try checked(x.double / y.double)
    }

    /// x / (a + b√r) = x(a − b√r) / (a² − b²r), when that stays exact.
    private static func divideBySurd(_ x: CalcValue, _ a: CalcRational, _ b: CalcRational, _ r: Int64) throws -> CalcValue? {
        guard let aa = a.multiplying(a), let bb = b.multiplying(b), let rr = CalcRational(r),
              let bbr = bb.multiplying(rr), let denom = aa.subtracting(bbr), !denom.isZero else { return nil }
        let numerator = try mul(x, surd(a, b.negated, r))
        return numerator.isExact ? try div(numerator, .rational(denom)) : nil
    }

    /// n = out² · inside with `inside` square-free. Gives up (nil) on huge numbers.
    static func squareFreeSplit(_ n: Int64) -> (Int64, Int64)? {
        guard n > 0, n <= 1_000_000_000_000 else { return nil }
        var inside = n, out: Int64 = 1, p: Int64 = 2
        while p * p <= inside {
            while inside % (p * p) == 0 { inside /= p * p; out *= p }
            p += p == 2 ? 1 : 2
        }
        return (out, inside)
    }

    static func sqrt(_ x: CalcValue) throws -> CalcValue {
        if case .rational(let q) = x {
            guard !q.isNegative else { throw CalcError.math }
            if let nd = calcMul(q.num, q.den), let (out, inside) = squareFreeSplit(nd),
               let c = CalcRational(out, q.den) {
                return inside == 1 ? .rational(c) : .surd(.zero, c, inside)
            }
        }
        let d = x.double
        guard d >= 0 else { throw CalcError.math }
        return try checked(d.squareRoot())
    }

    /// The exact k-th root of an integer, when there is one.
    static func integerRoot(_ n: Int64, _ k: Int) -> Int64? {
        guard k >= 1 else { return nil }
        if n < 0 { return k % 2 == 1 ? integerRoot(-n, k).map { -$0 } : nil }
        let guess = Int64(Foundation.pow(Double(n), 1 / Double(k)).rounded())
        for c in max(0, guess - 1)...(guess + 1) {
            if let p = CalcRational(c)?.power(k), p.isInteger, p.num == n { return c }
        }
        return nil
    }

    /// ˣ√y. Exact for perfect powers of fractions; odd roots of negatives are real.
    static func root(index: CalcValue, _ x: CalcValue) throws -> CalcValue {
        if let k = index.integerValue, k == 2 { return try sqrt(x) }
        if let k = index.integerValue, k >= 1, k <= 64, case .rational(let q) = x,
           let n = integerRoot(q.num, Int(k)), let d = integerRoot(q.den, Int(k)), let r = CalcRational(n, d) {
            return .rational(r)
        }
        let n = index.double, d = x.double
        guard n != 0 else { throw CalcError.math }
        if d < 0 {
            guard let k = index.integerValue, k % 2 != 0 else { throw CalcError.math }
            return try checked(-Foundation.pow(-d, 1 / n))
        }
        return try checked(Foundation.pow(d, 1 / n))
    }

    static func pow(_ x: CalcValue, _ y: CalcValue) throws -> CalcValue {
        if let n = y.integerValue, y.isExact, Swift.abs(n) <= 4096 {
            if x.isZero {
                guard n > 0 else { throw CalcError.math }
                return .zero
            }
            if x.isExact {
                var result = CalcValue.int(1), base = x, e = Swift.abs(n)
                while e > 0 {
                    if e & 1 == 1 { result = try mul(result, base) }
                    e >>= 1
                    if e > 0 { base = try mul(base, base) }
                }
                return n < 0 ? try div(.int(1), result) : result
            }
        }
        if case .rational(let p) = y, !p.isInteger, p.den <= 64, case .rational = x {
            let r = try root(index: .int(p.den), x)
            if r.isExact { return try pow(r, .int(p.num)) }
        }
        let b = x.double, e = y.double
        if b == 0 {
            guard e > 0 else { throw CalcError.math }
            return .zero
        }
        if b < 0 {
            if e == e.rounded() { return try checked(Foundation.pow(b, e)) }
            // Real odd roots: (−8)^(1/3) = −2.
            guard case .rational(let p) = y, p.den % 2 == 1 else { throw CalcError.math }
            let mag = Foundation.pow(-b, e)
            return try checked(p.num % 2 == 0 ? mag : -mag)
        }
        return try checked(Foundation.pow(b, e))
    }
}
