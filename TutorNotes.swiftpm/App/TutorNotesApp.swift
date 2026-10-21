import SwiftUI

@main
struct TutorNotesApp: App {
    @StateObject private var settings = AppSettings.shared
    @State private var library = LibraryStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .environmentObject(settings)
                .tint(Color(hex: "#5B5BD6"))
                .onOpenURL { library.openNoteFile($0) }
        }
    }
}
