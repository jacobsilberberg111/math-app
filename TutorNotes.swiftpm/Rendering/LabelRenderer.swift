import UIKit

/// Draws LabelSetContent: covers over printed labels, leader lines with a dot on each part, and
/// the labels themselves, or numbered blanks to write on in quiz mode.
@MainActor
enum LabelRenderer {
    static let quizBoxSize = CGSize(width: 156, height: 28)
    static let titleHeight: CGFloat = 26

    static func font(_ l: LabelSetContent) -> UIFont { NoteFonts.sans(size: l.fontSize, weight: .medium) }

    /// The box a label needs (a numbered blank in quiz mode).
    static func boxSize(text: String, number: Int, quiz: Bool, font: UIFont) -> CGSize {
        if quiz { return quizBoxSize }
        let tl = ElementRenderer.richLayout("\(number). " + text, font: font, width: 190, rich: true)
        return CGSize(width: tl.size.width + 10, height: max(24, tl.size.height + 6))
    }

    static func draw(_ l: LabelSetContent, rect: CGRect, progress: CGFloat, env: RenderEnvironment, ctx: CGContext) {
        // The set may have been resized; boxes keep their size while anchors scale (see ElementResizer).
        let ink = UIColor(hex: l.colorHex)
        for c in l.covers {
            let r = c.offsetBy(dx: rect.minX, dy: rect.minY)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.addPath(UIBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), cornerRadius: 3).cgPath)
            ctx.fillPath()
        }
        if let title = l.title, !title.isEmpty {
            let tl = ElementRenderer.richLayout(title, font: NoteFonts.sans(size: 16, weight: .semibold), width: rect.width, rich: true)
            tl.draw(in: ctx, origin: CGPoint(x: rect.minX + 2, y: rect.minY + 2), color: ink)
        }
        let font = font(l)
        let visible = progress >= 1 ? l.labels.count : Int((CGFloat(l.labels.count) * progress).rounded(.up))
        for (i, label) in l.labels.enumerated() where i < visible {
            let box = label.box.offsetBy(dx: rect.minX, dy: rect.minY)
            let anchor = CGPoint(x: label.anchor.x + rect.minX, y: label.anchor.y + rect.minY)
            // Leader line and the dot on the part.
            let start = LabelLayout.leaderStart(box: box, anchor: anchor)
            ctx.setStrokeColor(ink.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1.3)
            ctx.move(to: start)
            ctx.addLine(to: anchor)
            ctx.strokePath()
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: anchor.x - 4, y: anchor.y - 4, width: 8, height: 8))
            ctx.setFillColor(ink.cgColor)
            ctx.fillEllipse(in: CGRect(x: anchor.x - 2.8, y: anchor.y - 2.8, width: 5.6, height: 5.6))

            if l.quiz && !label.revealed {
                // "3. ________": a number and a line to write on.
                let num = ElementRenderer.richLayout("\(label.number).", font: NoteFonts.sans(size: l.fontSize, weight: .bold), width: 40, rich: false)
                num.draw(in: ctx, origin: CGPoint(x: box.minX + 2, y: box.maxY - num.size.height - 3), color: ink)
                ctx.setStrokeColor(ink.withAlphaComponent(0.55).cgColor)
                ctx.setLineWidth(1.1)
                ctx.move(to: CGPoint(x: box.minX + num.size.width + 8, y: box.maxY - 3))
                ctx.addLine(to: CGPoint(x: box.maxX, y: box.maxY - 3))
                ctx.strokePath()
            } else {
                let tl = ElementRenderer.richLayout("\(label.number). " + label.text, font: font, width: 190, rich: true)
                ctx.setFillColor(UIColor.white.withAlphaComponent(0.85).cgColor)
                ctx.addPath(UIBezierPath(roundedRect: box, cornerRadius: 5).cgPath)
                ctx.fillPath()
                let color = l.quiz ? UIColor(hex: "#1A7F37") : ink
                tl.draw(in: ctx, origin: CGPoint(x: box.minX + 5, y: box.midY - tl.size.height / 2), color: color)
            }
        }
    }

    static func tutorDescription(_ l: LabelSetContent, frame: CGRect) -> String {
        var s = l.quiz ? "labelling quiz, \(l.labels.count) numbered blanks" : "\(l.labels.count) labels"
        if let t = l.targetElementID { s += " on \(t)" }
        if let title = l.title { s += ", \"\(title.truncated(50))\"" }
        let items = l.labels.map { lb -> String in
            let box = lb.box.offsetBy(dx: frame.minX, dy: frame.minY)
            let a = CGPoint(x: lb.anchor.x + frame.minX, y: lb.anchor.y + frame.minY)
            let shown = l.quiz && !lb.revealed ? "hidden answer \"\(lb.text)\" (blank \(box.roundedForDisplay))" : "\"\(lb.text)\" \(box.roundedForDisplay)"
            return "\(lb.number): \(shown) → point (\(Int(a.x)), \(Int(a.y)))"
        }
        return s + ": " + items.joined(separator: "; ")
    }
}
