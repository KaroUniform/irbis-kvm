import AppKit
import SwiftUI

struct InputCaptureView: NSViewRepresentable {
    @ObservedObject var controller: KVMController

    func makeNSView(context: Context) -> InputCaptureNSView {
        let view = InputCaptureNSView()
        view.controller = controller
        return view
    }

    func updateNSView(_ nsView: InputCaptureNSView, context: Context) {
        nsView.controller = controller
    }
}

final class InputCaptureNSView: NSView {
    weak var controller: KVMController?
    private var sentPrimaryButtonDown = false
    private var sentSecondaryButtonDown = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func resignFirstResponder() -> Bool {
        controller?.releaseInput()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let alreadyCapturing = controller?.inputCaptured ?? false
        controller?.beginInputCapture()
        sentPrimaryButtonDown = alreadyCapturing
        if alreadyCapturing {
            controller?.mouseButton(.left, isDown: true)
        }
        window?.makeFirstResponder(self)
    }

    override func mouseUp(with event: NSEvent) {
        if sentPrimaryButtonDown {
            controller?.mouseButton(.left, isDown: false)
        }
        sentPrimaryButtonDown = false
    }

    override func rightMouseDown(with event: NSEvent) {
        let alreadyCapturing = controller?.inputCaptured ?? false
        controller?.beginInputCapture()
        sentSecondaryButtonDown = alreadyCapturing
        if alreadyCapturing {
            controller?.mouseButton(.right, isDown: true)
        }
        window?.makeFirstResponder(self)
    }

    override func rightMouseUp(with event: NSEvent) {
        if sentSecondaryButtonDown {
            controller?.mouseButton(.right, isDown: false)
        }
        sentSecondaryButtonDown = false
    }

    override func otherMouseDown(with event: NSEvent) {
        controller?.mouseButton(.middle, isDown: true)
    }

    override func otherMouseUp(with event: NSEvent) {
        controller?.mouseButton(.middle, isDown: false)
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.mouseMoved(deltaX: event.deltaX, deltaY: event.deltaY)
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.mouseMoved(deltaX: event.deltaX, deltaY: event.deltaY)
    }

    override func rightMouseDragged(with event: NSEvent) {
        controller?.mouseMoved(deltaX: event.deltaX, deltaY: event.deltaY)
    }

    override func otherMouseDragged(with event: NSEvent) {
        controller?.mouseMoved(deltaX: event.deltaX, deltaY: event.deltaY)
    }

    override func scrollWheel(with event: NSEvent) {
        controller?.scroll(deltaY: event.scrollingDeltaY)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 && flags.contains(.control) && flags.contains(.option) {
            controller?.releaseInput()
            return
        }
        controller?.keyDown(keyCode: event.keyCode)
    }

    override func keyUp(with event: NSEvent) {
        controller?.keyUp(keyCode: event.keyCode)
    }

    override func flagsChanged(with event: NSEvent) {
        controller?.modifierFlagsChanged(event.modifierFlags)
    }
}
