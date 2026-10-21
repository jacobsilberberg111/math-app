import UIKit
import PencilKit

/// Turns an Export menu choice into files: for the share sheet, or for the print dialog.
@MainActor
enum NoteExporter {
    /// The files for `kind`, or nil if exporting failed. Printing uses the PDF.
    static func files(for kind: ExportKind, document doc: NoteDocument) -> [URL]? {
        switch kind {
        case .pdf, .print: return PageRenderer.exportPDF(doc).map { [$0] }
        case .images: return PageRenderer.exportImages(doc)
        case .noteFile: return noteFile(doc).map { [$0] }
        }
    }

    /// The whole note as one `.margin` file. Uses the note's in-memory state, so edits that
    /// haven't reached the disk yet are included.
    private static func noteFile(_ doc: NoteDocument) -> URL? {
        guard let folder = ExportFiles.makeFolder() else { return nil }
        let url = folder.appendingPathComponent(ExportFiles.safeName(doc.meta.title) + "." + NoteArchive.fileExtension)
        do {
            let archive = try NoteArchive.pack(meta: doc.meta, content: doc.content, drawing: doc.drawing.dataRepresentation(),
                                               assetsFolder: doc.assetsFolder)
            try archive.encoded().write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Opens the print dialog for a PDF, as a popover under the toolbar's top-trailing corner.
    /// Returns false if it couldn't be shown.
    static func printPDF(_ url: URL, jobName: String) -> Bool {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        guard UIPrintInteractionController.isPrintingAvailable, let window = windows.first(where: { $0.isKeyWindow }) else { return false }
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = jobName
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = url
        let anchor = CGRect(x: window.bounds.maxX - 150, y: window.safeAreaInsets.top + 44, width: 1, height: 1)
        return controller.present(from: anchor, in: window, animated: true, completionHandler: nil)
    }
}
