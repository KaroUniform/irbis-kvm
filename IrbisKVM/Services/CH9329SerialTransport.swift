import Darwin
import Foundation

enum SerialTransportError: LocalizedError {
    case noPort
    case openFailed(String)
    case configureFailed(String)
    case writeFailed(String)
    case readFailed(String)
    case timeout
    case unexpectedResponse(UInt8)
    case commandFailed(UInt8)
    case malformedInfo

    var errorDescription: String? {
        switch self {
        case .noPort: return "No serial port found"
        case .openFailed(let detail), .configureFailed(let detail), .writeFailed(let detail), .readFailed(let detail):
            return detail
        case .timeout: return "CH9329 did not respond within 500 ms"
        case .unexpectedResponse(let command): return String(format: "Unexpected response: 0x%02X", command)
        case .commandFailed(let status):
            let detail: String
            switch status {
            case 0xE1: detail = "UART receive timeout"
            case 0xE2: detail = "Invalid frame header"
            case 0xE3: detail = "Unsupported command"
            case 0xE4: detail = "Checksum error"
            case 0xE5: detail = "Invalid parameters"
            case 0xE6: detail = "Operation not supported in the current mode"
            default: detail = String(format: "Status code 0x%02X", status)
            }
            return "CH9329: \(detail)"
        case .malformedInfo: return "CH9329 returned an invalid GET_INFO response"
        }
    }
}

actor CH9329SerialTransport {
    private var fileDescriptor: Int32 = -1
    private var receiveBuffer: [UInt8] = []

    nonisolated static func availablePorts() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else {
            return []
        }

        return names
            .filter { name in
                let lowercased = name.lowercased()
                // Show serial candidates rather than silently probing the first one. This includes
                // CH340/CH9329 names as well as adapters whose macOS driver uses `usbmodem`.
                return name.hasPrefix("cu.") &&
                    (lowercased.contains("usb") || lowercased.contains("serial") || lowercased.contains("modem"))
            }
            .sorted()
            .map { "/dev/\($0)" }
    }

    func connect(path: String, baud: SerialBaud) throws -> CH9329Info {
        close()

        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw SerialTransportError.openFailed(Self.systemError("Could not open \(path)"))
        }

        do {
            try configure(descriptor, baud: baud)
            fileDescriptor = descriptor
            // Some CH340/CH9329 cable assemblies reset when the UART endpoint opens.
            // Settle and retry the first GET_INFO without probing any other port.
            usleep(200_000)
            var lastError: Error?
            for attempt in 0..<3 {
                do {
                    return try getInfo()
                } catch {
                    lastError = error
                    guard attempt < 2 else { break }
                    usleep(250_000)
                }
            }
            throw lastError ?? SerialTransportError.timeout
        } catch {
            Darwin.close(descriptor)
            fileDescriptor = -1
            throw error
        }
    }

    func close() {
        guard fileDescriptor >= 0 else { return }
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
        receiveBuffer.removeAll(keepingCapacity: false)
    }

    func getInfo() throws -> CH9329Info {
        let response = try request(command: .getInfo, data: [])
        guard response.data.count >= 3 else { throw SerialTransportError.malformedInfo }
        return CH9329Info(
            version: response.data[0],
            usbConfigured: response.data[1] == 0x01,
            keyboardLEDs: response.data[2]
        )
    }

    func sendKeyboard(modifiers: UInt8, usages: [UInt8]) throws {
        let report = CH9329Protocol.keyboardReport(modifiers: modifiers, usages: usages)
        // Broadcast frames are accepted by every configured CH9329 address and intentionally
        // suppress ACKs. This prevents an ACK backlog from stalling high-rate HID input.
        try write(CH9329Protocol.frame(command: CH9329Command.keyboard.rawValue, data: report, address: 0xFF))
    }

    func sendRelativeMouse(buttons: UInt8, deltaX: Int, deltaY: Int, wheel: Int) throws {
        let report = CH9329Protocol.relativeMouseReport(
            buttons: buttons,
            deltaX: clampMouseDelta(deltaX),
            deltaY: clampMouseDelta(deltaY),
            wheel: clampMouseDelta(wheel)
        )
        try write(CH9329Protocol.frame(command: CH9329Command.relativeMouse.rawValue, data: report, address: 0xFF))
    }

    func releaseAll() throws {
        try sendKeyboard(modifiers: 0, usages: [])
        try sendRelativeMouse(buttons: 0, deltaX: 0, deltaY: 0, wheel: 0)
    }

    private func configure(_ descriptor: Int32, baud: SerialBaud) throws {
        var settings = termios()
        guard Darwin.tcgetattr(descriptor, &settings) == 0 else {
            throw SerialTransportError.configureFailed(Self.systemError("Could not read UART settings"))
        }

        Darwin.cfmakeraw(&settings)
        settings.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        settings.c_cflag &= ~tcflag_t(CSIZE | PARENB | CSTOPB | CRTSCTS)
        settings.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)

        guard Darwin.cfsetspeed(&settings, baud.speed) == 0 else {
            throw SerialTransportError.configureFailed(Self.systemError("Could not set \(baud.rawValue) baud"))
        }
        guard Darwin.tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
            throw SerialTransportError.configureFailed(Self.systemError("Could not apply UART settings"))
        }
    }

    private func request(command: CH9329Command, data: [UInt8]) throws -> CH9329Frame {
        let bytes = CH9329Protocol.frame(command: command.rawValue, data: data)
        try write(bytes)

        let expectedCommand = command.rawValue | 0x80
        let response = try readResponse(
            expectedCommand: expectedCommand,
            errorCommand: command.rawValue | 0xC0,
            timeoutMilliseconds: 500
        )
        guard response.data.first == 0x00 || command == .getInfo else {
            throw SerialTransportError.commandFailed(response.data.first ?? 0xFF)
        }
        return response
    }

    private func write(_ bytes: [UInt8]) throws {
        guard fileDescriptor >= 0 else { throw SerialTransportError.noPort }
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                Darwin.write(
                    fileDescriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
                _ = Darwin.poll(&descriptor, 1, 100)
                continue
            }
            throw SerialTransportError.writeFailed(Self.systemError("Could not write CH9329 command"))
        }
    }

    private func readResponse(
        expectedCommand: UInt8,
        errorCommand: UInt8,
        timeoutMilliseconds: Int
    ) throws -> CH9329Frame {
        guard fileDescriptor >= 0 else { throw SerialTransportError.noPort }
        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)

        while Date() < deadline {
            if let frame = CH9329Protocol.extractFrame(from: &receiveBuffer) {
                if frame.command == expectedCommand {
                    return frame
                }
                if frame.command == errorCommand {
                    throw SerialTransportError.commandFailed(frame.data.first ?? 0xFF)
                }
                continue
            }

            let remaining = max(1, Int(deadline.timeIntervalSinceNow * 1_000))
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&descriptor, 1, Int32(remaining))
            if pollResult == 0 { continue }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw SerialTransportError.readFailed(Self.systemError("UART read error"))
            }

            let capacity = 256
            var bytes = [UInt8](repeating: 0, count: capacity)
            let count = bytes.withUnsafeMutableBytes { buffer -> Int in
                Darwin.read(fileDescriptor, buffer.baseAddress, capacity)
            }
            if count > 0 {
                receiveBuffer.append(contentsOf: bytes.prefix(count))
            } else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                throw SerialTransportError.readFailed(Self.systemError("UART read error"))
            }
        }

        throw SerialTransportError.timeout
    }

    private func clampMouseDelta(_ value: Int) -> Int {
        min(127, max(-127, value))
    }

    private nonisolated static func systemError(_ prefix: String) -> String {
        "\(prefix): \(String(cString: Darwin.strerror(errno)))"
    }
}

enum SerialBaud: Int, CaseIterable, Identifiable {
    case baud9600 = 9_600
    case baud115200 = 115_200

    var id: Int { rawValue }

    fileprivate var speed: speed_t {
        switch self {
        case .baud9600: return speed_t(B9600)
        case .baud115200: return speed_t(B115200)
        }
    }
}
