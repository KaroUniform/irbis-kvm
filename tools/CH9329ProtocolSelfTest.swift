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

        check(
            CH9329Protocol.frame(
                command: CH9329Command.keyboard.rawValue,
                data: CH9329Protocol.keyboardReport(
                    modifiers: HIDTextMap.keystroke(for: "A")?.modifiers ?? 0,
                    usages: [HIDTextMap.keystroke(for: "A")?.usage ?? 0]
                )
            ),
            equals: "57 AB 00 02 08 02 00 04 00 00 00 00 00 12",
            named: "clipboard capital A"
        )
        // The paste paces itself by how long one of those frames occupies the UART.
        precondition(
            CH9329Protocol.frame(
                command: CH9329Command.keyboard.rawValue,
                data: CH9329Protocol.keyboardReport(modifiers: 0, usages: [])
            ).count == CH9329Protocol.keyboardFrameByteCount,
            "keyboard frame size drifted away from the pacing constant"
        )
        checkTextMap()

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

    /// The clipboard table is a second map, independent of `HIDKeyMap`, and a typo in it would put
    /// the wrong character into a password prompt. Check its shape rather than retyping every row.
    private static func checkTextMap() {
        let shift = HIDTextMap.shiftModifier
        let expected: [(Character, UInt8, UInt8)] = [
            ("a", 0x04, 0), ("A", 0x04, shift), ("z", 0x1D, 0), ("Z", 0x1D, shift),
            ("1", 0x1E, 0), ("!", 0x1E, shift), ("0", 0x27, 0), (")", 0x27, shift),
            ("-", 0x2D, 0), ("_", 0x2D, shift), ("/", 0x38, 0), ("?", 0x38, shift),
            ("\\", 0x31, 0), ("|", 0x31, shift), ("`", 0x35, 0), ("~", 0x35, shift),
            (" ", 0x2C, 0), ("\t", 0x2B, 0), ("\n", 0x28, 0), ("\r\n", 0x28, 0)
        ]
        for (character, usage, modifiers) in expected {
            precondition(
                HIDTextMap.keystroke(for: character) == HIDTextMap.Keystroke(usage: usage, modifiers: modifiers),
                "text map row for \(String(reflecting: character)) is wrong"
            )
        }

        // Every printable ASCII code must be typable, and no two of them may collide on the same
        // key: a collision means one character silently types as another.
        var printable: [(character: Character, keystroke: HIDTextMap.Keystroke)] = []
        for code in 0x20...0x7E {
            let character = Character(UnicodeScalar(UInt8(code)))
            guard let keystroke = HIDTextMap.keystroke(for: character) else {
                fatalError("printable ASCII \(String(reflecting: character)) has no US key")
            }
            printable.append((character, keystroke))
        }
        for outer in printable.indices {
            for inner in printable.indices where inner > outer {
                precondition(
                    printable[outer].keystroke != printable[inner].keystroke,
                    "\(printable[outer].character) and \(printable[inner].character) map to the same key"
                )
            }
        }

        // Anything a US keyboard cannot reach is dropped and counted, never guessed at.
        for character: Character in ["ё", "é", "😀", "\u{0}"] {
            precondition(HIDTextMap.keystroke(for: character) == nil, "non-US character must not map")
        }

        let plan = HIDTextMap.plan(for: "ls -la ~/логи\n")
        precondition(plan.keystrokes.count == 10, "typable characters miscounted")
        precondition(plan.skippedCharacters == 4, "skipped characters miscounted")
        precondition(plan.keystrokes.last?.usage == 0x28, "the trailing newline must press Enter")

        let windowsText = HIDTextMap.plan(for: "a\r\nb")
        precondition(
            windowsText.keystrokes.count == 3 && windowsText.keystrokes[1].usage == 0x28,
            "CRLF must press Enter exactly once"
        )
    }
}

private extension Array where Element == UInt8 {
    init(hex: String) {
        self = hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    }
}
