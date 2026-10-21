import SwiftUI
import VisionKit

/// The system document camera: finds the page edges, flattens and cleans up each page. Used to
/// scan worksheets, past papers, mark schemes and textbook pages.
struct DocumentScanner: UIViewControllerRepresentable {
    var onFinish: @MainActor ([UIImage]) -> Void
    var onCancel: @MainActor () -> Void

    /// False on the simulator and on devices without a camera.
    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: @MainActor ([UIImage]) -> Void
        let onCancel: @MainActor () -> Void

        init(onFinish: @escaping @MainActor ([UIImage]) -> Void, onCancel: @escaping @MainActor () -> Void) {
            self.onFinish = onFinish
            self.onCancel = onCancel
        }

        // VisionKit calls these on the main thread.
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            MainActor.assumeIsolated { onFinish(images) }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            MainActor.assumeIsolated { onCancel() }
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            MainActor.assumeIsolated { onCancel() }
        }
    }

    /// Writes scanned pages to a PDF in the temporary folder, each page 816 pt wide (a notebook
    /// page) and kept as JPEG so a long scan stays a few megabytes.
    static func pdf(from images: [UIImage], name: String) -> URL? {
        guard !images.isEmpty else { return nil }
        let safe = name.replacingOccurrences(of: "/", with: "-").trimmed
        let url = FileManager.default.temporaryDirectory.appendingPathComponent((safe.isEmpty ? "Scan" : safe) + ".pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 816, height: 1056))
        do {
            try renderer.writePDF(to: url) { rc in
                for image in images {
                    guard let cg = jpegBacked(image) else { continue }
                    let w = CGFloat(cg.width), h = CGFloat(cg.height)
                    guard w > 0, h > 0 else { continue }
                    let page = CGRect(x: 0, y: 0, width: 816, height: (816 * h / w).rounded())
                    rc.beginPage(withBounds: page, pageInfo: [:])
                    let ctx = rc.cgContext
                    ctx.saveGState()
                    ctx.translateBy(x: 0, y: page.height)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.interpolationQuality = .high
                    ctx.draw(cg, in: page)
                    ctx.restoreGState()
                }
            }
            return url
        } catch {
            return nil
        }
    }

    /// A downscaled copy backed by JPEG data, which PDF contexts embed as-is instead of as a bitmap.
    private static func jpegBacked(_ image: UIImage) -> CGImage? {
        let maxSide: CGFloat = 2200
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let scale = min(1, maxSide / max(pixels.width, pixels.height, 1))
        let size = CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = scaled.jpegData(compressionQuality: 0.72),
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
