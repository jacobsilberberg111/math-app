import Foundation

// STAT mode: single-variable statistics and the eight regression types of the fx-82AU PLUS II.

enum CalcStatType: String, Codable, CaseIterable {
    case oneVar, linear, quadratic, logarithmic, eExponential, abExponential, power, inverse

    var menuLabel: String {
        switch self {
        case .oneVar: return "1-VAR"
        case .linear: return "A+BX"
        case .quadratic: return "_+CX²"
        case .logarithmic: return "ln X"
        case .eExponential: return "e^X"
        case .abExponential: return "A•B^X"
        case .power: return "A•X^B"
        case .inverse: return "1/X"
        }
    }

    var isPaired: Bool { self != .oneVar }
}

struct CalcStatRow: Codable, Hashable {
    var x: Double
    var y: Double = 0
    var freq: Double = 1
}

struct CalcStatistics {
    let type: CalcStatType
    private let rows: [CalcStatRow]
    private let n: Double

    /// Coefficients of the fitted curve (A, B, C) and r, when paired.
    private var fit: (a: Double, b: Double, c: Double, r: Double?)?

    init(type: CalcStatType, rows: [CalcStatRow]) throws {
        self.type = type
        self.rows = rows.filter { $0.freq != 0 }
        guard rows.allSatisfy({ $0.freq >= 0 }) else { throw CalcError.math }
        n = self.rows.reduce(0) { $0 + $1.freq }
        guard n > 0 else { throw CalcError.math }
        if type.isPaired { fit = try? Self.regression(type, self.rows) }
    }

    private func sum(_ f: (CalcStatRow) -> Double) -> Double { rows.reduce(0) { $0 + $1.freq * f($1) } }

    private func mean(_ f: (CalcStatRow) -> Double) -> Double { sum(f) / n }

    /// σ (population) and s (sample) standard deviations.
    private func deviation(_ f: (CalcStatRow) -> Double, sample: Bool) throws -> Double {
        let m = mean(f)
        let ss = sum { (f($0) - m) * (f($0) - m) }
        if sample {
            guard n > 1 else { throw CalcError.math }
            return (ss / (n - 1)).squareRoot()
        }
        return (ss / n).squareRoot()
    }

    func value(_ v: CalcStatVar) throws -> Double {
        let paired = type.isPaired
        switch v {
        case .n: return n
        case .xMean: return mean { $0.x }
        case .sigmaX: return try deviation({ $0.x }, sample: false)
        case .sX: return try deviation({ $0.x }, sample: true)
        case .sumX: return sum { $0.x }
        case .sumX2: return sum { $0.x * $0.x }
        case .minX: return rows.map(\.x).min() ?? 0
        case .maxX: return rows.map(\.x).max() ?? 0
        case .q1, .med, .q3:
            guard !paired else { throw CalcError.math }
            return quartile(v)
        default: break
        }
        guard paired else { throw CalcError.math }
        switch v {
        case .yMean: return mean { $0.y }
        case .sigmaY: return try deviation({ $0.y }, sample: false)
        case .sY: return try deviation({ $0.y }, sample: true)
        case .sumY: return sum { $0.y }
        case .sumY2: return sum { $0.y * $0.y }
        case .sumXY: return sum { $0.x * $0.y }
        case .sumX3: return sum { $0.x * $0.x * $0.x }
        case .sumX2Y: return sum { $0.x * $0.x * $0.y }
        case .sumX4: return sum { $0.x * $0.x * $0.x * $0.x }
        case .minY: return rows.map(\.y).min() ?? 0
        case .maxY: return rows.map(\.y).max() ?? 0
        case .regA, .regB, .regC, .regR:
            guard let fit else { throw CalcError.math }
            switch v {
            case .regA: return fit.a
            case .regB: return fit.b
            case .regC:
                guard type == .quadratic else { throw CalcError.math }
                return fit.c
            default:
                guard let r = fit.r else { throw CalcError.math }
                return r
            }
        default: throw CalcError.math
        }
    }

    /// x̂, ŷ, x̂₁, x̂₂ for the value typed before them.
    func estimate(_ v: CalcStatVar, x input: Double) throws -> Double {
        guard type.isPaired, let fit else { throw CalcError.math }
        let (a, b, c) = (fit.a, fit.b, fit.c)
        let result: Double
        switch v {
        case .yHat:
            let x = input
            switch type {
            case .linear: result = a + b * x
            case .quadratic: result = a + b * x + c * x * x
            case .logarithmic:
                guard x > 0 else { throw CalcError.math }
                result = a + b * Foundation.log(x)
            case .eExponential: result = a * Foundation.exp(b * x)
            case .abExponential: result = a * Foundation.pow(b, x)
            case .power: result = a * Foundation.pow(x, b)
            case .inverse:
                guard x != 0 else { throw CalcError.math }
                result = a + b / x
            case .oneVar: throw CalcError.math
            }
        case .xHat:
            let y = input
            switch type {
            case .linear:
                guard b != 0 else { throw CalcError.math }
                result = (y - a) / b
            case .logarithmic:
                guard b != 0 else { throw CalcError.math }
                result = Foundation.exp((y - a) / b)
            case .eExponential:
                guard a != 0, b != 0, y / a > 0 else { throw CalcError.math }
                result = Foundation.log(y / a) / b
            case .abExponential:
                guard a != 0, b > 0, b != 1, y / a > 0 else { throw CalcError.math }
                result = Foundation.log(y / a) / Foundation.log(b)
            case .power:
                guard a != 0, b != 0, y / a > 0 else { throw CalcError.math }
                result = Foundation.pow(y / a, 1 / b)
            case .inverse:
                guard y != a else { throw CalcError.math }
                result = b / (y - a)
            default: throw CalcError.math
            }
        case .xHat1, .xHat2:
            guard type == .quadratic, c != 0 else { throw CalcError.math }
            let disc = b * b - 4 * c * (a - input)
            guard disc >= 0 else { throw CalcError.math }
            let root = disc.squareRoot()
            result = (v == .xHat1 ? -b + root : -b - root) / (2 * c)
        default:
            throw CalcError.math
        }
        guard result.isFinite else { throw CalcError.math }
        return result
    }

    // MARK: Quartiles

    /// Medians of the lower and upper halves (the middle value is left out of both when the count
    /// is odd), as the fx-82 does. Non-whole frequencies use cumulative frequency instead.
    private func quartile(_ v: CalcStatVar) -> Double {
        let sorted = rows.sorted { $0.x < $1.x }
        if sorted.allSatisfy({ $0.freq == $0.freq.rounded() }) && n <= 100_000 {
            var list: [Double] = []
            for r in sorted { list += Array(repeating: r.x, count: Int(r.freq)) }
            func median(_ a: ArraySlice<Double>) -> Double {
                guard !a.isEmpty else { return 0 }
                let m = a.startIndex + a.count / 2
                return a.count % 2 == 1 ? a[m] : (a[m - 1] + a[m]) / 2
            }
            let all = list[...]
            if v == .med { return median(all) }
            if list.count == 1 { return list[0] }
            let half = list.count / 2
            let lower = list[0..<half]
            let upper = list[(list.count - half)...]
            return v == .q1 ? median(lower) : median(upper)
        }
        let p: Double = v == .q1 ? 0.25 : (v == .med ? 0.5 : 0.75)
        let target = n * p
        var cumulative = 0.0
        for (k, r) in sorted.enumerated() {
            cumulative += r.freq
            if Swift.abs(cumulative - target) < 1e-12, k + 1 < sorted.count { return (r.x + sorted[k + 1].x) / 2 }
            if cumulative > target { return r.x }
        }
        return sorted.last?.x ?? 0
    }

    // MARK: Regression

    private static func regression(_ type: CalcStatType, _ rows: [CalcStatRow]) throws -> (a: Double, b: Double, c: Double, r: Double?) {
        if type == .quadratic { return try quadratic(rows) }
        // Fit v = a + b·u on transformed data.
        var pts: [(u: Double, v: Double, f: Double)] = []
        for r in rows {
            var u = r.x, v = r.y
            switch type {
            case .logarithmic:
                guard u > 0 else { throw CalcError.math }
                u = Foundation.log(u)
            case .eExponential, .abExponential:
                guard v > 0 else { throw CalcError.math }
                v = Foundation.log(v)
            case .power:
                guard u > 0, v > 0 else { throw CalcError.math }
                u = Foundation.log(u); v = Foundation.log(v)
            case .inverse:
                guard u != 0 else { throw CalcError.math }
                u = 1 / u
            default: break
            }
            pts.append((u, v, r.freq))
        }
        let n = pts.reduce(0) { $0 + $1.f }
        let mu = pts.reduce(0) { $0 + $1.f * $1.u } / n
        let mv = pts.reduce(0) { $0 + $1.f * $1.v } / n
        let suu = pts.reduce(0) { $0 + $1.f * ($1.u - mu) * ($1.u - mu) }
        let svv = pts.reduce(0) { $0 + $1.f * ($1.v - mv) * ($1.v - mv) }
        let suv = pts.reduce(0) { $0 + $1.f * ($1.u - mu) * ($1.v - mv) }
        guard suu > 0 else { throw CalcError.math }
        let b = suv / suu, a = mv - b * mu
        let r: Double? = svv > 0 ? suv / (suu * svv).squareRoot() : nil
        switch type {
        case .eExponential: return (Foundation.exp(a), b, 0, r)
        case .abExponential: return (Foundation.exp(a), Foundation.exp(b), 0, r)
        case .power: return (Foundation.exp(a), b, 0, r)
        default: return (a, b, 0, r)
        }
    }

    /// Least squares for y = A + Bx + Cx², solving the 3×3 normal equations.
    private static func quadratic(_ rows: [CalcStatRow]) throws -> (a: Double, b: Double, c: Double, r: Double?) {
        func s(_ f: (CalcStatRow) -> Double) -> Double { rows.reduce(0) { $0 + $1.freq * f($1) } }
        let n = s { _ in 1 }, sx = s { $0.x }, sx2 = s { $0.x * $0.x }, sx3 = s { pow($0.x, 3) }, sx4 = s { pow($0.x, 4) }
        let sy = s { $0.y }, sxy = s { $0.x * $0.y }, sx2y = s { $0.x * $0.x * $0.y }
        var m: [[Double]] = [[n, sx, sx2, sy], [sx, sx2, sx3, sxy], [sx2, sx3, sx4, sx2y]]
        for col in 0..<3 {
            guard let pivot = (col..<3).max(by: { Swift.abs(m[$0][col]) < Swift.abs(m[$1][col]) }),
                  Swift.abs(m[pivot][col]) > 1e-300 else { throw CalcError.math }
            m.swapAt(col, pivot)
            for row in 0..<3 where row != col {
                let k = m[row][col] / m[col][col]
                for j in col..<4 { m[row][j] -= k * m[col][j] }
            }
        }
        return (m[0][3] / m[0][0], m[1][3] / m[1][1], m[2][3] / m[2][2], nil)
    }
}
