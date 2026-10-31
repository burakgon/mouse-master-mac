import Foundation

/// The whole persistent configuration, stored as JSON in
/// `~/Library/Application Support/Mouse Master/config.json`.
///
/// Hardware settings are optionals: nil means "leave whatever the device has",
/// so Mouse Master never changes anything the user did not touch.
public struct Config: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = Config.currentVersion
    public var general = General()
    public var devices: [String: DeviceConfig] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey { case version, general, devices }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, Config.currentVersion)
        general = c.value(.general, General())
        devices = c.value(.devices, [:])
    }
}

public struct General: Codable, Equatable, Sendable {
    public var showMenuBarIcon = true
    /// Battery percentage next to the menu bar icon.
    public var showBatteryInMenuBar = true
    /// On screen display when DPI or wheel mode change from the mouse.
    public var osd = true
    /// Low battery notifications.
    public var notifications = true
    public var lowBatteryPercent = 15
    /// Switch bindings automatically with the frontmost application.
    public var appProfiles = true
    /// Temporarily give every control its native behaviour back.
    public var paused = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case showMenuBarIcon, showBatteryInMenuBar, osd, notifications, lowBatteryPercent, appProfiles, paused
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = General()
        showMenuBarIcon = c.value(.showMenuBarIcon, d.showMenuBarIcon)
        showBatteryInMenuBar = c.value(.showBatteryInMenuBar, d.showBatteryInMenuBar)
        osd = c.value(.osd, d.osd)
        notifications = c.value(.notifications, d.notifications)
        lowBatteryPercent = c.value(.lowBatteryPercent, d.lowBatteryPercent)
        appProfiles = c.value(.appProfiles, d.appProfiles)
        paused = c.value(.paused, d.paused)
    }
}

public struct DeviceConfig: Codable, Equatable, Sendable {
    /// Last known name, for people reading the file.
    public var name = ""
    public var settings = DeviceSettings()
    /// Bindings used when no application profile matches.
    public var bindings = Bindings()
    /// Application specific overrides, checked in order.
    public var profiles: [AppProfile] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case name, settings, bindings, profiles }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.value(.name, "")
        settings = c.value(.settings, DeviceSettings())
        bindings = c.value(.bindings, Bindings())
        profiles = c.value(.profiles, [])
    }

    /// The profile for an application, if one is enabled for it.
    public func profile(for bundleID: String?) -> AppProfile? {
        guard let bundleID else { return nil }
        return profiles.first { $0.matches(bundleID) }
    }
}

public enum ScrollDirection: String, Codable, Sendable, CaseIterable {
    case natural, standard
}

public enum WheelModeSetting: String, Codable, Sendable {
    case ratchet
    case freeSpin = "free-spin"
}

public struct DeviceSettings: Codable, Equatable, Sendable {
    public var dpi: Int?
    /// Values cycled through by the DPI actions.
    public var dpiPresets: [Int] = []
    public var wheelMode: WheelModeSetting?
    /// Automatic switch to free spin when scrolling fast.
    public var smartShift: Bool?
    /// SmartShift sensitivity, 1 (very sensitive) ... 50 (almost never).
    public var smartShiftThreshold: Int?
    /// Ratchet force in percent, on devices with tunable torque.
    public var smartShiftTorque: Int?
    /// Smooth, high resolution scrolling with the main wheel (default on).
    public var smoothScroll: Bool?
    /// Scroll direction of this mouse; nil follows the system setting.
    public var scrollDirection: ScrollDirection?
    /// Smooth scrolling speed multiplier (default 1).
    public var scrollSpeed: Double?
    /// Smooth scrolling acceleration, 0 (linear) ... 2 (default 1).
    public var scrollAcceleration: Double?
    /// Swap the thumb wheel's direction.
    public var thumbwheelInvert: Bool?
    public var haptics: Bool?
    public var hapticsLevel: Int?

    public init() {}

    public var effectiveSmoothScroll: Bool { smoothScroll ?? true }
    public var effectiveScrollSpeed: Double { min(max(scrollSpeed ?? 1, 0.1), 5) }
    public var effectiveScrollAcceleration: Double { min(max(scrollAcceleration ?? 1, 0), 3) }

    public static let defaultDPIPresets = [800, 1600, 3200]

    enum CodingKeys: String, CodingKey {
        case dpi, dpiPresets, wheelMode, smartShift, smartShiftThreshold, smartShiftTorque, smoothScroll
        case scrollDirection, scrollSpeed, scrollAcceleration, thumbwheelInvert, haptics, hapticsLevel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dpi = c.optional(.dpi)
        dpiPresets = c.value(.dpiPresets, [])
        wheelMode = c.optional(.wheelMode)
        smartShift = c.optional(.smartShift)
        smartShiftThreshold = c.optional(.smartShiftThreshold)
        smartShiftTorque = c.optional(.smartShiftTorque)
        smoothScroll = c.optional(.smoothScroll)
        scrollDirection = c.optional(.scrollDirection)
        scrollSpeed = c.optional(.scrollSpeed)
        scrollAcceleration = c.optional(.scrollAcceleration)
        thumbwheelInvert = c.optional(.thumbwheelInvert)
        haptics = c.optional(.haptics)
        hapticsLevel = c.optional(.hapticsLevel)
    }
}

/// What the thumb wheel does.
public enum ThumbwheelBinding: Hashable, Sendable, Codable {
    /// macOS' own horizontal scrolling (the wheel is not diverted).
    case native
    /// Smooth horizontal scrolling at a custom speed.
    case scroll(speed: Double)
    /// Zoom in (right) and out (left).
    case zoom(speed: Double)
    /// One action per step to the left and another per step to the right.
    case actions(left: Action, right: Action, stepDegrees: Double)

    enum CodingKeys: String, CodingKey { case type, speed, left, right, stepDegrees }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "native", "default": self = .native
        case "scroll": self = .scroll(speed: c.value(.speed, 1))
        case "zoom": self = .zoom(speed: c.value(.speed, 1))
        case "actions":
            self = .actions(left: try c.decode(Action.self, forKey: .left),
                            right: try c.decode(Action.self, forKey: .right),
                            stepDegrees: c.value(.stepDegrees, 20))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown thumb wheel binding \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .native: try c.encode("native", forKey: .type)
        case .scroll(let s):
            try c.encode("scroll", forKey: .type)
            try c.encode(s, forKey: .speed)
        case .zoom(let s):
            try c.encode("zoom", forKey: .type)
            try c.encode(s, forKey: .speed)
        case .actions(let l, let r, let step):
            try c.encode("actions", forKey: .type)
            try c.encode(l, forKey: .left)
            try c.encode(r, forKey: .right)
            try c.encode(step, forKey: .stepDegrees)
        }
    }

    public var isDiverted: Bool { self != .native }
}

public struct Bindings: Codable, Equatable, Sendable {
    /// Button bindings keyed by control key (`gesture`, `middle`, `back`, `cid-01a0`...).
    public var buttons: [String: Action] = [:]
    public var thumbwheel: ThumbwheelBinding?
    /// A single tap on the thumb wheel (touch sensitive wheels).
    public var thumbwheelTap: Action?

    public init(buttons: [String: Action] = [:], thumbwheel: ThumbwheelBinding? = nil, thumbwheelTap: Action? = nil) {
        self.buttons = buttons
        self.thumbwheel = thumbwheel
        self.thumbwheelTap = thumbwheelTap
    }

    enum CodingKeys: String, CodingKey { case buttons, thumbwheel, thumbwheelTap }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        buttons = c.value(.buttons, [:])
        thumbwheel = c.optional(.thumbwheel)
        thumbwheelTap = c.optional(.thumbwheelTap)
    }

    /// Overlays `other` on top of `self`: entries in `other` win.
    public func overlay(_ other: Bindings) -> Bindings {
        var b = self
        for (k, v) in other.buttons { b.buttons[k] = v }
        if let t = other.thumbwheel { b.thumbwheel = t }
        if let t = other.thumbwheelTap { b.thumbwheelTap = t }
        return b
    }

    public var isEmpty: Bool { buttons.isEmpty && thumbwheel == nil && thumbwheelTap == nil }
}

public struct AppProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// Display name, usually the application's name.
    public var name: String
    /// Bundle identifiers of the applications this profile applies to.
    public var apps: [String]
    public var enabled = true
    public var bindings = Bindings()
    /// Optional pointer resolution while the application is frontmost.
    public var dpi: Int?

    public init(id: String = UUID().uuidString, name: String, apps: [String]) {
        self.id = id
        self.name = name
        self.apps = apps
    }

    public func matches(_ bundleID: String) -> Bool {
        enabled && apps.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    enum CodingKeys: String, CodingKey { case id, name, apps, enabled, bindings, dpi }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID().uuidString)
        name = c.value(.name, "")
        apps = c.value(.apps, [])
        enabled = c.value(.enabled, true)
        bindings = c.value(.bindings, Bindings())
        dpi = c.optional(.dpi)
    }
}

public extension Config {
    static func load(from url: URL) throws -> Config {
        guard let data = try? Data(contentsOf: url) else { return Config() }
        return try JSONDecoder().decode(Config.self, from: data)
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
