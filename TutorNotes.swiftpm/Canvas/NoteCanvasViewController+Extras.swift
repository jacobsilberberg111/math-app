import UIKit
import ObjectiveC

/// State for the input refinements (shape commits, eraser swipes, text editing) kept off the main
/// controller file. One object per canvas controller.
final class CanvasInputExtras {
    /// After a snapped shape is committed: strokes PencilKit adds before `until` that were
    /// started before `date` are leftovers of the cancelled raw stroke.
    var lateStrokeGuard: (count: Int, date: Date, until: Date)?

    /// The current eraser swipe: tutor items hidden so far (removed together at the end) and how
    /// far the eraser has rubbed inside each typed tutor item.
    var erasing = false
    var erasedIDs: [String] = []
    var rubDistance: [String: CGFloat] = [:]
    var lastErasePoint: CGPoint?

    /// The keyboard's height over the canvas while a text box is being edited.
    var keyboardInset: CGFloat = 0
    var keyboardObservers: [NSObjectProtocol] = []
}

private var extrasKey: UInt8 = 0

extension NoteCanvasViewController {
    var extras: CanvasInputExtras {
        if let e = objc_getAssociatedObject(self, &extrasKey) as? CanvasInputExtras { return e }
        let e = CanvasInputExtras()
        objc_setAssociatedObject(self, &extrasKey, e, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return e
    }

    var lateStrokeGuard: (count: Int, date: Date, until: Date)? {
        get { extras.lateStrokeGuard }
        set { extras.lateStrokeGuard = newValue }
    }
}

// MARK: - Keyboard shortcuts (a hardware keyboard: Magic Keyboard, Smart Keyboard)

extension NoteCanvasViewController {
    override var canBecomeFirstResponder: Bool { true }

    /// ⌘C ⌘X ⌘D and Delete act on the lasso selection; ⌘V pastes into the middle of the screen.
    /// None of them while a text box is being typed in (the text box has its own).
    override var keyCommands: [UIKeyCommand]? {
        guard editingTextView == nil else { return super.keyCommands }
        var commands = [UIKeyCommand(title: "Paste", action: #selector(keyPaste), input: "v", modifierFlags: .command)]
        if !lasso.isEmpty {
            commands += [
                UIKeyCommand(title: "Copy", action: #selector(keyCopy), input: "c", modifierFlags: .command),
                UIKeyCommand(title: "Cut", action: #selector(keyCut), input: "x", modifierFlags: .command),
                UIKeyCommand(title: "Duplicate", action: #selector(keyDuplicate), input: "d", modifierFlags: .command),
                UIKeyCommand(title: "Delete", action: #selector(keyDelete), input: UIKeyCommand.inputDelete, modifierFlags: []),
                UIKeyCommand(title: "Delete", action: #selector(keyDelete), input: "\u{8}", modifierFlags: []),
                UIKeyCommand(title: "Deselect", action: #selector(keyDeselect), input: UIKeyCommand.inputEscape, modifierFlags: []),
            ]
        }
        for c in commands { c.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + commands
    }

    @objc private func keyCopy() { performLassoAction(.copy) }
    @objc private func keyCut() { performLassoAction(.cut) }
    @objc private func keyDuplicate() { performLassoAction(.duplicate) }
    @objc private func keyDelete() { performLassoAction(.delete) }
    @objc private func keyDeselect() { clearLassoSelection() }
    @objc private func keyPaste() { pasteFromClipboard(at: nil) }

    /// Takes keyboard focus (for the shortcuts) unless something else is being typed in.
    func takeKeyFocus() {
        guard editingTextView == nil, !isFirstResponder, view.window != nil else { return }
        becomeFirstResponder()
    }
}
