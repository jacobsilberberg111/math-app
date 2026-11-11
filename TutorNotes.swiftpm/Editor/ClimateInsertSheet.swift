import SwiftUI

/// Insert → Climate Graph: the student types a place. STUB: replaced by the geo feature.
struct ClimateInsertSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Text("Climate graphs are coming soon.")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
