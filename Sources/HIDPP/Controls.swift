import Foundation

/// Control ids (CIDs) of mouse buttons and other reprogrammable controls.
public enum CID {
    public static let left: UInt16 = 0x0050
    public static let right: UInt16 = 0x0051
    public static let middle: UInt16 = 0x0052
    public static let back: UInt16 = 0x0053
    public static let forward: UInt16 = 0x0056
    public static let scrollLeft: UInt16 = 0x005B
    public static let scrollRight: UInt16 = 0x005D
    public static let gesture: UInt16 = 0x00C3
    public static let modeShift: UInt16 = 0x00C4
    public static let virtualGesture: UInt16 = 0x00D7
    public static let dpiButton: UInt16 = 0x00ED
    public static let dpiSwitch: UInt16 = 0x00FD
    public static let hapticPanel: UInt16 = 0x01A0
}

/// The semantic role of a control, used to place it on device artwork and to
/// name it in the configuration.
public enum ControlRole: String, Codable, Sendable, CaseIterable {
    case left, right, middle, back, forward
    case scrollLeft = "scroll-left"
    case scrollRight = "scroll-right"
    case gesture
    case modeShift = "mode-shift"
    case dpi
    case hapticPanel = "haptic-panel"
    case other

    public init(cid: UInt16) {
        switch cid {
        case CID.left: self = .left
        case CID.right: self = .right
        case CID.middle: self = .middle
        case CID.back, 0x0054, 0x0055, 0x00BD, 0x00CE: self = .back
        case CID.forward, 0x0057, 0x0058, 0x00CF: self = .forward
        case CID.scrollLeft, 0x005A: self = .scrollLeft
        case CID.scrollRight, 0x005C: self = .scrollRight
        case CID.gesture, 0x00D0: self = .gesture
        case CID.modeShift: self = .modeShift
        case CID.dpiButton, CID.dpiSwitch: self = .dpi
        case CID.hapticPanel: self = .hapticPanel
        default: self = .other
        }
    }
}

/// Stable configuration key of a control: its role name, or `cid-xxxx`.
public func controlKey(_ cid: UInt16) -> String {
    let role = ControlRole(cid: cid)
    return role == .other ? String(format: "cid-%04x", cid) : role.rawValue
}

/// Human readable name of a control.
public func controlName(_ cid: UInt16) -> String {
    switch cid {
    case 0x0050: return "Left button"
    case 0x0051: return "Right button"
    case 0x0052: return "Middle button"
    case 0x0053, 0x0054, 0x00BD, 0x00CE: return "Back button"
    case 0x0056, 0x0057, 0x00CF: return "Forward button"
    case 0x005A, 0x005B: return "Scroll left"
    case 0x005C, 0x005D: return "Scroll right"
    case 0x00C3, 0x00D0: return "Gesture button"
    case 0x00C4: return "Mode shift button"
    case 0x00D7: return "Virtual gesture button"
    case 0x00ED: return "DPI button"
    case 0x00FD: return "DPI switch"
    case 0x01A0: return "Haptic sense panel"
    case 0x0003: return "Mute"
    case 0x0008: return "App switcher"
    case 0x00C7: return "Brightness down"
    case 0x00C8: return "Brightness up"
    case 0x00E4: return "Previous track"
    case 0x00E5: return "Play / Pause"
    case 0x00E6: return "Next track"
    case 0x00E7: return "Mute"
    case 0x00E8: return "Volume down"
    case 0x00E9: return "Volume up"
    case 0x0103: return "Dictation"
    case 0x0108: return "Emoji"
    case 0x010A: return "Screen capture"
    case 0x011C: return "Mute microphone"
    case 0x011D: return "Do not disturb"
    case 0x01A9: return "Cut"
    case 0x01AA: return "Copy"
    case 0x01AB: return "Paste"
    case 0x01B4: return "AI prompt"
    default: return String(format: "Control 0x%04X", cid)
    }
}
