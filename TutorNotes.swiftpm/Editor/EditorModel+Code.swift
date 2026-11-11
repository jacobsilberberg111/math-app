import SwiftUI

extension EditorModel {
    /// Insert → Code Block: an empty Python block in view, opened in the code editor.
    func insertCodeBlock() {
        let c = CodeContent(code: "")
        guard let e = insertStudentElement(.code(c), size: CodeRenderer.size(for: c, width: 560), actionName: "Insert Code") else { return }
        codeEditTarget = CodeEditTarget(id: e.id)
    }
}
