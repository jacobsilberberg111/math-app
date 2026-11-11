import SwiftUI

/// Editing a code block: a code editor, program input, Run and the output. STUB: replaced by the
/// code feature.
struct CodeEditorSheet: View {
    @Bindable var model: EditorModel
    let elementID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Text("The code editor is coming soon.")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}
