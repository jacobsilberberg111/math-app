import SwiftUI
import VisionKit

/// The system document camera: finds the page edges, flattens and cleans up each page. Used to
/// scan worksheets, past papers, mark schemes and textbook pages.
struct DocumentScanner: UIViewControllerRepresentable {
    /// Each scanned page as JPEG data (full-resolution camera images are dropped as soon as
    /// they're compressed, so long scans don't pile up in memory).
    var onFinish: @MainActor ([Data]) -> Void
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
        let onFinish: @MainActor ([Data]) -> Void
        let onCancel: @MainActor () -> Void

        init(onFinish: @escaping @MainActor ([Data]) -> Void, onCancel: @escaping @MainActor () -> Void) {
            self.onFinish = onFinish
            self.onCancel = onCancel
        }

        // VisionKit calls these on the main thread.
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var pages: [Data] = []
            for i in 0..<scan.pageCount {
                autoreleasepool {
                    if let data = DocumentScanner.compressedPage(scan.imageOfPage(at: i)) { pages.append(data) }
                }
            }
            MainActor.assumeIsolated { onFinish(pages) }
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
    static func pdf(from pages: [Data], name: String) -> URL? {
        guard !pages.isEmpty else { return nil }
        let safe = name.replacingOccurrences(of: "/", with: "-").trimmed
        let url = FileManager.default.temporaryDirectory.appendingPathComponent((safe.isEmpty ? "Scan" : safe) + ".pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 816, height: 1056))
        do {
            try renderer.writePDF(to: url) { rc in
                for data in pages {
                    autoreleasepool {
                        guard let provider = CGDataProvider(data: data as CFData),
                              let cg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
                        let w = CGFloat(cg.width), h = CGFloat(cg.height)
                        guard w > 0, h > 0 else { return }
                        let page = CGRect(x: 0, y: 0, width: 816, height: (816 * h / w).rounded())
                        rc.beginPage(withBounds: page, pageInfo: [:])
                        let ctx = rc.cgContext
                        ctx.saveGState()
                        ctx.translateBy(x: 0, y: page.height)
                        ctx.scaleBy(x: 1, y: -1)
                        ctx.interpolationQuality = .high
                        // Drawn from JPEG data, the page is embedded as JPEG rather than as a bitmap.
                        ctx.draw(cg, in: page)
                        ctx.restoreGState()
                    }
                }
            }
            return url
        } catch {
            return nil
        }
    }

    /// The page downscaled to at most 2200 px and JPEG-compressed.
    static func compressedPage(_ image: UIImage) -> Data? {
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
        return scaled.jpegData(compressionQuality: 0.72)
    }
}
