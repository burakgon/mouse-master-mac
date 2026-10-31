import Foundation

/// Everything the settings app shows, pushed by the agent whenever something changes.
public struct AgentState: Codable, Equatable, Sendable {
    public var agentVersion: String
    public var devices: [DeviceSnapshot]
    public var config: Config
    public var permissions: Permissions
    public var activeApp: ActiveApp?
    public var conflicts: [ConflictInfo]
    /// The system setting for trackpads and mice; mice can override it per device.
    public var systemNaturalScrolling: Bool

    public init(agentVersion: String, devices: [DeviceSnapshot], config: Config, permissions: Permissions,
                activeApp: ActiveApp?, conflicts: [ConflictInfo], systemNaturalScrolling: Bool) {
        self.agentVersion = agentVersion
        self.devices = devices
        self.config = config
        self.permissions = permissions
        self.activeApp = activeApp
        self.conflicts = conflicts
        self.systemNaturalScrolling = systemNaturalScrolling
    }
}

public struct Permissions: Codable, Equatable, Sendable {
    /// Needed to perform actions (posting keyboard, mouse and scroll events).
    public var accessibility: Bool
    /// Only needed when macOS refuses to open a device without it.
    public var inputMonitoringNeeded: Bool
    public var inputMonitoring: Bool

    public init(accessibility: Bool, inputMonitoringNeeded: Bool, inputMonitoring: Bool) {
        self.accessibility = accessibility
        self.inputMonitoringNeeded = inputMonitoringNeeded
        self.inputMonitoring = inputMonitoring
    }
}

public struct ActiveApp: Codable, Equatable, Sendable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Another program that takes over the mouse too.
public struct ConflictInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var pid: Int32

    public init(id: String, name: String, pid: Int32) {
        self.id = id
        self.name = name
        self.pid = pid
    }
}

public struct DeviceSnapshot: Codable, Equatable, Identifiable, Sendable {
    /// `<model id>-<unit id>`, the same over Bluetooth and receivers.
    public var id: String
    public var name: String
    public var kind: String
    public var modelID: String
    public var unitID: String
    public var serial: String?
    public var firmware: [FirmwareInfo]
    public var protocolVersion: String
    public var connection: ConnectionInfo
    public var online: Bool
    /// Settings are being read or written.
    public var busy: Bool
    public var battery: BatteryInfo?
    public var capabilities: Capabilities
    public var state: HardwareState
    /// Controls that can be remapped.
    public var controls: [ControlInfo]
    public var features: [FeatureInfo]
    /// Id of the application profile in effect.
    public var activeProfile: String?
    public var error: String?

    public init(id: String, name: String, kind: String, modelID: String, unitID: String, serial: String?,
                firmware: [FirmwareInfo], protocolVersion: String, connection: ConnectionInfo, online: Bool,
                busy: Bool, battery: BatteryInfo?, capabilities: Capabilities, state: HardwareState,
                controls: [ControlInfo], features: [FeatureInfo], activeProfile: String?, error: String?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.modelID = modelID
        self.unitID = unitID
        self.serial = serial
        self.firmware = firmware
        self.protocolVersion = protocolVersion
        self.connection = connection
        self.online = online
        self.busy = busy
        self.battery = battery
        self.capabilities = capabilities
        self.state = state
        self.controls = controls
        self.features = features
        self.activeProfile = activeProfile
        self.error = error
    }

    public func control(_ key: String) -> ControlInfo? { controls.first { $0.key == key } }
}

public struct ConnectionInfo: Codable, Equatable, Sendable {
    /// "bluetooth", "usb" or "receiver".
    public var transport: String
    public var receiverName: String?
    public var slot: Int?

    public init(transport: String, receiverName: String? = nil, slot: Int? = nil) {
        self.transport = transport
        self.receiverName = receiverName
        self.slot = slot
    }

    public var label: String {
        switch transport {
        case "bluetooth": return "Bluetooth"
        case "usb": return "USB"
        default: return receiverName ?? "Receiver"
        }
    }
}

public struct BatteryInfo: Codable, Equatable, Sendable {
    public var percent: Int?
    /// "critical", "low", "good" or "full".
    public var level: String?
    public var charging: Bool
    public var full: Bool

    public init(percent: Int?, level: String?, charging: Bool, full: Bool) {
        self.percent = percent
        self.level = level
        self.charging = charging
        self.full = full
    }
}

public struct FirmwareInfo: Codable, Equatable, Sendable {
    public var kind: Int
    public var name: String
    public var version: String

    public init(kind: Int, name: String, version: String) {
        self.kind = kind
        self.name = name
        self.version = version
    }

    public var kindLabel: String {
        switch kind {
        case 0: return "Firmware"
        case 1: return "Bootloader"
        case 2: return "Hardware"
        case 5: return "Radio"
        default: return "Component \(kind)"
        }
    }
}

public struct FeatureInfo: Codable, Equatable, Sendable {
    public var id: Int
    public var name: String
    public var version: Int
    public var hidden: Bool

    public init(id: Int, name: String, version: Int, hidden: Bool) {
        self.id = id
        self.name = name
        self.version = version
        self.hidden = hidden
    }
}

public struct ControlInfo: Codable, Equatable, Identifiable, Sendable {
    public var cid: Int
    public var key: String
    public var name: String
    public var role: String
    /// Reports pointer motion while held (gestures).
    public var gestures: Bool

    public var id: String { key }

    public init(cid: Int, key: String, name: String, role: String, gestures: Bool) {
        self.cid = cid
        self.key = key
        self.name = name
        self.role = role
        self.gestures = gestures
    }
}

public struct DPICaps: Codable, Equatable, Sendable {
    public var min: Int
    public var max: Int
    public var step: Int?
    public var values: [Int]?
    public var defaultValue: Int

    public init(min: Int, max: Int, step: Int?, values: [Int]?, defaultValue: Int) {
        self.min = min
        self.max = max
        self.step = step
        self.values = values
        self.defaultValue = defaultValue
    }

    public func snap(_ v: Int) -> Int {
        if let values, !values.isEmpty { return values.min { abs($0 - v) < abs($1 - v) } ?? v }
        let s = Swift.max(step ?? 1, 1)
        let c = Swift.min(Swift.max(v, self.min), self.max)
        return Swift.min(self.min + ((c - self.min + s / 2) / s) * s, self.max)
    }
}

public struct Capabilities: Codable, Equatable, Sendable {
    public var dpi: DPICaps?
    public var smartShift: Bool
    public var smartShiftTorque: Bool
    public var smartShiftDefaultThreshold: Int?
    public var hiresWheel: Bool
    public var wheelMultiplier: Int?
    public var thumbwheel: Bool
    public var thumbwheelTouch: Bool
    public var thumbwheelTap: Bool
    public var hosts: Int?
    public var hostNamesWritable: Bool
    public var haptics: Bool
    public var gestures: Bool
    public var battery: Bool

    public init() {
        smartShift = false
        smartShiftTorque = false
        hiresWheel = false
        thumbwheel = false
        thumbwheelTouch = false
        thumbwheelTap = false
        hostNamesWritable = false
        haptics = false
        gestures = false
        battery = false
    }
}

public struct HostEntry: Codable, Equatable, Identifiable, Sendable {
    public var index: Int
    public var paired: Bool
    public var bus: String
    public var name: String
    public var current: Bool

    public var id: Int { index }

    public init(index: Int, paired: Bool, bus: String, name: String, current: Bool) {
        self.index = index
        self.paired = paired
        self.bus = bus
        self.name = name
        self.current = current
    }
}

/// What the device reports right now.
public struct HardwareState: Codable, Equatable, Sendable {
    public var dpi: Int?
    /// "ratchet" or "free-spin".
    public var wheelMode: String?
    public var smartShiftThreshold: Int?
    public var smartShiftTorque: Int?
    public var currentHost: Int?
    public var hosts: [HostEntry]
    public var haptics: Bool?
    public var hapticsLevel: Int?
    /// The main wheel is handled by Mouse Master (smooth scrolling).
    public var smoothScrolling: Bool
    /// The thumb wheel is handled by Mouse Master.
    public var thumbwheelDiverted: Bool

    public init() {
        hosts = []
        smoothScrolling = false
        thumbwheelDiverted = false
    }

    public var smartShiftEnabled: Bool? {
        guard let t = smartShiftThreshold else { return nil }
        return t != 0 && t != 255
    }
}
