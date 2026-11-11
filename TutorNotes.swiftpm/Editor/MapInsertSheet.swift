import SwiftUI

/// Insert → Map: the student picks a region and a data layer. STUB: replaced by the geo feature.
struct MapInsertSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Text("Maps are coming soon.")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
