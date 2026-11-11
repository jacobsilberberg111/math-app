import Foundation

/// A data chart on the page: bar, horizontal bar, line, scatter, pie or climate graph (owned by
/// the geography feature, also used by science). Rendered by ChartRenderer.
///
/// Every field is optional so saved notes keep decoding as fields are added. Inline values are
/// for the student's own or textbook data; real-world statistics are fetched by the app.
struct ChartContent: Codable, Equatable {
    var title: String?
    var source: String?
    /// ChartKind raw value.
    var kind: String?
    /// Category labels (bars, line or pie slices, months on a climate graph).
    var categories: [String]?
    var series: [ChartSeries]?
    var xLabel: String?
    var yLabel: String?
    /// Right-hand axis title (climate graphs: rainfall).
    var y2Label: String?
    /// Scatter: draw the least-squares line of best fit.
    var bestFit: Bool?
    var yMin: Double?
    var yMax: Double?
    var showValues: Bool?
    /// A line under the title, e.g. "Dubbo, NSW · 32.2°S 148.6°E · 264 m".
    var subtitle: String?
    /// A line above the source, e.g. "Annual rainfall 590 mm · Temperature range 15.6 °C".
    var note: String?

    var chartKind: ChartKind { ChartKind(rawValue: kind ?? "") ?? .bar }
    var allSeries: [ChartSeries] { series ?? [] }
}

enum ChartKind: String, CaseIterable {
    case bar
    case horizontalBar = "horizontal_bar"
    case line
    case scatter
    case pie
    case climate

    var displayName: String {
        switch self {
        case .bar: return "Column chart"
        case .horizontalBar: return "Bar chart"
        case .line: return "Line graph"
        case .scatter: return "Scatter plot"
        case .pie: return "Pie chart"
        case .climate: return "Climate graph"
        }
    }
}

struct ChartSeries: Codable, Equatable {
    var name: String
    /// One value per category (nil = missing).
    var values: [Double?]?
    /// [x, y] pairs for scatter plots and lines with a numeric x axis.
    var points: [[Double]]?
    var colorHex: String?
    /// "right" to use the right-hand axis.
    var axis: String?
    /// "bar", "line" or "dashed" (climate graphs mix bars and lines).
    var style: String?

    var onRight: Bool { axis == "right" }
    var xyPoints: [(x: Double, y: Double)] {
        (points ?? []).compactMap { $0.count >= 2 && $0[0].isFinite && $0[1].isFinite ? ($0[0], $0[1]) : nil }
    }
}

/// Axis ranges and ticks.
struct ChartScale: Equatable {
    var lo: Double
    var hi: Double
    var step: Double

    var ticks: [Double] {
        guard step > 0, hi > lo else { return [lo] }
        var out: [Double] = []
        var v = lo
        var n = 0
        while v <= hi + step * 1e-6 && n < 200 {
            out.append(abs(v) < step * 1e-9 ? 0 : v)
            n += 1
            v = lo + Double(n) * step
        }
        return out
    }

    func fraction(_ v: Double) -> Double { hi > lo ? (v - lo) / (hi - lo) : 0 }

    /// A 1-2-2.5-5 step giving at most `maxTicks` intervals; includes zero when `includeZero`.
    static func nice(min a: Double, max b: Double, maxTicks: Int = 6, includeZero: Bool = false) -> ChartScale {
        var lo = Swift.min(a, b), hi = Swift.max(a, b)
        if includeZero { lo = Swift.min(lo, 0); hi = Swift.max(hi, 0) }
        if !lo.isFinite || !hi.isFinite { return ChartScale(lo: 0, hi: 1, step: 0.2) }
        if hi - lo < 1e-12 {
            let pad = abs(hi) > 0 ? abs(hi) * 0.1 : 1
            lo -= pad; hi += pad
            if includeZero && a >= 0 { lo = Swift.max(lo, 0) }
        }
        let raw = (hi - lo) / Double(Swift.max(1, maxTicks))
        let mag = pow(10, floor(log10(raw)))
        var step = mag
        for f in [1.0, 2.0, 2.5, 5.0, 10.0] {
            step = f * mag
            if (ceil(hi / step - 1e-9) - floor(lo / step + 1e-9)) <= Double(maxTicks) { break }
        }
        return ChartScale(lo: floor(lo / step + 1e-9) * step, hi: ceil(hi / step - 1e-9) * step, step: step)
    }

    /// Climate graph axes: temperature on the left, rainfall on the right, with the same number of
    /// intervals and zero on the same line, so gridlines serve both (rainfall ticks below zero
    /// are not labelled).
    static func climateAxes(tempMin: Double, tempMax: Double, rainMax: Double, maxTicks: Int) -> (temp: ChartScale, rain: ChartScale) {
        let t = nice(min: Swift.min(0, tempMin), max: Swift.max(tempMax, 10), maxTicks: maxTicks, includeZero: true)
        let k = Swift.max(1, Int(((t.hi - t.lo) / t.step).rounded()))
        let neg = Int((-t.lo / t.step).rounded())
        let raw = Swift.max(10, rainMax) / Double(Swift.max(1, k - neg))
        let mag = pow(10, floor(log10(raw)))
        let step = [1.0, 2, 2.5, 5, 10].map { $0 * mag }.first { $0 >= raw - 1e-9 } ?? 10 * mag
        return (t, ChartScale(lo: -Double(neg) * step, hi: Double(k - neg) * step, step: step))
    }

    static func label(_ v: Double, step: Double) -> String {
        if abs(v) >= 1e6 && step >= 1e5 { return GeoFormat.short(v) }
        let d = (0...4).first { d in
            let s = step * pow(10, Double(d))
            return abs(s - s.rounded()) < 1e-6 * Swift.max(1, s)
        } ?? 4
        if d == 0 && abs(v) >= 1000 { return GeoFormat.grouped(v) }
        let s = String(format: "%.\(d)f", v)
        return s.hasPrefix("-") && Double(s) == 0 ? String(s.dropFirst()) : s
    }
}

/// Least-squares line through scatter points.
struct ChartFit: Equatable {
    var slope: Double
    var intercept: Double
    /// Pearson correlation coefficient.
    var r: Double

    static func leastSquares(_ pts: [(x: Double, y: Double)]) -> ChartFit? {
        guard pts.count >= 2 else { return nil }
        let n = Double(pts.count)
        let mx = pts.map(\.x).reduce(0, +) / n, my = pts.map(\.y).reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in pts {
            sxx += (p.x - mx) * (p.x - mx)
            sxy += (p.x - mx) * (p.y - my)
            syy += (p.y - my) * (p.y - my)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        let r = syy > 0 ? sxy / sqrt(sxx * syy) : 1
        return ChartFit(slope: slope, intercept: my - slope * mx, r: r)
    }

    var equation: String {
        let m = GeoFormat.trim(slope, abs(slope) >= 10 ? 1 : 3), c = GeoFormat.trim(abs(intercept), abs(intercept) >= 10 ? 1 : 3)
        return "y = \(m)x \(intercept < 0 ? "−" : "+") \(c)"
    }
}

/// Pie slices: start/end angles (radians, clockwise from 12 o'clock) and percentages.
enum ChartPie {
    static func slices(_ values: [Double]) -> [(start: Double, end: Double, percent: Double)] {
        let v = values.map { $0.isFinite ? Swift.max(0, $0) : 0 }
        let total = v.reduce(0, +)
        guard total > 0 else { return [] }
        var a = 0.0
        return v.map { x in
            let sweep = x / total * 2 * .pi
            defer { a += sweep }
            return (a, a + sweep, x / total * 100)
        }
    }
}

enum ChartPalette {
    static let series = ["#1C64F2", "#E8590C", "#2F9E44", "#7048E8", "#D6336C", "#0C8599", "#F59F00", "#5C7CFA"]
    static let rain = "#3B82C4"
    static let temp = "#E03131"

    static func color(_ i: Int) -> String { series[((i % series.count) + series.count) % series.count] }
}

/// What the tutor is told about a chart: values per series, so it can discuss the data.
enum ChartSummary {
    static func text(_ c: ChartContent) -> String {
        var parts: [String] = []
        let cats = c.categories ?? []
        for s in c.allSeries {
            if let vals = s.values, !vals.isEmpty {
                let items = vals.enumerated().map { i, v in "\(i < cats.count ? cats[i] : "#\(i + 1)") \(v.map { GeoFormat.value($0) } ?? "–")" }
                parts.append("\(s.name): " + items.prefix(40).joined(separator: ", ") + (items.count > 40 ? ", …" : ""))
            } else {
                let pts = s.xyPoints
                if !pts.isEmpty {
                    parts.append("\(s.name): \(pts.count) points" + (pts.count <= 20 ? " " + pts.map { "(\(GeoFormat.value($0.x)), \(GeoFormat.value($0.y)))" }.joined(separator: " ") : ""))
                }
            }
        }
        if c.chartKind == .scatter && c.bestFit == true, let s = c.allSeries.first, let fit = ChartFit.leastSquares(s.xyPoints) {
            parts.append("Line of best fit \(fit.equation), r = \(GeoFormat.trim(fit.r, 2))")
        }
        return parts.joined(separator: "; ")
    }
}
