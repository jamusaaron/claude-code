import SwiftUI
import UIKit
import QuickLook
import ARKit

/// Something to hand to the share sheet.
struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// UIActivityViewController wrapper (SwiftUI's ShareLink needs the file to exist up front;
/// exports here are generated on demand).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var completion: (() -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in completion?() }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// AR Quick Look for a USDZ file, at true scale (content scaling disabled so a 40 cm object
/// stays 40 cm when placed in the room).
struct ARQuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            let item = ARQuickLookPreviewItem(fileAt: url)
            item.allowsContentScaling = false
            return item
        }
    }
}

enum SystemSettings {
    @MainActor static func open() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
