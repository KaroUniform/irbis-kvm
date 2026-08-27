import AppKit
import Combine
import Foundation

@MainActor
final class KVMController: ObservableObject {
    @Published private(set) var serialMessage = "UART disconnected"
    @Published private(set) var serialStatus: ConnectionStatus = .idle
    @Published private(set) var inputCaptured = false
    @Published private(set) var targetConnected = false
    @Published private(set) var isPasting = false
    @Published private(set) var pasteProgress = 0.0
    @Published private(set) var pasteMessage = ""
    @Published private(set) var pasteSkippedCharacters = 0
    @Published private(set) var availableSerialPorts: [String] = []
    @Published var selectedSerialPort = ""
    @Published var selectedSerialBaud: SerialBaud = .baud9600

    let video = VideoCaptureController()

    private let serial = CH9329SerialTransport()
    private var pressedUsages = Set<UInt8>()
    private var modifiers: UInt8 = 0
    private var mouseButtons: UInt8 = 0
    private var lastSentMouseButtons: UInt8 = 0
    private var pendingMouseX: CGFloat = 0
    private var pendingMouseY: CGFloat = 0
    private var pendingMouseWheel: CGFloat = 0
    private var mouseWriteInFlight = false
    private var mousePump: Task<Void, Never>?
    private var pasteTask: Task<Void, Never>?
    private var inputGeneration = 0
    private let pointerCapture = LocalPointerCapture()
    private var observers: [NSObjectProtocol] = []
    private let selectedSerialPortKey = "selectedSerialPort"
    private let selectedSerialBaudKey = "selectedSerialBaud"

    init() {
        selectedSerialPort = UserDefaults.standard.string(forKey: selectedSerialPortKey) ?? ""
        if let storedBaud = UserDefaults.standard.object(forKey: selectedSerialBaudKey) as? Int,
           let baud = SerialBaud(rawValue: storedBaud) {
            selectedSerialBaud = baud
        }
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.emergencyRelease()
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.emergencyRelease()
                }
            }
        )
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func refreshSerialPorts() {
        availableSerialPorts = CH9329SerialTransport.availablePorts()
        guard !availableSerialPorts.isEmpty else {
            selectedSerialPort = ""
            return
        }

        guard !availableSerialPorts.contains(selectedSerialPort) else { return }
        selectedSerialPort = availableSerialPorts.first(where: { $0.localizedCaseInsensitiveContains("wch") })
            ?? availableSerialPorts.first(where: { $0.localizedCaseInsensitiveContains("usb") })
            ?? availableSerialPorts[0]
        UserDefaults.standard.set(selectedSerialPort, forKey: selectedSerialPortKey)
    }

    func selectSerialPort(_ path: String) {
        selectedSerialPort = path
        UserDefaults.standard.set(path, forKey: selectedSerialPortKey)
    }

    func selectSerialBaud(_ baud: SerialBaud) {
        selectedSerialBaud = baud
        UserDefaults.standard.set(baud.rawValue, forKey: selectedSerialBaudKey)
    }

    func connectSerial() {
        guard !selectedSerialPort.isEmpty, availableSerialPorts.contains(selectedSerialPort) else {
            targetConnected = false
            serialStatus = .idle
            serialMessage = "Select a UART port and connect the adapter to your Mac"
            return
        }
        let path = selectedSerialPort
        let baud = selectedSerialBaud

        serialStatus = .connecting
        serialMessage = "Checking \(path) at \(baud.rawValue) baud…"

        Task {
            do {
                let info = try await serial.connect(path: path, baud: baud)
                targetConnected = info.usbConfigured
                serialStatus = info.usbConfigured ? .ready : .warning
                serialMessage = info.usbConfigured
                    ? "CH9329 ready: the server detects the HID device (\(path), \(baud.rawValue) baud)"
                    : "CH9329 is responding, but the server has not enumerated its HID device yet"
            } catch {
                targetConnected = false
                serialStatus = .failed
                serialMessage = "UART is not responding: \(error.localizedDescription)"
            }
        }
    }

    func disconnectSerial() {
        emergencyRelease()
        Task { await serial.close() }
        targetConnected = false
        serialStatus = .idle
        serialMessage = "UART disconnected"
    }

    func beginInputCapture() {
        guard serialStatus == .ready || serialStatus == .warning else {
            serialMessage = "Connect UART first"
            return
        }
        guard !inputCaptured else { return }
        inputCaptured = true
        inputGeneration &+= 1
        pointerCapture.begin()
        startMousePump()
    }

    func releaseInput() {
        emergencyRelease()
    }

    func emergencyRelease() {
        // A paste keeps typing on its own timer, so it has to stop with everything else: leaving
        // the window must never keep pushing characters at the server.
        pasteTask?.cancel()
        let shouldTransmitRelease = inputCaptured || !pressedUsages.isEmpty || modifiers != 0 || mouseButtons != 0
        inputCaptured = false
        inputGeneration &+= 1
        pointerCapture.end()
        stopMousePump()
        pressedUsages.removeAll()
        modifiers = 0
        mouseButtons = 0

        guard shouldTransmitRelease else { return }

        Task {
            do {
                try await serial.releaseAll()
            } catch {
                // The device may already be unplugged. Never block the user from leaving capture mode.
            }
        }
    }

    func keyDown(keyCode: UInt16) {
        guard inputCaptured, !isPasting, let usage = HIDKeyMap.usage(for: keyCode) else { return }
        guard pressedUsages.insert(usage).inserted else { return }
        transmitKeyboardState()
    }

    func keyUp(keyCode: UInt16) {
        guard inputCaptured, !isPasting, let usage = HIDKeyMap.usage(for: keyCode) else { return }
        guard pressedUsages.remove(usage) != nil else { return }
        transmitKeyboardState()
    }

    func modifierFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        guard inputCaptured, !isPasting else { return }
        let updatedModifiers = HIDKeyMap.modifierByte(for: flags)
        guard updatedModifiers != modifiers else { return }
        modifiers = updatedModifiers
        transmitKeyboardState()
    }

    func mouseMoved(deltaX: CGFloat, deltaY: CGFloat) {
        guard inputCaptured else { return }
        pendingMouseX += deltaX
        pendingMouseY += deltaY
    }

    func scroll(deltaY: CGFloat) {
        guard inputCaptured else { return }
        pendingMouseWheel += deltaY
    }

    func mouseButton(_ button: MouseButton, isDown: Bool) {
        guard inputCaptured else { return }
        let previousButtons = mouseButtons
        if isDown {
            mouseButtons |= button.rawValue
        } else {
            mouseButtons &= ~button.rawValue
        }
        guard mouseButtons != previousButtons else { return }
        flushMouseIfPossible()
    }

    func tapKey(_ usage: UInt8) {
        Task {
            do {
                try await serial.sendKeyboard(modifiers: 0, usages: [usage])
                try await serial.sendKeyboard(modifiers: 0, usages: [])
            } catch {
                recordTransportFailure(error)
            }
        }
    }

    func sendControlAltDelete() {
        Task {
            do {
                try await serial.sendKeyboard(modifiers: 0x05, usages: [0x4C])
                try await serial.sendKeyboard(modifiers: 0, usages: [])
            } catch {
                recordTransportFailure(error)
            }
        }
    }

    /// Pasting needs a live CH9329, but not captured input: the bridge sends HID reports no matter
    /// who owns the local keyboard.
    var canPasteClipboard: Bool {
        serialStatus == .ready || serialStatus == .warning
    }

    /// Types the clipboard on the server as US-layout keystrokes.
    func pasteClipboard() {
        guard canPasteClipboard else {
            pasteSkippedCharacters = 0
            pasteMessage = "Connect UART before pasting"
            return
        }
        guard pasteTask == nil else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            pasteSkippedCharacters = 0
            pasteMessage = "The clipboard holds no text"
            return
        }

        let plan = HIDTextMap.plan(for: text)
        pasteSkippedCharacters = plan.skippedCharacters
        guard !plan.keystrokes.isEmpty else {
            pasteMessage = "Nothing to type: none of these \(plan.skippedCharacters) characters exist on a US keyboard"
            return
        }

        // The paste composes its own keyboard reports, so anything the user is physically holding —
        // the shortcut's own ⇧⌘ included — is dropped first, and local key events stay muted until
        // the paste ends. A stray event in the middle of the text would corrupt it silently.
        pressedUsages.removeAll()
        modifiers = 0
        isPasting = true
        pasteProgress = 0
        pasteMessage = "Typing 0 of \(plan.keystrokes.count) characters…"

        let interval = selectedSerialBaud.keystrokeIntervalNanoseconds
        pasteTask = Task { [keystrokes = plan.keystrokes] in
            var heldModifiers: UInt8 = 0
            var typed = 0
            var failure: Error?

            do {
                for keystroke in keystrokes {
                    if keystroke.modifiers != heldModifiers {
                        // Shift gets its own frame, the way a physical keyboard reports it before
                        // the key travels down; held across a run of capitals it also saves frames.
                        heldModifiers = keystroke.modifiers
                        try await serial.sendKeyboard(modifiers: heldModifiers, usages: [])
                        try await Task.sleep(nanoseconds: interval)
                    }

                    try await serial.sendKeyboard(modifiers: heldModifiers, usages: [keystroke.usage])
                    try await Task.sleep(nanoseconds: interval)
                    // The key-up stops the target's auto-repeat and is what makes a doubled
                    // character ("ll", "--") arrive as two presses instead of one.
                    try await serial.sendKeyboard(modifiers: heldModifiers, usages: [])
                    try await Task.sleep(nanoseconds: interval)

                    typed += 1
                    pasteProgress = Double(typed) / Double(keystrokes.count)
                    pasteMessage = "Typing \(typed) of \(keystrokes.count) characters…"
                }
            } catch {
                // Task.sleep is the cancellation point; a UART failure arrives the same way.
                failure = error
            }

            // Finished, cancelled, or broken, the server must never be left holding a key.
            try? await serial.sendKeyboard(modifiers: 0, usages: [])

            pasteTask = nil
            isPasting = false
            pasteProgress = 0
            pasteMessage = Self.pasteSummary(
                typed: typed,
                total: keystrokes.count,
                skipped: plan.skippedCharacters,
                failure: failure
            )
            if let failure, !(failure is CancellationError) {
                recordTransportFailure(failure)
            }
        }
    }

    func cancelPaste() {
        pasteTask?.cancel()
    }

    /// The skipped count is always part of the summary. Dropping a character of a password or of a
    /// shell command without saying so is worse than refusing the paste outright.
    private static func pasteSummary(typed: Int, total: Int, skipped: Int, failure: Error?) -> String {
        let skippedNote = skipped > 0
            ? " · skipped \(skipped): CH9329 types US-layout ASCII only"
            : ""

        if failure is CancellationError {
            return "Paste cancelled after \(typed) of \(total) characters" + skippedNote
        }
        if failure != nil {
            return "Paste stopped after \(typed) of \(total) characters: the UART write failed" + skippedNote
        }
        return "Typed \(typed) characters from the clipboard" + skippedNote
    }

    private func transmitKeyboardState() {
        let usages = pressedUsages.sorted()
        let currentModifiers = modifiers
        Task {
            do {
                try await serial.sendKeyboard(modifiers: currentModifiers, usages: usages)
            } catch {
                recordTransportFailure(error)
            }
        }
    }

    private func startMousePump() {
        mousePump?.cancel()
        mousePump = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000) // 50 Hz fits comfortably in 9,600 baud.
                guard !Task.isCancelled, let self, self.inputCaptured else { break }
                self.flushMouseIfPossible()
            }
        }
    }

    private func stopMousePump() {
        mousePump?.cancel()
        mousePump = nil
        pendingMouseX = 0
        pendingMouseY = 0
        pendingMouseWheel = 0
        lastSentMouseButtons = 0
        mouseWriteInFlight = false
    }

    private func flushMouseIfPossible() {
        // Mouse frames share the same 9,600-baud link, so they wait until the paste has finished
        // rather than pushing keystroke frames further apart. Movement keeps accumulating.
        guard inputCaptured, !isPasting, !mouseWriteInFlight else { return }

        let deltaX = takeMouseStep(from: &pendingMouseX)
        let deltaY = takeMouseStep(from: &pendingMouseY)
        let wheel = takeMouseStep(from: &pendingMouseWheel)
        let buttons = mouseButtons
        guard deltaX != 0 || deltaY != 0 || wheel != 0 || buttons != lastSentMouseButtons else { return }

        let generation = inputGeneration
        mouseWriteInFlight = true
        lastSentMouseButtons = buttons

        Task {
            do {
                try await serial.sendRelativeMouse(
                    buttons: buttons,
                    deltaX: deltaX,
                    deltaY: deltaY,
                    wheel: wheel
                )
                guard generation == inputGeneration else { return }
                mouseWriteInFlight = false
            } catch {
                guard generation == inputGeneration else { return }
                mouseWriteInFlight = false
                recordTransportFailure(error)
            }
        }
    }

    private func takeMouseStep(from pending: inout CGFloat) -> Int {
        let integer = Int(pending.rounded(.towardZero))
        let step = min(127, max(-127, integer))
        pending -= CGFloat(step)
        return step
    }

    private func recordTransportFailure(_ error: Error) {
        inputCaptured = false
        inputGeneration &+= 1
        pointerCapture.end()
        stopMousePump()
        pressedUsages.removeAll()
        modifiers = 0
        mouseButtons = 0
        targetConnected = false
        serialStatus = .failed
        serialMessage = "UART connection lost: \(error.localizedDescription)"
    }
}

enum ConnectionStatus: Equatable {
    case idle
    case connecting
    case ready
    case warning
    case failed
}

enum MouseButton: UInt8 {
    case left = 0x01
    case right = 0x02
    case middle = 0x04
}
