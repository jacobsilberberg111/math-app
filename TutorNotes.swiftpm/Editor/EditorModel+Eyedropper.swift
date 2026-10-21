import SwiftUI

extension EditorModel {
    /// The palette's Eyedropper button: closes the palette and lets the next tap on the page set the
    /// colour of the slot being edited.
    func startEyedropper() {
        guard let canvas else { return }
        palettePresented = false
        flash("Tap the page to pick a colour")
        // The slot whose palette was open, even if another colour is tapped while sampling.
        let kind = tools.kind, slot = tools.colorIndex
        canvas.beginEyedropper { [weak self] hex in
            guard let self, let hex, self.tools.kind == kind else { return }
            self.tools.setColor(hex, at: slot)
            Haptics.success()
            self.flash("Picked colour")
        }
    }
}
