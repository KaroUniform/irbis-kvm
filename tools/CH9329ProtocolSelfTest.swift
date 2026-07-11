import Foundation

@main
struct CH9329ProtocolSelfTest {
    static func main() {
        check(
            CH9329Protocol.frame(command: CH9329Command.getInfo.rawValue, data: []),
            equals: "57 AB 00 01 00 03",
            named: "GET_INFO"
        )
        check(
            CH9329Protocol.frame(
                command: CH9329Command.keyboard.rawValue,
                data: CH9329Protocol.keyboardReport(modifiers: 0, usages: [0x04])
            ),
            equals: "57 AB 00 02 08 00 00 04 00 00 00 00 00 10",
            named: "A down"
        )
        check(
            CH9329Protocol.frame(
                command: CH9329Command.relativeMouse.rawValue,
                data: CH9329Protocol.relativeMouseReport(buttons: 0, deltaX: -3, deltaY: 5, wheel: 0)
            ),
            equals: "57 AB 00 05 05 01 00 FD 05 00 0F",
            named: "relative mouse"
        )

        var incoming = [UInt8](hex: "00 57 AB 00 82 01 00 85")
        guard let parsed = CH9329Protocol.extractFrame(from: &incoming),
              parsed.command == 0x82,
              parsed.data == [0],
              incoming.isEmpty
        else {
            fatalError("stream parser test failed")
        }
        print("CH9329 protocol self-test passed")
    }

    private static func check(_ bytes: [UInt8], equals expected: String, named name: String) {
        precondition(bytes == [UInt8](hex: expected), "\(name) vector mismatch")
    }
}

private extension Array where Element == UInt8 {
    init(hex: String) {
        self = hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    }
}
