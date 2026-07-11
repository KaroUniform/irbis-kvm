import Darwin
import Foundation

@main
struct CH9329WireProbe {
    static func main() {
        let baud = requestedBaud()
        guard let port = requestedPort() else {
            fputs("Usage: CH9329WireProbe --port /dev/cu.usbserial-XXXX [--baud 9600|115200] [--release-reports]\n", stderr)
            exit(2)
        }

        let descriptor = Darwin.open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            perror("open")
            exit(2)
        }
        defer { Darwin.close(descriptor) }

        var settings = termios()
        guard Darwin.tcgetattr(descriptor, &settings) == 0 else {
            perror("tcgetattr")
            exit(2)
        }
        Darwin.cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        settings.c_cflag &= ~tcflag_t(PARENB)
        settings.c_cflag &= ~tcflag_t(CSTOPB)
        guard Darwin.cfsetspeed(&settings, baud.speed) == 0,
              Darwin.tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
            perror("tcsetattr")
            exit(2)
        }

        print("port: \(port), baud: \(baud.label)")
        // Several CH340/CH9329 cable assemblies reset their UART bridge when DTR opens.
        // Let the target-side controller finish booting before the first protocol frame.
        usleep(1_000_000)
        exchange(descriptor, name: "GET_INFO", bytes: CH9329Protocol.frame(command: 0x01, data: []))

        if CommandLine.arguments.contains("--release-reports") {
            exchange(
                descriptor,
                name: "keyboard release (state-neutral)",
                bytes: CH9329Protocol.frame(command: 0x02, data: [0, 0, 0, 0, 0, 0, 0, 0])
            )
            exchange(
                descriptor,
                name: "mouse release (state-neutral)",
                bytes: CH9329Protocol.frame(command: 0x05, data: [1, 0, 0, 0, 0])
            )
        }
    }

    private static func exchange(_ descriptor: Int32, name: String, bytes: [UInt8]) {
        _ = Darwin.tcflush(descriptor, TCIFLUSH)
        let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, bytes.count) }
        print("\(name) → \(hex(bytes)) (written \(written))")

        let deadline = Date().addingTimeInterval(0.65)
        var received: [UInt8] = []
        while Date() < deadline {
            let timeout = max(1, Int(deadline.timeIntervalSinceNow * 1_000))
            var polling = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&polling, 1, Int32(timeout))
            if result <= 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 256)
            let capacity = buffer.count
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, capacity) }
            if count > 0 { received.append(contentsOf: buffer.prefix(count)) }
        }
        print("\(name) ← \(received.isEmpty ? "(no bytes)" : hex(received))")
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func requestedBaud() -> (label: Int, speed: speed_t) {
        if let index = CommandLine.arguments.firstIndex(of: "--baud"),
           CommandLine.arguments.indices.contains(index + 1),
           let value = Int(CommandLine.arguments[index + 1]),
           value == 115_200 {
            return (115_200, speed_t(B115200))
        }
        return (9_600, speed_t(B9600))
    }

    private static func requestedPort() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--port"),
              CommandLine.arguments.indices.contains(index + 1)
        else { return nil }

        let port = CommandLine.arguments[index + 1]
        return port.hasPrefix("/dev/cu.") ? port : nil
    }
}
