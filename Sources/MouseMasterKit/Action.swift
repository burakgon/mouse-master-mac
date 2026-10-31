import Foundation

/// Modifier keys of a key combination.
public struct Modifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let shift = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)
    public static let function = Modifiers(rawValue: 1 << 4)

    /// In the order macOS displays them.
    public static let ordered: [(Modifiers, String, String)] = [
        (.function, "fn", "fn "), (.control, "control", "⌃"), (.option, "option", "⌥"),
        (.shift, "shift", "⇧"), (.command, "command", "⌘"),
    ]

    public var symbols: String {
        Self.ordered.filter { contains($0.0) }.map(\.2).joined()
    }

    public init(from decoder: Decoder) throws {
        let names = try decoder.singleValueContainer().decode([String].self)
        var m = Modifiers()
        for (flag, name, _) in Self.ordered where names.contains(name) { m.insert(flag) }
        if names.contains("fn") { m.insert(.function) }
        self = m
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Self.ordered.filter { contains($0.0) }.map(\.1))
    }
}

/// A key combination: an optional key (macOS virtual key code) plus modifiers.
public struct KeyCombo: Hashable, Sendable, Codable {
    /// Virtual key code (`kVK_*`); nil for a combination of modifiers only.
    public var keyCode: Int?
    public var modifiers: Modifiers
    /// Label captured when the shortcut was recorded (keyboard layout aware), e.g. "⌘⇧T".
    public var display: String?

    public init(keyCode: Int?, modifiers: Modifiers = [], display: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    public var label: String {
        if let display, !display.isEmpty { return display }
        return modifiers.symbols + (keyCode.map { KeyNames.name(for: $0) } ?? "")
    }
}

public enum MouseButton: String, Codable, CaseIterable, Sendable {
    case left, right, middle, back, forward

    /// CoreGraphics button number.
    public var number: Int {
        switch self {
        case .left: return 0
        case .right: return 1
        case .middle: return 2
        case .back: return 3
        case .forward: return 4
        }
    }

    public var title: String {
        switch self {
        case .left: return "Left click"
        case .right: return "Right click"
        case .middle: return "Middle click"
        case .back: return "Back button (button 4)"
        case .forward: return "Forward button (button 5)"
        }
    }
}

public enum Direction: String, Codable, CaseIterable, Sendable {
    case up, down, left, right
}

public enum GestureMode: String, Codable, CaseIterable, Sendable {
    /// Up / down / left / right / click, each with its own action.
    case directional
    /// Moving the mouse scrolls in any direction.
    case pan
    /// Moving the mouse up zooms in, down zooms out.
    case zoom
}

public enum GestureTrigger: String, Codable, Sendable {
    /// Fire as soon as the movement passes the threshold.
    case move
    /// Fire when the button is released.
    case release
}

/// Hold a control and move the mouse.
public struct GestureSet: Hashable, Sendable, Codable {
    public var mode: GestureMode = .directional
    public var up: Action = .builtin("mission-control")
    public var down: Action = .builtin("app-expose")
    public var left: Action = .builtin("space-left")
    public var right: Action = .builtin("space-right")
    /// Pressing and releasing without moving.
    public var click: Action = .builtin("mission-control")
    /// Distance in millimetres the mouse must travel to recognise a direction.
    public var thresholdMM: Double = 7
    public var trigger: GestureTrigger = .move
    /// Keep firing up/down actions every threshold while held (volume, zoom...).
    public var repeatVertical = false
    /// Keep firing left/right actions every threshold while held.
    public var repeatHorizontal = false
    /// Pan mode: scroll speed multiplier.
    public var panSpeed: Double = 1
    /// Pan mode: drag the content (grab and move) instead of the view.
    public var panInvert = false
    /// Zoom mode: speed multiplier.
    public var zoomSpeed: Double = 1

    public init() {}

    public func action(_ d: Direction) -> Action {
        switch d {
        case .up: return up
        case .down: return down
        case .left: return left
        case .right: return right
        }
    }

    public mutating func setAction(_ a: Action, for d: Direction) {
        switch d {
        case .up: up = a
        case .down: down = a
        case .left: left = a
        case .right: right = a
        }
    }

    public func repeats(_ d: Direction) -> Bool {
        d == .up || d == .down ? repeatVertical : repeatHorizontal
    }

    enum CodingKeys: String, CodingKey {
        case mode, up, down, left, right, click, thresholdMM, trigger, repeatVertical, repeatHorizontal
        case panSpeed, panInvert, zoomSpeed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GestureSet.defaultValue
        mode = c.value(.mode, d.mode)
        up = c.value(.up, d.up)
        down = c.value(.down, d.down)
        left = c.value(.left, d.left)
        right = c.value(.right, d.right)
        click = c.value(.click, d.click)
        thresholdMM = c.value(.thresholdMM, d.thresholdMM)
        trigger = c.value(.trigger, d.trigger)
        repeatVertical = c.value(.repeatVertical, d.repeatVertical)
        repeatHorizontal = c.value(.repeatHorizontal, d.repeatHorizontal)
        panSpeed = c.value(.panSpeed, d.panSpeed)
        panInvert = c.value(.panInvert, d.panInvert)
        zoomSpeed = c.value(.zoomSpeed, d.zoomSpeed)
    }

    static let defaultValue = GestureSet()
}

/// One step of a macro.
public enum MacroStep: Hashable, Sendable, Codable {
    case keys(KeyCombo)
    case builtin(String)
    case click(MouseButton)
    case delay(Int)
    case command(String)
    case text(String)

    enum CodingKeys: String, CodingKey { case step, keyCode, modifiers, display, id, button, ms, command, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .step) {
        case "keys":
            self = .keys(KeyCombo(keyCode: try c.decodeIfPresent(Int.self, forKey: .keyCode),
                                  modifiers: c.value(.modifiers, Modifiers()),
                                  display: try c.decodeIfPresent(String.self, forKey: .display)))
        case "builtin": self = .builtin(try c.decode(String.self, forKey: .id))
        case "click": self = .click(c.value(.button, MouseButton.left))
        case "delay": self = .delay(c.value(.ms, 100))
        case "command": self = .command(try c.decode(String.self, forKey: .command))
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .step, in: c, debugDescription: "unknown macro step \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keys(let k):
            try c.encode("keys", forKey: .step)
            try c.encodeIfPresent(k.keyCode, forKey: .keyCode)
            try c.encode(k.modifiers, forKey: .modifiers)
            try c.encodeIfPresent(k.display, forKey: .display)
        case .builtin(let id):
            try c.encode("builtin", forKey: .step)
            try c.encode(id, forKey: .id)
        case .click(let b):
            try c.encode("click", forKey: .step)
            try c.encode(b, forKey: .button)
        case .delay(let ms):
            try c.encode("delay", forKey: .step)
            try c.encode(ms, forKey: .ms)
        case .command(let s):
            try c.encode("command", forKey: .step)
            try c.encode(s, forKey: .command)
        case .text(let s):
            try c.encode("text", forKey: .step)
            try c.encode(s, forKey: .text)
        }
    }
}

/// What a control, gesture direction or wheel step does.
public indirect enum Action: Hashable, Sendable, Codable {
    /// The control's native function; the control is not diverted.
    case `default`
    /// Does nothing (disables the control). Stored as "none".
    case nothing
    /// A built-in action from the catalog.
    case builtin(String)
    /// A key combination, held while the control is held.
    case keys(KeyCombo)
    /// A mouse button, held while the control is held.
    case mouse(MouseButton)
    /// A shell command.
    case command(String)
    /// A URL, file, folder or application (path or bundle identifier).
    case open(String)
    /// A shortcut from the Shortcuts app, by name.
    case shortcut(String)
    /// Types a piece of text.
    case text(String)
    case setDPI(Int)
    /// Another resolution while the control is held ("precision mode").
    case shiftDPI(Int)
    /// Easy-Switch to another host (0 based).
    case switchHost(Int)
    /// Hold the control and move the mouse.
    case gestures(GestureSet)
    case macro([MacroStep])

    /// Whether the control must be diverted to run this action.
    public var needsDivert: Bool { self != .default }
    /// Whether the control must report pointer motion while held.
    public var needsRawXY: Bool {
        if case .gestures = self { return true }
        return false
    }

    public var isGestures: Bool { needsRawXY }

    enum CodingKeys: String, CodingKey {
        case type, id, keyCode, modifiers, display, button, command, target, name, text, dpi, host, steps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "default": self = .default
        case "none": self = .nothing
        case "builtin": self = .builtin(try c.decode(String.self, forKey: .id))
        case "keys":
            self = .keys(KeyCombo(keyCode: try c.decodeIfPresent(Int.self, forKey: .keyCode),
                                  modifiers: c.value(.modifiers, Modifiers()),
                                  display: try c.decodeIfPresent(String.self, forKey: .display)))
        case "mouse": self = .mouse(try c.decode(MouseButton.self, forKey: .button))
        case "command": self = .command(try c.decode(String.self, forKey: .command))
        case "open": self = .open(try c.decode(String.self, forKey: .target))
        case "shortcut": self = .shortcut(try c.decode(String.self, forKey: .name))
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        case "set-dpi": self = .setDPI(try c.decode(Int.self, forKey: .dpi))
        case "shift-dpi": self = .shiftDPI(try c.decode(Int.self, forKey: .dpi))
        case "switch-host": self = .switchHost(try c.decode(Int.self, forKey: .host))
        case "gestures": self = .gestures(try GestureSet(from: decoder))
        case "macro": self = .macro(try c.decode([MacroStep].self, forKey: .steps))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown action \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .default: try c.encode("default", forKey: .type)
        case .nothing: try c.encode("none", forKey: .type)
        case .builtin(let id):
            try c.encode("builtin", forKey: .type)
            try c.encode(id, forKey: .id)
        case .keys(let k):
            try c.encode("keys", forKey: .type)
            try c.encodeIfPresent(k.keyCode, forKey: .keyCode)
            try c.encode(k.modifiers, forKey: .modifiers)
            try c.encodeIfPresent(k.display, forKey: .display)
        case .mouse(let b):
            try c.encode("mouse", forKey: .type)
            try c.encode(b, forKey: .button)
        case .command(let s):
            try c.encode("command", forKey: .type)
            try c.encode(s, forKey: .command)
        case .open(let s):
            try c.encode("open", forKey: .type)
            try c.encode(s, forKey: .target)
        case .shortcut(let s):
            try c.encode("shortcut", forKey: .type)
            try c.encode(s, forKey: .name)
        case .text(let s):
            try c.encode("text", forKey: .type)
            try c.encode(s, forKey: .text)
        case .setDPI(let d):
            try c.encode("set-dpi", forKey: .type)
            try c.encode(d, forKey: .dpi)
        case .shiftDPI(let d):
            try c.encode("shift-dpi", forKey: .type)
            try c.encode(d, forKey: .dpi)
        case .switchHost(let h):
            try c.encode("switch-host", forKey: .type)
            try c.encode(h, forKey: .host)
        case .gestures(let set):
            try c.encode("gestures", forKey: .type)
            try set.encode(to: encoder)
        case .macro(let steps):
            try c.encode("macro", forKey: .type)
            try c.encode(steps, forKey: .steps)
        }
    }
}

extension KeyedDecodingContainer {
    /// Lenient decoding: a missing or malformed value falls back to the default, so an
    /// older or hand edited configuration never fails to load as a whole.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    func optional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}
