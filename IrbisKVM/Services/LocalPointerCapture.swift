import ApplicationServices
import AppKit

@MainActor
final class LocalPointerCapture {
    private var isCaptured = false

    func begin() {
        guard !isCaptured else { return }
        guard CGAssociateMouseAndMouseCursorPosition(0) == .success else { return }
        _ = CGDisplayHideCursor(kCGNullDirectDisplay)
        isCaptured = true
    }

    func end() {
        guard isCaptured else { return }
        _ = CGAssociateMouseAndMouseCursorPosition(1)
        _ = CGDisplayShowCursor(kCGNullDirectDisplay)
        isCaptured = false
    }
}
