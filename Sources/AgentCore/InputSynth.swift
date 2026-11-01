import AppKit
import CoreGraphics
import MouseMasterKit

/// Posts keyboard, mouse, scroll and media key events.
@MainActor
final class InputSynth {
    private let source: CGEventSource?

    init() {
        source = CGEventSource(stateID: .hidSystemState)
        // Never mute the real mouse and keyboard after posting an event.
        source?.localEventsSuppressionInterval = 0
    }

    private struct Mod {
        let flag: Modifiers
        let code: Int
        let mask: CGEventFlags
    }

    private static let mods: [Mod] = [
        Mod(flag: .control, code: KeyCode.control, mask: .maskControl),
        Mod(flag: .option, code: KeyCode.option, mask: .maskAlternate),
        Mod(flag: .shift, code: KeyCode.shift, mask: .maskShift),
        Mod(flag: .command, code: KeyCode.command, mask: .maskCommand),
    ]

    static func flags(_ m: Modifiers) -> CGEventFlags {
        var f: CGEventFlags = []
        for mod in mods where m.contains(mod.flag) { f.insert(mod.mask) }
        if m.contains(.function) { f.insert(.maskSecondaryFn) }
        return f
    }

    func postKey(_ code: Int, down: Bool, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { return }
        var f = flags
        if KeyCode.functionFlagKeys.contains(code) { f.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        e.flags = f
        e.post(tap: .cghidEventTap)
    }

    /// Presses the modifiers, then the key; they stay down until `release`.
    func press(_ combo: KeyCombo) {
        var flags: CGEventFlags = []
        for mod in Self.mods where combo.modifiers.contains(mod.flag) {
            flags.insert(mod.mask)
            postKey(mod.code, down: true, flags: flags)
        }
        if combo.modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        if let code = combo.keyCode { postKey(code, down: true, flags: flags) }
    }

    func release(_ combo: KeyCombo) {
        var flags = Self.flags(combo.modifiers)
        if let code = combo.keyCode { postKey(code, down: false, flags: flags) }
        flags.remove(.maskSecondaryFn)
        for mod in Self.mods.reversed() where combo.modifiers.contains(mod.flag) {
            flags.remove(mod.mask)
            postKey(mod.code, down: false, flags: flags)
        }
    }

    func tap(_ combo: KeyCombo) {
        press(combo)
        release(combo)
    }

    /// A key press carrying the modifier flags only (how system hot keys are triggered).
    func tapRaw(code: Int, flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { return }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    func type(_ text: String) {
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            i += chunk.count
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                e.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: Mouse

    private var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    func mouse(_ button: MouseButton, down: Bool, clickCount: Int = 1) {
        let type: CGEventType
        let cg: CGMouseButton
        switch button {
        case .left:
            type = down ? .leftMouseDown : .leftMouseUp
            cg = .left
        case .right:
            type = down ? .rightMouseDown : .rightMouseUp
            cg = .right
        default:
            type = down ? .otherMouseDown : .otherMouseUp
            cg = CGMouseButton(rawValue: UInt32(button.number)) ?? .center
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: cursor, mouseButton: cg) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.number))
        e.post(tap: .cghidEventTap)
    }

    func click(_ button: MouseButton, count: Int = 1) {
        for n in 1...max(count, 1) {
            mouse(button, down: true, clickCount: n)
            mouse(button, down: false, clickCount: n)
        }
    }

    /// Points per line for applications that only look at line deltas.
    private static let pointsPerLine = 12.0
    private var lineCarryX = 0.0, lineCarryY = 0.0

    /// Ends the pinch in progress; set by `PinchZoomer` while it pinches. Scrolling calls it
    /// first: apps take scrolling during a pinch as part of the pinch, and Chromium then
    /// ignores the scrolling once the pinch ends, until the wheel rests for half a second.
    var endPinch: (() -> Void)?

    private func endPinchBeforeScrolling() {
        guard let end = endPinch else { return }
        endPinch = nil
        end()
    }

    /// Continuous (trackpad-like) scrolling in points. Positive `dx` reveals content to
    /// the right, positive `dy` content below.
    func scroll(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        endPinchBeforeScrolling()
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(clamping: -dy), wheel2: Int32(clamping: -dx), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Line deltas add up to whole lines instead of one line per frame, for apps
        // that ignore precise deltas.
        lineCarryY += Double(-dy) / Self.pointsPerLine
        lineCarryX += Double(-dx) / Self.pointsPerLine
        let lineY = lineCarryY.rounded(.towardZero), lineX = lineCarryX.rounded(.towardZero)
        lineCarryY -= lineY
        lineCarryX -= lineX
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(lineY))
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(lineX))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(-dy) / Self.pointsPerLine)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(-dx) / Self.pointsPerLine)
        e.location = cursor
        e.post(tap: .cghidEventTap)
    }

    /// Classic line based scrolling (one wheel notch per unit).
    func scrollLines(dx: Int, dy: Int) {
        endPinchBeforeScrolling()
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                              wheel1: Int32(clamping: -dy), wheel2: Int32(clamping: -dx), wheel3: 0) else { return }
        e.location = cursor
        e.post(tap: .cghidEventTap)
    }

    // MARK: Pinch

    enum GesturePhase: Int64 {
        case began = 1, changed = 2, ended = 4
    }

    /// A trackpad pinch: a gesture event of the zoom kind. `magnification` is the change of
    /// scale since the last event (0.02 is 2 % bigger). Apps zoom smoothly around the pointer.
    /// (Private event fields: 55 type, 110 gesture kind, 113 magnification, 132 phase.)
    func pinch(_ magnification: Double, phase: GesturePhase) {
        guard let e = CGEvent(source: source) else { return }
        e.setIntegerValueField(CGEventField(rawValue: 55)!, value: 29)  // gesture
        e.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)  // zoom (IOHID event type)
        e.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase.rawValue)
        e.setDoubleValueField(CGEventField(rawValue: 113)!, value: magnification)
        e.location = cursor
        e.post(tap: .cghidEventTap)
    }

    // MARK: Media keys

    enum MediaKey: Int32 {
        case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
        case play = 16, next = 17, previous = 18, fast = 19, rewind = 20
    }

    func media(_ key: MediaKey, down: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
        let data1 = Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8))
        let e = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                   windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
        e?.cgEvent?.post(tap: .cghidEventTap)
    }

    func tapMedia(_ key: MediaKey) {
        media(key, down: true)
        media(key, down: false)
    }
}

/// System-wide hot keys (Mission Control, Spaces, screenshots...), triggered the way the
/// user has them configured. A disabled or unassigned hot key is bound to a spare key
/// combination for a moment, so it works even when the user turned it off.
@MainActor
final class SymbolicHotKeys {
    private typealias GetValue = @convention(c) (Int32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias IsEnabled = @convention(c) (Int32) -> Bool
    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32
    private typealias SetValue = @convention(c) (Int32, UInt16, UInt16, UInt32) -> Int32

    private let getValue: GetValue?
    private let isEnabled: IsEnabled?
    private let setEnabled: SetEnabled?
    private let setValue: SetValue?

    static let missionControl: Int32 = 32
    static let appWindows: Int32 = 33
    static let showDesktop: Int32 = 36
    static let previousInputSource: Int32 = 60
    static let spotlight: Int32 = 64
    static let spaceLeft: Int32 = 79
    static let spaceRight: Int32 = 81
    static let notificationCenter: Int32 = 163
    static let quickNote: Int32 = 190
    static let screenshotFile: Int32 = 28
    static let screenshotRegionFile: Int32 = 30
    static let screenshotOptions: Int32 = 184

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let handle, let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        getValue = sym("CGSGetSymbolicHotKeyValue", GetValue.self)
        isEnabled = sym("CGSIsSymbolicHotKeyEnabled", IsEnabled.self)
        setEnabled = sym("CGSSetSymbolicHotKeyEnabled", SetEnabled.self)
        setValue = sym("CGSSetSymbolicHotKeyValue", SetValue.self)
    }

    var available: Bool { getValue != nil && isEnabled != nil && setEnabled != nil && setValue != nil }

    /// Triggers a hot key. Returns false when the system offers no way to do it.
    func post(_ id: Int32, synth: InputSynth) -> Bool {
        guard let getValue, let isEnabled, let setEnabled, let setValue else { return false }
        var ke: UInt16 = 0, kc: UInt16 = 0, mods: UInt32 = 0
        let err = getValue(id, &ke, &kc, &mods)
        let enabled = isEnabled(id)
        let assigned = err == 0 && kc != 0xFFFF
        if assigned && enabled {
            synth.tapRaw(code: Int(kc), flags: CGEventFlags(rawValue: UInt64(mods)))
            return true
        }
        // F19 with every modifier: nobody uses that.
        let spareCode: UInt16 = 0x50
        let spareMods: UInt32 = 0x1E0000
        let code = assigned ? kc : spareCode
        let flags = assigned ? mods : spareMods
        if !assigned { _ = setValue(id, 0xFFFF, spareCode, spareMods) }
        if !enabled { _ = setEnabled(id, true) }
        // The window server needs a moment to pick up the change.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            MainActor.assumeIsolated {
                synth.tapRaw(code: Int(code), flags: CGEventFlags(rawValue: UInt64(flags)))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if !enabled { _ = setEnabled(id, false) }
                if !assigned { _ = setValue(id, ke, kc, mods) }
            }
        }
        return true
    }
}
