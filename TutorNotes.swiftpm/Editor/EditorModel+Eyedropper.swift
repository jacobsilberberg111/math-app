import SwiftUI

extension EditorModel {
    /// The palette's Eyedropper button: closes the palette and lets the next tap on the page set the
    /// colour of the slot being edited.
    func startEyedropper() {
        guard let canvas else { return }
        palettePresented = false
        flash("Tap the page to pick a colour")
        canvas.beginEyedropper { [weak self] hex in
            guard let self, let hex else { return }
            self.tools.setColor(hex, at: self.tools.colorIndex)
            Haptics.success()
            self.flash("Picked colour")
        }
    }
}
