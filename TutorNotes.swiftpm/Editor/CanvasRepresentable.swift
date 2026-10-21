import SwiftUI

struct CanvasRepresentable: UIViewControllerRepresentable {
    let model: EditorModel
    let config: CanvasToolConfig

    func makeUIViewController(context: Context) -> NoteCanvasViewController {
        let vc = NoteCanvasViewController(document: model.document)
        vc.host = model
        model.canvas = vc
        return vc
    }

    func updateUIViewController(_ vc: NoteCanvasViewController, context: Context) {
        if vc.tool != config { vc.apply(tool: config) }
    }
}
