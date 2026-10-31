import Foundation

/// macOS virtual key codes (`kVK_*` from Carbon) and their names on a US keyboard.
/// The settings app prefers labels from the current keyboard layout.
public enum KeyCode {
    public static let a = 0x00, s = 0x01, d = 0x02, f = 0x03, h = 0x04, g = 0x05, z = 0x06, x = 0x07
    public static let c = 0x08, v = 0x09, b = 0x0B, q = 0x0C, w = 0x0D, e = 0x0E, r = 0x0F, y = 0x10
    public static let t = 0x11, one = 0x12, two = 0x13, three = 0x14, four = 0x15, six = 0x16, five = 0x17
    public static let equal = 0x18, nine = 0x19, seven = 0x1A, minus = 0x1B, eight = 0x1C, zero = 0x1D
    public static let rightBracket = 0x1E, o = 0x1F, u = 0x20, leftBracket = 0x21, i = 0x22, p = 0x23
    public static let returnKey = 0x24, l = 0x25, j = 0x26, quote = 0x27, k = 0x28, semicolon = 0x29
    public static let backslash = 0x2A, comma = 0x2B, slash = 0x2C, n = 0x2D, m = 0x2E, period = 0x2F
    public static let tab = 0x30, space = 0x31, grave = 0x32, delete = 0x33, escape = 0x35
    public static let rightCommand = 0x36, command = 0x37, shift = 0x38, capsLock = 0x39, option = 0x3A
    public static let control = 0x3B, rightShift = 0x3C, rightOption = 0x3D, rightControl = 0x3E, function = 0x3F
    public static let f17 = 0x40, volumeUp = 0x48, volumeDown = 0x49, mute = 0x4A, f18 = 0x4F, f19 = 0x50
    public static let f20 = 0x5A, f5 = 0x60, f6 = 0x61, f7 = 0x62, f3 = 0x63, f8 = 0x64, f9 = 0x65
    public static let f11 = 0x67, f13 = 0x69, f16 = 0x6A, f14 = 0x6B, f10 = 0x6D, f12 = 0x6F, f15 = 0x71
    public static let help = 0x72, home = 0x73, pageUp = 0x74, forwardDelete = 0x75, f4 = 0x76, end = 0x77
    public static let f2 = 0x78, pageDown = 0x79, f1 = 0x7A, leftArrow = 0x7B, rightArrow = 0x7C
    public static let downArrow = 0x7D, upArrow = 0x7E

    public static let modifierKeys: Set<Int> = [command, rightCommand, shift, rightShift, option, rightOption,
                                                control, rightControl, function, capsLock]

    /// Keys that physically carry the fn flag (arrows and the navigation block).
    public static let functionFlagKeys: Set<Int> = [leftArrow, rightArrow, upArrow, downArrow, home, end,
                                                    pageUp, pageDown, forwardDelete, help]
}

public enum KeyNames {
    static let special: [Int: String] = [
        KeyCode.returnKey: "↩", KeyCode.tab: "⇥", KeyCode.space: "Space", KeyCode.delete: "⌫",
        KeyCode.escape: "⎋", KeyCode.forwardDelete: "⌦", KeyCode.home: "↖", KeyCode.end: "↘",
        KeyCode.pageUp: "⇞", KeyCode.pageDown: "⇟", KeyCode.leftArrow: "←", KeyCode.rightArrow: "→",
        KeyCode.upArrow: "↑", KeyCode.downArrow: "↓", KeyCode.help: "Help", KeyCode.capsLock: "⇪",
        KeyCode.volumeUp: "Volume Up", KeyCode.volumeDown: "Volume Down", KeyCode.mute: "Mute",
        KeyCode.f1: "F1", KeyCode.f2: "F2", KeyCode.f3: "F3", KeyCode.f4: "F4", KeyCode.f5: "F5",
        KeyCode.f6: "F6", KeyCode.f7: "F7", KeyCode.f8: "F8", KeyCode.f9: "F9", KeyCode.f10: "F10",
        KeyCode.f11: "F11", KeyCode.f12: "F12", KeyCode.f13: "F13", KeyCode.f14: "F14", KeyCode.f15: "F15",
        KeyCode.f16: "F16", KeyCode.f17: "F17", KeyCode.f18: "F18", KeyCode.f19: "F19", KeyCode.f20: "F20",
        0x41: "Num .", 0x43: "Num *", 0x45: "Num +", 0x47: "Clear", 0x4B: "Num /", 0x4C: "⌤", 0x4E: "Num -",
        0x51: "Num =", 0x52: "Num 0", 0x53: "Num 1", 0x54: "Num 2", 0x55: "Num 3", 0x56: "Num 4",
        0x57: "Num 5", 0x58: "Num 6", 0x59: "Num 7", 0x5B: "Num 8", 0x5C: "Num 9",
    ]

    static let ansi: [Int: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C",
        0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1",
        0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-",
        0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L",
        0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M",
        0x2F: ".", 0x32: "`",
    ]

    /// Layout aware names supplied by the app (character keys only).
    nonisolated(unsafe) public static var layoutName: ((Int) -> String?)?

    public static func isSpecial(_ code: Int) -> Bool { special[code] != nil }

    public static func name(for code: Int) -> String {
        if let s = special[code] { return s }
        if let n = layoutName?(code), !n.isEmpty { return n.uppercased() }
        return ansi[code] ?? String(format: "Key 0x%02X", code)
    }
}
