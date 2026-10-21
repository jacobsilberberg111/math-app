import UIKit

/// A pending one-shot colour sample: the tool it began under, the banner on screen, and who gets the result.
struct EyedropperSession {
    let kind: CanvasToolKind
    let banner: UIView
    let done: (String?) -> Void
}

/// One-shot colour sampling: while it's armed the next tap or Pencil touch reads the colour of the
/// page under it instead of drawing, then everything goes back to how it was.
extension NoteCanvasViewController {

    // MARK: Session

    /// Arms the eyedropper. `done` gets the sampled "#RRGGBB", or nil if sampling was cancelled
    /// (the tool changed, the banner's close button, or the note closed).
    func beginEyedropper(_ done: @escaping (String?) -> Void) {
        cancelEyedropper()
        endTextEditing()
        let banner = makeEyedropperBanner()
        view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])
        banner.alpha = 0
        UIView.animate(withDuration: 0.2) { banner.alpha = 1 }
        eyedropper = EyedropperSession(kind: tool.kind, banner: banner, done: done)
        suspendInputForEyedropper()
    }

    func cancelEyedropper() {
        endEyedropper(with: nil)
    }

    /// Samples the page at a document point (the tap's location), then ends the session.
    func finishEyedropper(at docPoint: CGPoint) {
        let hex = sampleColor(at: docPoint)
        showSampleRing(at: docPoint, hex: hex)
        endEyedropper(with: hex)
    }

    /// Called at the end of `apply(tool:)`: another tool ends sampling; a new colour or width of the
    /// same tool must not hand drawing back to PencilKit.
    func eyedropperToolApplied() {
        guard let session = eyedropper else { return }
        if tool.kind == session.kind { suspendInputForEyedropper() } else { cancelEyedropper() }
    }

    private func endEyedropper(with hex: String?) {
        guard let session = eyedropper else { return }
        eyedropper = nil
        let banner = session.banner
        UIView.animate(withDuration: 0.15, animations: { banner.alpha = 0 }) { _ in banner.removeFromSuperview() }
        longPress.isEnabled = true
        apply(tool: tool)
        session.done(hex)
    }

    /// Keeps PencilKit, the Ask Tutor region drag and the shape observer out of the way.
    private func suspendInputForEyedropper() {
        canvasView.drawingGestureRecognizer.isEnabled = false
        regionPan?.isEnabled = false
        strokeObserver?.isEnabled = false
        longPress.isEnabled = false
        hoverPreview.hide()
    }

    @objc func cancelEyedropperTapped() {
        cancelEyedropper()
    }

    // MARK: Chrome

    private func makeEyedropperBanner() -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "eyedropper"))
        icon.tintColor = .secondaryLabel
        let label = UILabel()
        label.text = "Tap to pick a colour"
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .label
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        close.tintColor = .secondaryLabel
        close.accessibilityLabel = "Cancel"
        close.addTarget(self, action: #selector(cancelEyedropperTapped), for: .touchUpInside)
        close.widthAnchor.constraint(equalToConstant: 30).isActive = true
        close.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let stack = UIStackView(arrangedSubviews: [icon, label, close])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let banner = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.layer.cornerRadius = 19
        banner.layer.cornerCurve = .continuous
        banner.clipsToBounds = true
        banner.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: banner.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: banner.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: banner.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: banner.contentView.trailingAnchor),
        ])
        return banner
    }

    /// A dot in the picked colour that blooms and fades where the page was sampled.
    private func showSampleRing(at docPoint: CGPoint, hex: String) {
        let z = max(zoom, 0.01)
        let d = 40 / z
        let ring = UIView(frame: CGRect(x: docPoint.x - d / 2, y: docPoint.y - d / 2, width: d, height: d))
        ring.isUserInteractionEnabled = false
        ring.backgroundColor = UIColor(hex: hex)
        ring.layer.cornerRadius = d / 2
        ring.layer.borderWidth = 3 / z
        ring.layer.borderColor = UIColor.white.cgColor
        ring.layer.shadowColor = UIColor.black.cgColor
        ring.layer.shadowOpacity = 0.25
        ring.layer.shadowRadius = 4 / z
        ring.layer.shadowOffset = .zero
        chrome.addSubview(ring)
        UIView.animate(withDuration: 0.45, delay: 0.2, options: [], animations: {
            ring.alpha = 0
            ring.transform = CGAffineTransform(scaleX: 1.5, y: 1.5)
        }) { _ in ring.removeFromSuperview() }
    }

    // MARK: Sampling

    /// The dominant colour of the page around a document point, as "#RRGGBB"; the paper's own
    /// colour when there's only paper there.
    func sampleColor(at docPoint: CGPoint) -> String {
        let (index, p) = document.pagePoint(fromDoc: docPoint)
        guard document.content.pages.indices.contains(index) else { return tool.inkColorHex }
        let page = document.content.pages[index]
        // A PDF page is drawn on white whatever the paper colour says.
        let paperHex = page.pdfAssetID == nil ? page.paper.color.hex : "#FFFFFF"
        let darkPaper = page.pdfAssetID == nil && page.paper.color.isDark

        // The same size on screen at any zoom: about a fingertip.
        let side = max(6, min(60, ColorSampler.side / max(zoom, 0.01)))
        let region = CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)
        let doc = document
        let env = PageRenderer.environment(for: doc)
        let format = UIGraphicsImageRendererFormat()
        format.scale = ColorSampler.scale * ColorSampler.side / side
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: region.size, format: format).image { rc in
            let ctx = rc.cgContext
            ctx.translateBy(x: -region.minX, y: -region.minY)
            // Beyond the page's edge there's nothing to draw, so start from the paper colour.
            ctx.setFillColor(UIColor(hex: paperHex).cgColor)
            ctx.fill(region)
            ctx.clip(to: region)
            // No ruling: lines and grids aren't what anyone is trying to pick.
            PageRenderer.drawPage(doc, page: index, ctx: ctx, inkScale: format.scale, env: env, patternAlpha: 0, region: region)
        }
        guard let cg = image.cgImage, let rgba = rgbaBytes(of: cg),
              let picked = ColorSampler.dominantColor(rgba: rgba, width: cg.width, height: cg.height,
                                                      paper: ColorSampler.rgb(hex: paperHex), darkPaper: darkPaper) else { return paperHex }
        return ColorSampler.hex(picked)
    }

    /// The image's pixels as 8-bit RGBA, top row first.
    private func rgbaBytes(of image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? bytes : nil
    }
}

/// Picks the colour a tap on the page most likely meant from a small bitmap centred on it.
/// Platform-independent: it only looks at pixel bytes.
enum ColorSampler {
    typealias RGB = (r: Int, g: Int, b: Int)

    /// Side of the sampled square in points, and the bitmap's pixels per point.
    static let side: CGFloat = 24
    static let scale: CGFloat = 2

    /// Pixels this far (squared RGB distance) from the paper count as ink; the second, looser limit
    /// is for faint ink such as pale highlighter, used only when nothing passes the first.
    private static let inkDistance = 40 * 40
    private static let faintDistance = 12 * 12

    private struct Bucket {
        var key = 0
        var count = 0
        var r = 0, g = 0, b = 0
        /// Squared distance (in half pixels) from the closest of its pixels to the centre.
        var nearest = Int.max
    }

    /// The dominant non-paper colour in 8-bit RGBA `rgba` (top row first), whose centre is the tap;
    /// nil when it's all paper. Ignores the paper colour, near-white (on light paper) and faint
    /// anti-aliased edges. Pixels are bucketed by quantised RGB; the biggest bucket's average wins,
    /// and among buckets about as big (within 10%) the one nearest the tap.
    static func dominantColor(rgba: [UInt8], width: Int, height: Int, paper: RGB, darkPaper: Bool) -> RGB? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        for limit in [inkDistance, faintDistance] {
            var buckets: [Int: Bucket] = [:]
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    guard rgba[i + 3] > 200 else { continue }
                    let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
                    let dr = r - paper.r, dg = g - paper.g, db = b - paper.b
                    guard dr * dr + dg * dg + db * db >= limit else { continue }
                    if !darkPaper && r > 240 && g > 240 && b > 240 { continue }
                    let key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
                    let ox = 2 * x + 1 - width, oy = 2 * y + 1 - height
                    var bucket = buckets[key] ?? Bucket(key: key)
                    bucket.count += 1
                    bucket.r += r
                    bucket.g += g
                    bucket.b += b
                    bucket.nearest = min(bucket.nearest, ox * ox + oy * oy)
                    buckets[key] = bucket
                }
            }
            guard let top = buckets.values.map(\.count).max() else { continue }
            let contenders = buckets.values.filter { $0.count * 10 >= top * 9 }
            if let best = contenders.min(by: { ($0.nearest, -$0.count, $0.key) < ($1.nearest, -$1.count, $1.key) }) {
                let n = best.count
                return ((best.r + n / 2) / n, (best.g + n / 2) / n, (best.b + n / 2) / n)
            }
        }
        return nil
    }

    static func rgb(hex: String) -> RGB {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = Int(digits.prefix(6), radix: 16) ?? 0
        return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    }

    static func hex(_ c: RGB) -> String {
        String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }
}
