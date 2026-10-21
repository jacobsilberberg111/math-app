import UIKit
import PencilKit

/// What the lasso's action bar does. Each edit is one undo step, and our own edits keep the selection.
extension NoteCanvasViewController {

    func performLassoAction(_ action: LassoAction) {
        switch action {
        case .ask:
            askAboutLasso()
        case .toText:
            host?.canvasConvertLasso(.text)
        case .toMath:
            host?.canvasConvertLasso(.math)
        case .colour(let hex):
            recolourLasso(hex)
        case .customColour:
            pickCustomLassoColour()
        case .thickness(let change):
            rethickenLasso(change)
        case .copy:
            copyLasso()
            showToast(symbol: "doc.on.doc")
        case .cut:
            copyLasso()
            deleteLasso(actionName: "Cut")
            showToast(symbol: "scissors")
        case .duplicate:
            duplicateLasso()
        case .delete:
            deleteLasso(actionName: "Delete")
        }
    }

    // MARK: Ask

    /// Sends the selection's area to the tutor, exactly as dragging a region with the Ask tool does.
    private func askAboutLasso() {
        let (page, rect) = document.pageRectFromDoc(lasso.bounds)
        let clipped = rect.intersection(CGRect(origin: .zero, size: document.pageSize))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return }
        let docClipped = document.docRect(clipped, page: page)
        showRegion(docClipped)
        Haptics.tap()
        host?.canvasRegionSelected(page: page, rect: clipped, anchor: viewRect(fromDoc: docClipped))
        clearLassoSelection()
    }

    // MARK: Colour

    func recolourLasso(_ hex: String) {
        let color = UIColor(hex: hex)
        lasso.isCommitting = true
        let indices = validLassoStrokeIndices()
        if !indices.isEmpty {
            var strokes = document.drawing.strokes
            for i in indices {
                let s = strokes[i]
                strokes[i] = PKStroke(ink: PKInk(s.ink.inkType, color: color), path: s.path, transform: s.transform, mask: s.mask)
            }
            replaceLassoStrokes(strokes, actionName: "Colour")
        }
        for id in lasso.elementIDs {
            document.update(id, actionName: "Colour") { e in
                switch e.kind {
                case .text(var t):
                    t.colorHex = hex
                    e.kind = .text(t)
                case .math(var m):
                    m.colorHex = hex
                    e.kind = .math(m)
                case .ink(var i):
                    i.colorHex = hex
                    e.kind = .ink(i)
                case .table(var t):
                    t.colorHex = hex
                    e.kind = .table(t)
                default:
                    break
                }
            }
        }
        lasso.isCommitting = false
        refreshLassoSelection()
        host?.canvasUndoStateChanged()
    }

    /// The system colour picker (it has an eyedropper); the colour applies when the picker is closed.
    func pickCustomLassoColour() {
        let picker = UIColorPickerViewController()
        let start = dominantColourHex(of: lassoStrokes) ?? tool.penColorHex
        picker.supportsAlpha = false
        picker.selectedColor = UIColor(hex: start)
        picker.delegate = self
        lasso.pickerStartHex = start
        lasso.pickedColour = nil
        present(picker, animated: true)
    }

    // MARK: Thickness

    func rethickenLasso(_ change: LassoThickness) {
        lasso.isCommitting = true
        let indices = validLassoStrokeIndices()
        if !indices.isEmpty {
            var strokes = document.drawing.strokes
            for i in indices {
                let width = lassoWidth(of: strokes[i])
                let target = min(max(newWidth(from: width, change), 0.4), 60)
                strokes[i] = scaledStroke(strokes[i], by: target / max(width, 0.01))
            }
            replaceLassoStrokes(strokes, actionName: "Thickness")
        }
        for id in lasso.elementIDs {
            document.update(id, actionName: "Thickness") { e in
                guard case .ink(var ink) = e.kind else { return }
                ink.width = min(max(newWidth(from: ink.width, change), 0.4), 60)
                e.kind = .ink(ink)
            }
        }
        lasso.isCommitting = false
        refreshLassoSelection()
        host?.canvasUndoStateChanged()
    }

    private func newWidth(from width: CGFloat, _ change: LassoThickness) -> CGFloat {
        switch change {
        case .thinner: return width * 0.8
        case .thicker: return width * 1.25
        case .width(let w): return w
        }
    }

    /// How wide a stroke looks on the page: the middle point size, times the stroke's own scale.
    private func lassoWidth(of stroke: PKStroke) -> CGFloat {
        let widths = stroke.path.map { $0.size.width }.sorted()
        guard !widths.isEmpty else { return 1 }
        let t = stroke.transform
        return widths[widths.count / 2] * sqrt(abs(t.a * t.d - t.b * t.c))
    }

    /// The stroke with every point's size multiplied by `factor` (its transform is left alone).
    private func scaledStroke(_ stroke: PKStroke, by factor: CGFloat) -> PKStroke {
        let points = stroke.path.map { p in
            PKStrokePoint(location: p.location, timeOffset: p.timeOffset,
                          size: CGSize(width: p.size.width * factor, height: p.size.height * factor),
                          opacity: p.opacity, force: p.force, azimuth: p.azimuth, altitude: p.altitude)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate)
        return PKStroke(ink: stroke.ink, path: path, transform: stroke.transform, mask: stroke.mask)
    }

    // MARK: Copy, duplicate, delete

    /// The selection as a clip: ink translated so its top-left is the origin, items relative to it.
    func makeLassoClip() -> CanvasClip? {
        guard !lasso.bounds.isNull, !lasso.isEmpty else { return nil }
        let origin = lasso.bounds.origin
        let shift = CGAffineTransform(translationX: -origin.x, y: -origin.y)
        var drawing = PKDrawing()
        drawing.strokes = lassoStrokes.map { stroke -> PKStroke in
            var moved = stroke
            moved.transform = moved.transform.concatenating(shift)
            return moved
        }
        var assets: [String: Data] = [:]
        let elements = lassoElements.map { source -> CanvasElement in
            var e = source
            e.pageIndex = 0
            e.frame = document.docRect(for: source).offsetBy(dx: -origin.x, dy: -origin.y)
            if case .image(let image) = source.kind, assets[image.assetID] == nil,
               let data = try? Data(contentsOf: document.assetURL(image.assetID)) {
                assets[image.assetID] = data
            }
            return e
        }
        return CanvasClip(strokes: drawing.dataRepresentation(), elements: elements, assets: assets, size: lasso.bounds.size)
    }

    private func copyLasso() {
        guard let clip = makeLassoClip() else { return }
        let rect = lasso.bounds.insetBy(dx: -ElementView.padding, dy: -ElementView.padding)
        let scale = min(2, 2048 / max(rect.width, rect.height, 1))
        clip.copyToPasteboard(picture: renderLassoSelection(rect: rect, scale: scale))
    }

    private func duplicateLasso() {
        let offset = CGAffineTransform(translationX: 24, y: 24)
        let strokes = lassoStrokes.map { stroke -> PKStroke in
            var copy = stroke
            copy.transform = copy.transform.concatenating(offset)
            return copy
        }
        let elements = lassoElements.map { source -> CanvasElement in
            var copy = source
            copy.id = document.nextElementID()
            copy.createdAt = Date()
            let (page, local) = document.pageRectFromDoc(document.docRect(for: source).offsetBy(dx: 24, dy: 24))
            copy.pageIndex = page
            copy.frame = local
            return copy
        }
        addLassoContent(strokes: strokes, elements: elements, actionName: "Duplicate")
    }

    /// Adds ink and items as one undo step and makes them the selection.
    func addLassoContent(strokes: [PKStroke], elements: [CanvasElement], actionName: String) {
        lasso.isCommitting = true
        let first = document.drawing.strokes.count
        if !strokes.isEmpty {
            var drawing = document.drawing
            drawing.strokes.append(contentsOf: strokes)
            document.replaceDrawing(drawing, actionName: actionName)
        }
        for e in elements { document.add(e, actionName: actionName) }
        lasso.isCommitting = false
        setLassoSelection(strokes: Array(first..<(first + strokes.count)), elements: elements.map(\.id))
        host?.canvasUndoStateChanged()
    }

    private func deleteLasso(actionName: String) {
        lasso.isCommitting = true
        let drop = Set(validLassoStrokeIndices())
        if !drop.isEmpty {
            let kept = document.drawing.strokes.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
            replaceLassoStrokes(kept, actionName: actionName)
        }
        for id in lasso.elementIDs { document.remove(id, actionName: actionName) }
        lasso.isCommitting = false
        clearLassoSelection()
        host?.canvasUndoStateChanged()
    }
}

extension NoteCanvasViewController: UIColorPickerViewControllerDelegate {
    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        // The picker may report the colour it opened on; only a different one is a choice.
        lasso.pickedColour = color.hexString == lasso.pickerStartHex ? nil : color
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        guard let color = lasso.pickedColour else { return }
        lasso.pickedColour = nil
        recolourLasso(color.hexString)
    }
}
