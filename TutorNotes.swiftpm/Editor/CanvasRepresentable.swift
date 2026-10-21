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
        guard vc.tool != config else { return }
        // Switching tools can end text editing or clear the selection, and both write back to the
        // model. Writing observed state during SwiftUI's update is undefined behaviour (other
        // changes in the same update can be dropped), so apply the tool just after it.
        let config = config
        DispatchQueue.main.async { [weak vc] in
            guard let vc, vc.tool != config else { return }
            vc.apply(tool: config)
        }
    }
}
