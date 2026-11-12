import Foundation

// Parsing and evaluating what was typed, with the fx-82AU PLUS II's priority sequence:
// brackets, functions with a closing bracket, postfix functions and powers/roots, fractions,
// the negative sign, STAT estimates, implied multiplication, nPr/nCr, × ÷, then + −.
// Missing closing brackets are closed at the end, as on the calculator.

enum CalcAngle: String, Codable, CaseIterable {
    case deg, rad, gra

    var indicator: String {
        switch self {
        case .deg: return "D"
        case .rad: return "R"
        case .gra: return "G"
        }
    }
}

indirect enum CalcExpr {
    case value(CalcValue)
    case variable(String)
    case ans
    case ranNum
    case stat(CalcStatVar)
    case estimate(CalcStatVar, CalcExpr)
    case negate(CalcExpr)
    case binary(CalcBinary, CalcExpr, CalcExpr)
    case postfix(CalcPostfix, CalcExpr)
    case function(CalcFunction, [CalcExpr])
    case power(CalcExpr, CalcExpr)
    case root(CalcExpr, CalcExpr)
    case sqrt(CalcExpr)
    case cbrt(CalcExpr)
    case tenPower(CalcExpr)
    case ePower(CalcExpr)
    case logBase(CalcExpr, CalcExpr)
    case abs(CalcExpr)
    case fraction(CalcExpr, CalcExpr)
    case mixed(CalcExpr, CalcExpr, CalcExpr)
    case relation(CalcRelation, CalcExpr, CalcExpr)
}

struct CalcParser {
    private let nodes: [CalcNode]
    private var i = 0
    private let depth: Int

    private init(_ line: CalcLine, depth: Int) {
        nodes = line.nodes
        self.depth = depth
    }

    /// Statements separated by ":".
    static func parseStatements(_ line: CalcLine) throws -> [CalcExpr] {
        var groups: [[CalcNode]] = [[]]
        for n in line.nodes {
            if case .token(.colon) = n { groups.append([]) } else { groups[groups.count - 1].append(n) }
        }
        return try groups.map { try parse(CalcLine($0)) }
    }

    /// One expression, which may contain a single relation (VERIF).
    static func parse(_ line: CalcLine) throws -> CalcExpr {
        var p = CalcParser(line, depth: 0)
        let e = try p.parseRelation()
        guard p.i == p.nodes.count else { throw CalcError.syntax }
        return e
    }

    private static func parseSlot(_ line: CalcLine, depth: Int) throws -> CalcExpr {
        guard !line.isEmpty else { throw CalcError.syntax }
        guard depth < 24 else { throw CalcError.stack }
        var p = CalcParser(line, depth: depth + 1)
        let e = try p.parseSum()
        guard p.i == p.nodes.count else { throw CalcError.syntax }
        return e
    }

    private var peek: CalcNode? { i < nodes.count ? nodes[i] : nil }

    private var peekToken: CalcToken? {
        if case .token(let t) = peek { return t }
        return nil
    }

    private mutating func parseRelation() throws -> CalcExpr {
        let lhs = try parseSum()
        guard case .relation(let r) = peekToken else { return lhs }
        i += 1
        let rhs = try parseSum()
        if case .relation = peekToken { throw CalcError.syntax }
        return .relation(r, lhs, rhs)
    }

    private mutating func parseSum() throws -> CalcExpr {
        var lhs = try parseProduct()
        while case .binary(let op) = peekToken, op == .plus || op == .minus {
            i += 1
            lhs = .binary(op, lhs, try parseProduct())
        }
        return lhs
    }

    private mutating func parseProduct() throws -> CalcExpr {
        var lhs = try parsePermutation()
        while case .binary(let op) = peekToken, op == .times || op == .divide {
            i += 1
            lhs = .binary(op, lhs, try parsePermutation())
        }
        return lhs
    }

    private mutating func parsePermutation() throws -> CalcExpr {
        var lhs = try parseImplied()
        while case .binary(let op) = peekToken, op == .nPr || op == .nCr {
            i += 1
            lhs = .binary(op, lhs, try parseImplied())
        }
        return lhs
    }

    private mutating func parseImplied() throws -> CalcExpr {
        var lhs = try parseEstimate()
        while let next = peek, CalcParser.startsOperand(next) {
            lhs = .binary(.times, lhs, try parseEstimate())
        }
        return lhs
    }

    private mutating func parseEstimate() throws -> CalcExpr {
        var x = try parseNegative()
        while case .stat(let s) = peekToken, s.isEstimate {
            i += 1
            x = .estimate(s, x)
        }
        return x
    }

    private mutating func parseNegative() throws -> CalcExpr {
        // A leading "−" (the subtract key) is read as a sign too, which the calculator also allows.
        if case .negative = peekToken {
            i += 1
            return .negate(try parseNegative())
        }
        if case .binary(.minus) = peekToken {
            i += 1
            return .negate(try parseNegative())
        }
        return try parsePostfix()
    }

    private mutating func parsePostfix() throws -> CalcExpr {
        var x = try parseAtom()
        while let next = peek {
            switch next {
            case .token(.postfix(let p)):
                i += 1
                x = .postfix(p, x)
            case .template(.power, let slots):
                i += 1
                x = .power(x, try CalcParser.parseSlot(slots[0], depth: depth))
            case .template(.exp10, let slots):
                i += 1
                x = .binary(.times, x, .tenPower(try CalcParser.parseSlot(slots[0], depth: depth)))
            default:
                return x
            }
        }
        return x
    }

    static func isNumberToken(_ t: CalcToken) -> Bool {
        if case .digit = t { return true }
        return t == .point
    }

    static func startsOperand(_ n: CalcNode) -> Bool {
        switch n {
        case .template(let k, _): return k != .power && k != .exp10
        case .token(let t):
            switch t {
            case .digit, .point, .openParen, .function, .pi, .e, .variable, .ans, .ranNum: return true
            case .stat(let s): return !s.isEstimate
            default: return false
            }
        }
    }

    private mutating func readNumber() throws -> CalcValue {
        var s = ""
        while case .token(let t) = peek {
            if case .digit(let d) = t { s += String(d) } else if case .point = t {
                if s.contains(".") { throw CalcError.syntax }
                s += "."
            } else { break }
            i += 1
        }
        guard s != "." else { throw CalcError.syntax }
        if let q = CalcRational.decimal(s) { return .rational(q) }
        guard let d = Double(s) else { throw CalcError.syntax }
        return try CalcMath.checked(d)
    }

    private mutating func parseAtom() throws -> CalcExpr {
        guard depth < 24 else { throw CalcError.stack }
        guard let node = peek else { throw CalcError.syntax }
        switch node {
        case .template(let kind, let slots):
            i += 1
            func slot(_ k: Int) throws -> CalcExpr { try CalcParser.parseSlot(slots[k], depth: depth) }
            switch kind {
            case .fraction: return .fraction(try slot(0), try slot(1))
            case .mixed: return .mixed(try slot(0), try slot(1), try slot(2))
            case .sqrt: return .sqrt(try slot(0))
            case .cbrt: return .cbrt(try slot(0))
            case .root: return .root(try slot(0), try slot(1))
            case .tenPower: return .tenPower(try slot(0))
            case .ePower: return .ePower(try slot(0))
            case .logBase: return .logBase(try slot(0), try slot(1))
            case .abs: return .abs(try slot(0))
            case .exp10: return .tenPower(try slot(0))
            case .power: throw CalcError.syntax
            }
        case .token(let t):
            switch t {
            case .digit, .point:
                var value = try readNumber()
                // Sexagesimal: 2°20°30° is 2 degrees, 20 minutes, 30 seconds.
                if case .postfix(.dms) = peekToken {
                    i += 1
                    var parts: [CalcValue] = [value]
                    while parts.count < 3, case .token(let nt)? = peek, CalcParser.isNumberToken(nt) {
                        let save = i
                        let part = try readNumber()
                        guard case .postfix(.dms) = peekToken else { i = save; break }
                        i += 1
                        parts.append(part)
                    }
                    value = try CalcEvaluator.dmsValue(parts)
                }
                return .value(value)
            case .openParen:
                i += 1
                guard depth < 24 else { throw CalcError.stack }
                var inner = CalcParser(CalcLine(Array(nodes[i...])), depth: depth + 1)
                let e = try inner.parseSum()
                i += inner.i
                if case .closeParen = peekToken { i += 1 }
                return e
            case .function(let f):
                i += 1
                var inner = CalcParser(CalcLine(Array(nodes[i...])), depth: depth + 1)
                var args = [try inner.parseSum()]
                while case .comma = inner.peekToken {
                    inner.i += 1
                    args.append(try inner.parseSum())
                }
                i += inner.i
                if case .closeParen = peekToken { i += 1 }
                guard args.count == f.argumentCount else { throw CalcError.syntax }
                return .function(f, args)
            case .pi:
                i += 1
                return .value(.pi(.one))
            case .e:
                i += 1
                return .value(.real(M_E))
            case .variable(let v):
                i += 1
                return .variable(v)
            case .ans:
                i += 1
                return .ans
            case .ranNum:
                i += 1
                return .ranNum
            case .stat(let s) where !s.isEstimate:
                i += 1
                return .stat(s)
            default:
                throw CalcError.syntax
            }
        }
    }
}

// MARK: - Evaluation

struct CalcEvaluator {
    var angle: CalcAngle = .deg
    var variables: [String: CalcValue] = [:]
    var ans: CalcValue = .zero
    var statistics: CalcStatistics?
    var format: CalcNumberFormat = .norm(1)
    var random: () -> Double = { Double.random(in: 0..<1) }

    /// Pol/Rec results (r and θ, or x and y), written to X and Y.
    private(set) var pair: (CalcValue, CalcValue)?

    static func dmsValue(_ parts: [CalcValue]) throws -> CalcValue {
        var total = CalcValue.zero
        let scales: [Int64] = [1, 60, 3600]
        let negative = parts.first.map { $0.double < 0 } ?? false
        for (k, p) in parts.enumerated() {
            var part = try CalcMath.div(p, .int(scales[k]))
            if negative && k > 0 { part = CalcMath.neg(part) }
            total = try CalcMath.add(total, part)
        }
        return total
    }

    mutating func evaluate(_ e: CalcExpr) throws -> CalcValue {
        pair = nil
        if case .function(let f, let args) = e, f == .pol || f == .rec {
            let a = try eval(args[0]), b = try eval(args[1])
            let p = f == .pol ? try polar(a, b) : try rectangular(a, b)
            pair = p
            return p.0
        }
        return try eval(e)
    }

    private func eval(_ e: CalcExpr) throws -> CalcValue {
        switch e {
        case .value(let v): return v
        case .variable(let v): return variables[v] ?? .zero
        case .ans: return ans
        case .ranNum:
            let k = Int64((random() * 1000).rounded(.down))
            return .rational(CalcRational(min(999, k), 1000)!)
        case .stat(let s):
            guard let stats = statistics else { throw CalcError.math }
            return try CalcMath.checked(try stats.value(s))
        case .estimate(let s, let x):
            guard let stats = statistics else { throw CalcError.math }
            return try CalcMath.checked(try stats.estimate(s, x: try eval(x).double))
        case .negate(let x): return CalcMath.neg(try eval(x))
        case .binary(let op, let a, let b):
            let x = try eval(a), y = try eval(b)
            switch op {
            case .plus: return try CalcMath.add(x, y)
            case .minus: return try CalcMath.sub(x, y)
            case .times: return try CalcMath.mul(x, y)
            case .divide: return try CalcMath.div(x, y)
            case .nPr, .nCr: return try permutation(x, y, combinations: op == .nCr)
            }
        case .postfix(let p, let x): return try postfix(p, try eval(x))
        case .function(let f, let args): return try function(f, try args.map { try eval($0) })
        case .power(let a, let b): return try CalcMath.pow(try eval(a), try eval(b))
        case .root(let n, let x): return try CalcMath.root(index: try eval(n), try eval(x))
        case .sqrt(let x): return try CalcMath.sqrt(try eval(x))
        case .cbrt(let x): return try CalcMath.root(index: .int(3), try eval(x))
        case .tenPower(let x): return try CalcMath.pow(.int(10), try eval(x))
        case .ePower(let x):
            let v = try eval(x)
            if v.isZero { return .int(1) }
            return try CalcMath.checked(Foundation.exp(v.double))
        case .logBase(let b, let x): return try logBase(try eval(b), try eval(x))
        case .abs(let x): return absValue(try eval(x))
        case .fraction(let a, let b): return try CalcMath.div(try eval(a), try eval(b))
        case .mixed(let w, let n, let d):
            let whole = try eval(w), part = try CalcMath.div(try eval(n), try eval(d))
            return whole.double < 0 ? try CalcMath.sub(whole, part) : try CalcMath.add(whole, part)
        case .relation: throw CalcError.syntax
        }
    }

    /// TRUE/FALSE for VERIF.
    mutating func verify(_ e: CalcExpr) throws -> Bool {
        guard case .relation(let r, let a, let b) = e else { throw CalcError.syntax }
        let x = try eval(a), y = try eval(b)
        let equal: Bool
        if x.isExact && y.isExact { equal = x == y } else {
            equal = Swift.abs(x.double - y.double) <= 1e-13 * max(1, Swift.abs(x.double), Swift.abs(y.double))
        }
        switch r {
        case .eq: return equal
        case .ne: return !equal
        case .gt: return !equal && x.double > y.double
        case .lt: return !equal && x.double < y.double
        case .ge: return equal || x.double > y.double
        case .le: return equal || x.double < y.double
        }
    }

    private func absValue(_ v: CalcValue) -> CalcValue {
        v.double < 0 ? CalcMath.neg(v) : v
    }

    private func postfix(_ p: CalcPostfix, _ x: CalcValue) throws -> CalcValue {
        switch p {
        case .square: return try CalcMath.mul(x, x)
        case .cube: return try CalcMath.mul(try CalcMath.mul(x, x), x)
        case .inverse: return try CalcMath.div(.int(1), x)
        case .percent: return try CalcMath.div(x, .int(100))
        case .factorial:
            guard let n = x.integerValue, n >= 0, n <= 69 else { throw CalcError.math }
            var exact: Int64 = 1, real = 1.0, fits = true
            for k in stride(from: 2, through: n, by: 1) {
                real *= Double(k)
                if fits, let p = CalcRational(exact)?.multiplying(CalcRational(k)!), p.isInteger { exact = p.num } else { fits = false }
            }
            return fits ? .int(exact) : try CalcMath.checked(real)
        case .dms: return x
        case .degMark: return try convertAngle(x, from: .deg)
        case .radMark: return try convertAngle(x, from: .rad)
        case .gradMark: return try convertAngle(x, from: .gra)
        }
    }

    // MARK: Angles

    /// A value in `from` units, converted to the current unit.
    func convertAngle(_ x: CalcValue, from: CalcAngle) throws -> CalcValue {
        guard from != angle else { return x }
        let degrees = try toDegrees(x, unit: from)
        return try fromDegrees(degrees)
    }

    private func toDegrees(_ x: CalcValue, unit: CalcAngle) throws -> CalcValue {
        switch unit {
        case .deg: return x
        case .gra: return try CalcMath.mul(x, .rational(CalcRational(9, 10)!))
        case .rad:
            if case .pi(let c) = x, let d = c.multiplying(CalcRational(180)!) { return .rational(d) }
            return try CalcMath.checked(x.double * 180 / Double.pi)
        }
    }

    private func fromDegrees(_ d: CalcValue) throws -> CalcValue {
        switch angle {
        case .deg: return d
        case .gra: return try CalcMath.mul(d, .rational(CalcRational(10, 9)!))
        case .rad:
            if case .rational(let q) = d {
                if q.isZero { return .zero }
                if let c = q.dividing(CalcRational(180)!), c.den <= 1000 { return .pi(c) }
            }
            return try CalcMath.checked(d.double * Double.pi / 180)
        }
    }

    private func radians(_ x: CalcValue) throws -> Double {
        let limit: Double
        switch angle {
        case .deg: limit = 9e9
        case .rad: limit = 157079632.7
        case .gra: limit = 1e10
        }
        guard Swift.abs(x.double) < limit else { throw CalcError.math }
        switch angle {
        case .deg: return x.double * Double.pi / 180
        case .rad: return x.double
        case .gra: return x.double * Double.pi / 200
        }
    }

    private static let half = CalcValue.rational(CalcRational(1, 2)!)
    private static let root2Over2 = CalcValue.surd(.zero, CalcRational(1, 2)!, 2)
    private static let root3Over2 = CalcValue.surd(.zero, CalcRational(1, 2)!, 3)
    private static let root3 = CalcValue.surd(.zero, .one, 3)
    private static let root3Over3 = CalcValue.surd(.zero, CalcRational(1, 3)!, 3)

    /// sin of a whole number of degrees that is a multiple of 30 or 45, exactly.
    private static func exactSin(degrees q: CalcRational) -> CalcValue? {
        guard q.isInteger else { return nil }
        let d = ((q.num % 360) + 360) % 360
        switch d {
        case 0, 180: return .zero
        case 30, 150: return half
        case 210, 330: return CalcMath.neg(half)
        case 90: return .int(1)
        case 270: return .int(-1)
        case 45, 135: return root2Over2
        case 225, 315: return CalcMath.neg(root2Over2)
        case 60, 120: return root3Over2
        case 240, 300: return CalcMath.neg(root3Over2)
        default: return nil
        }
    }

    private func exactDegrees(_ x: CalcValue) -> CalcRational? {
        switch (angle, x) {
        case (.deg, .rational(let q)): return q
        case (.gra, .rational(let q)): return q.multiplying(CalcRational(9, 10)!)
        case (.rad, .rational(let q)) where q.isZero: return .zero
        case (.rad, .pi(let c)): return c.multiplying(CalcRational(180)!)
        default: return nil
        }
    }

    private func trig(_ f: CalcFunction, _ x: CalcValue) throws -> CalcValue {
        if let d = exactDegrees(x), let s = CalcEvaluator.exactSin(degrees: d),
           let shifted = d.adding(CalcRational(90)!), let c = CalcEvaluator.exactSin(degrees: shifted) {
            switch f {
            case .sin: return s
            case .cos: return c
            default:
                guard !c.isZero else { throw CalcError.math }
                return try CalcMath.div(s, c)
            }
        }
        let r = try radians(x)
        var v: Double
        switch f {
        case .sin: v = Foundation.sin(r)
        case .cos: v = Foundation.cos(r)
        default:
            if Swift.abs(Foundation.cos(r)) < 1e-15 { throw CalcError.math }
            v = Foundation.tan(r)
        }
        if Swift.abs(v) < 1e-13 { v = 0 }
        return try CalcMath.checked(v)
    }

    private func inverseTrig(_ f: CalcFunction, _ x: CalcValue) throws -> CalcValue {
        let v = x.double
        if f != .atan { guard Swift.abs(v) <= 1 else { throw CalcError.math } }
        // Exact angles for the special values.
        let table: [(CalcValue, Int64)]
        switch f {
        case .asin, .acos:
            table = [(.zero, 0), (CalcEvaluator.half, 30), (CalcEvaluator.root2Over2, 45), (CalcEvaluator.root3Over2, 60), (.int(1), 90)]
        default:
            table = [(.zero, 0), (CalcEvaluator.root3Over3, 30), (.int(1), 45), (CalcEvaluator.root3, 60)]
        }
        for (value, deg) in table {
            for sign in [Int64(1), -1] {
                let target = sign == 1 ? value : CalcMath.neg(value)
                guard target == x else { continue }
                var d = sign * deg
                if f == .acos { d = 90 - d }
                return try fromDegrees(.int(d))
            }
        }
        let radians: Double
        switch f {
        case .asin: radians = Foundation.asin(v)
        case .acos: radians = Foundation.acos(v)
        default: radians = Foundation.atan(v)
        }
        switch angle {
        case .deg: return try CalcMath.checked(radians * 180 / Double.pi)
        case .rad: return try CalcMath.checked(radians)
        case .gra: return try CalcMath.checked(radians * 200 / Double.pi)
        }
    }

    // MARK: Functions

    private func function(_ f: CalcFunction, _ args: [CalcValue]) throws -> CalcValue {
        let x = args[0]
        switch f {
        case .sin, .cos, .tan: return try trig(f, x)
        case .asin, .acos, .atan: return try inverseTrig(f, x)
        case .sinh, .cosh:
            guard Swift.abs(x.double) <= 230.2585092 else { throw CalcError.math }
            return try CalcMath.checked(f == .sinh ? Foundation.sinh(x.double) : Foundation.cosh(x.double))
        case .tanh: return try CalcMath.checked(Foundation.tanh(x.double))
        case .asinh: return try CalcMath.checked(Foundation.asinh(x.double))
        case .acosh:
            guard x.double >= 1 else { throw CalcError.math }
            return try CalcMath.checked(Foundation.acosh(x.double))
        case .atanh:
            guard Swift.abs(x.double) < 1 else { throw CalcError.math }
            return try CalcMath.checked(Foundation.atanh(x.double))
        case .log: return try logBase(.int(10), x)
        case .ln:
            guard x.double > 0 else { throw CalcError.math }
            if x == .int(1) { return .zero }
            return try CalcMath.checked(Foundation.log(x.double))
        case .abs: return absValue(x)
        case .rnd: return try round(x)
        case .pol, .rec: throw CalcError.syntax
        case .ranInt:
            guard let a = args[0].integerValue, let b = args[1].integerValue, a < b, b - a < 10_000_000_000 else { throw CalcError.math }
            let k = Int64((random() * Double(b - a + 1)).rounded(.down))
            return .int(a + min(k, b - a))
        case .gcd, .lcm:
            guard let a = args[0].integerValue, let b = args[1].integerValue,
                  Swift.abs(a) < 10_000_000_000, Swift.abs(b) < 10_000_000_000 else { throw CalcError.math }
            let g = CalcRational.gcd(Swift.abs(a), Swift.abs(b))
            if f == .gcd { return .int(a == 0 && b == 0 ? 0 : g) }
            guard a >= 0, b >= 0 else { throw CalcError.math }
            if a == 0 || b == 0 { return .zero }
            return try CalcMath.checked(Double(a / g) * Double(b)).exactIfInteger
        }
    }

    private func logBase(_ base: CalcValue, _ x: CalcValue) throws -> CalcValue {
        let b = base.double, v = x.double
        guard b > 0, b != 1, v > 0 else { throw CalcError.math }
        let r = Foundation.log(v) / Foundation.log(b)
        // Whole-number answers stay exact when they really are (log₂8 = 3).
        let n = r.rounded()
        if Swift.abs(r - n) < 1e-10, Swift.abs(n) <= 4096, base.isExact, x.isExact,
           let p = try? CalcMath.pow(base, .int(Int64(n))), p == x {
            return .int(Int64(n))
        }
        return try CalcMath.checked(r)
    }

    private func permutation(_ x: CalcValue, _ y: CalcValue, combinations: Bool) throws -> CalcValue {
        guard let n = x.integerValue, let r = y.integerValue, n >= 0, r >= 0, r <= n, n < 10_000_000_000 else { throw CalcError.math }
        let k = combinations ? min(r, n - r) : r
        var exact = CalcRational.one, real = 1.0, fits = true
        for j in stride(from: Int64(0), to: k, by: 1) {
            real *= Double(n - j)
            if combinations { real /= Double(j + 1) }
            guard real < 1e100 else { throw CalcError.math }
            if fits {
                if let m = exact.multiplying(CalcRational(n - j)!), let d = combinations ? m.dividing(CalcRational(j + 1)!) : m {
                    exact = d
                } else { fits = false }
            }
        }
        return fits ? .rational(exact) : try CalcMath.checked(real.rounded())
    }

    private func polar(_ x: CalcValue, _ y: CalcValue) throws -> (CalcValue, CalcValue) {
        let r = try CalcMath.sqrt(try CalcMath.add(try CalcMath.mul(x, x), try CalcMath.mul(y, y)))
        let theta: Double
        switch angle {
        case .deg: theta = Foundation.atan2(y.double, x.double) * 180 / Double.pi
        case .rad: theta = Foundation.atan2(y.double, x.double)
        case .gra: theta = Foundation.atan2(y.double, x.double) * 200 / Double.pi
        }
        return (r, try CalcMath.checked(theta))
    }

    private func rectangular(_ r: CalcValue, _ theta: CalcValue) throws -> (CalcValue, CalcValue) {
        let c = try trig(.cos, theta), s = try trig(.sin, theta)
        return (try CalcMath.mul(r, c), try CalcMath.mul(r, s))
    }

    /// Rnd: the value rounded the way it is displayed (10 significant digits in Norm).
    func round(_ x: CalcValue) throws -> CalcValue {
        let d = x.double
        guard d != 0 else { return .zero }
        let text: String
        switch format {
        case .fix(let n): text = String(format: "%.\(n)f", d)
        case .sci(let n): text = String(format: "%.\(max(0, (n == 0 ? 10 : n) - 1))e", d)
        case .norm: text = String(format: "%.9e", d)
        }
        guard let rounded = Double(text) else { throw CalcError.math }
        if case .fix = format, let q = CalcRational.decimal(text.replacingOccurrences(of: "-", with: "")) {
            return .rational(rounded < 0 ? q.negated : q)
        }
        return try CalcMath.checked(rounded).exactIfInteger
    }
}

extension CalcValue {
    /// A whole-number decimal as an exact integer.
    var exactIfInteger: CalcValue {
        if case .real(let d) = self, d == d.rounded(), Swift.abs(d) < 9e15 { return .int(Int64(d)) }
        return self
    }
}
