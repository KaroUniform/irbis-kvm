import Foundation

/// Characters to keystrokes on the US layout that CH9329 speaks on the wire.
///
/// `HIDKeyMap` answers "which HID usage did this local key press produce"; this table answers the
/// opposite question — "which key would have produced this character" — for text that arrives with
/// no key event at all, such as clipboard contents.
enum HIDTextMap {
    /// One keypress: the HID usage plus the modifier byte held while that usage is reported.
    struct Keystroke: Equatable {
        let usage: UInt8
        let modifiers: UInt8
    }

    /// The result of translating text: what can be typed, and how much had to be dropped.
    struct TypingPlan: Equatable {
        let keystrokes: [Keystroke]
        let skippedCharacters: Int
    }

    /// Left Shift, the same bit `HIDKeyMap.modifierByte(for:)` sets for a local Shift key.
    static let shiftModifier: UInt8 = 0x02

    static func keystroke(for character: Character) -> Keystroke? {
        keystrokes[character]
    }

    /// Translates text into keystrokes and counts everything a US keyboard cannot produce:
    /// Cyrillic, accented letters, emoji, and control codes. The count is not diagnostic noise —
    /// the caller has to show it, because a password or a shell command that quietly loses one
    /// character is more dangerous than one that is refused outright.
    static func plan(for text: String) -> TypingPlan {
        var strokes: [Keystroke] = []
        strokes.reserveCapacity(text.count)
        var skipped = 0

        for character in text {
            if let stroke = keystrokes[character] {
                strokes.append(stroke)
            } else {
                skipped += 1
            }
        }
        return TypingPlan(keystrokes: strokes, skippedCharacters: skipped)
    }

    /// One row per printable US key: the character it types alone, the character it types with
    /// Shift, and its HID usage. CH9329 sends US scancodes and knows nothing about the layout the
    /// target machine runs, so the shifted column only holds while the target is on US as well.
    private static let printableKeys: [(plain: Character, shifted: Character, usage: UInt8)] = [
        ("a", "A", 0x04), ("b", "B", 0x05), ("c", "C", 0x06), ("d", "D", 0x07),
        ("e", "E", 0x08), ("f", "F", 0x09), ("g", "G", 0x0A), ("h", "H", 0x0B),
        ("i", "I", 0x0C), ("j", "J", 0x0D), ("k", "K", 0x0E), ("l", "L", 0x0F),
        ("m", "M", 0x10), ("n", "N", 0x11), ("o", "O", 0x12), ("p", "P", 0x13),
        ("q", "Q", 0x14), ("r", "R", 0x15), ("s", "S", 0x16), ("t", "T", 0x17),
        ("u", "U", 0x18), ("v", "V", 0x19), ("w", "W", 0x1A), ("x", "X", 0x1B),
        ("y", "Y", 0x1C), ("z", "Z", 0x1D),
        ("1", "!", 0x1E), ("2", "@", 0x1F), ("3", "#", 0x20), ("4", "$", 0x21),
        ("5", "%", 0x22), ("6", "^", 0x23), ("7", "&", 0x24), ("8", "*", 0x25),
        ("9", "(", 0x26), ("0", ")", 0x27),
        ("-", "_", 0x2D), ("=", "+", 0x2E), ("[", "{", 0x2F), ("]", "}", 0x30),
        ("\\", "|", 0x31), (";", ":", 0x33), ("'", "\"", 0x34), ("`", "~", 0x35),
        (",", "<", 0x36), (".", ">", 0x37), ("/", "?", 0x38)
    ]

    private static let keystrokes: [Character: Keystroke] = {
        var table: [Character: Keystroke] = [:]
        for key in printableKeys {
            table[key.plain] = Keystroke(usage: key.usage, modifiers: 0)
            table[key.shifted] = Keystroke(usage: key.usage, modifiers: shiftModifier)
        }

        // Whitespace has no shifted twin. Swift reads CR LF as a single character, so listing all
        // three line endings presses Enter exactly once per line of a Windows or Unix clipboard.
        table[" "] = Keystroke(usage: 0x2C, modifiers: 0)
        table["\t"] = Keystroke(usage: 0x2B, modifiers: 0)
        table["\n"] = Keystroke(usage: 0x28, modifiers: 0)
        table["\r"] = Keystroke(usage: 0x28, modifiers: 0)
        table["\r\n"] = Keystroke(usage: 0x28, modifiers: 0)
        return table
    }()
}
