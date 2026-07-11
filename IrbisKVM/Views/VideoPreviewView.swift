import AVFoundation
import AppKit
import SwiftUI

struct VideoPreviewView: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.captureLayer = previewLayer
        return view
    }

    func updateNSView(_ nsView: PreviewHostView, context: Context) {
        nsView.captureLayer = previewLayer
    }
}

final class PreviewHostView: NSView {
    var captureLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            guard oldValue !== captureLayer else { return }
            oldValue?.removeFromSuperlayer()
            guard let captureLayer else { return }
            wantsLayer = true
            layer?.addSublayer(captureLayer)
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        captureLayer?.frame = bounds
    }
}
