import Foundation

enum CH9329Command: UInt8 {
    case getInfo = 0x01
    case keyboard = 0x02
    case absoluteMouse = 0x04
    case relativeMouse = 0x05
}

struct CH9329Frame: Equatable {
    let address: UInt8
    let command: UInt8
    let data: [UInt8]
}

struct CH9329Info: Equatable {
    let version: UInt8
    let usbConfigured: Bool
    let keyboardLEDs: UInt8
}

enum CH9329Protocol {
    static let header: [UInt8] = [0x57, 0xAB]

    // Header, address, command, length, the 8-byte keyboard report, and the checksum. Pacing code
    // needs the size to know how long a single keystroke frame occupies the UART.
    static let keyboardFrameByteCount = 14

    static func frame(command: UInt8, data: [UInt8], address: UInt8 = 0) -> [UInt8] {
        precondition(data.count <= 64, "CH9329 accepts at most 64 payload bytes")
        var bytes = header + [address, command, UInt8(data.count)] + data
        bytes.append(bytes.reduce(0, &+))
        return bytes
    }

    static func keyboardReport(modifiers: UInt8, usages: [UInt8]) -> [UInt8] {
        let keys = Array(usages.prefix(6))
        return [modifiers, 0] + keys + Array(repeating: 0, count: 6 - keys.count)
    }

    static func relativeMouseReport(
        buttons: UInt8,
        deltaX: Int,
        deltaY: Int,
        wheel: Int
    ) -> [UInt8] {
        [
            0x01,
            buttons,
            encodedSignedByte(deltaX),
            encodedSignedByte(deltaY),
            encodedSignedByte(wheel)
        ]
    }

    static func extractFrame(from buffer: inout [UInt8]) -> CH9329Frame? {
        while buffer.count >= header.count {
            guard buffer[0] == header[0], buffer[1] == header[1] else {
                buffer.removeFirst()
                continue
            }

            guard buffer.count >= 5 else { return nil }
            let dataLength = Int(buffer[4])
            guard dataLength <= 64 else {
                buffer.removeFirst()
                continue
            }
            let frameLength = 6 + dataLength
            guard buffer.count >= frameLength else { return nil }

            let candidate = Array(buffer.prefix(frameLength))
            let expectedChecksum = candidate.dropLast().reduce(0, &+)
            guard candidate.last == expectedChecksum else {
                buffer.removeFirst()
                continue
            }

            buffer.removeFirst(frameLength)
            return CH9329Frame(
                address: candidate[2],
                command: candidate[3],
                data: Array(candidate[5..<(5 + dataLength)])
            )
        }
        return nil
    }

    private static func encodedSignedByte(_ value: Int) -> UInt8 {
        UInt8(bitPattern: Int8(clamping: value))
    }
}
