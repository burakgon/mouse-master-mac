import Foundation

// MARK: - Device identity (0x0003, 0x0005, 0x0007)

public enum DeviceKind: String, Codable, Sendable {
    case keyboard, remoteControl = "remote-control", numpad, mouse, touchpad, trackball, presenter, receiver
    case headset, webcam, steeringWheel = "steering-wheel", joystick, gamepad, dock, speaker, microphone, unknown

    public init(hidpp20 t: UInt8) {
        let all: [DeviceKind] = [.keyboard, .remoteControl, .numpad, .mouse, .touchpad, .trackball, .presenter,
                                 .receiver, .headset, .webcam, .steeringWheel, .joystick, .gamepad, .dock,
                                 .speaker, .microphone]
        self = Int(t) < all.count ? all[Int(t)] : .unknown
    }

    public init(hidpp10 kind: UInt8) {
        switch kind & 0x0F {
        case 0x01: self = .keyboard
        case 0x02: self = .mouse
        case 0x03: self = .numpad
        case 0x04: self = .presenter
        case 0x07: self = .remoteControl
        case 0x08: self = .trackball
        case 0x09: self = .touchpad
        case 0x0B: self = .gamepad
        case 0x0C: self = .joystick
        case 0x0D: self = .headset
        default: self = .unknown
        }
    }

    public var isPointer: Bool { self == .mouse || self == .trackball || self == .touchpad }
}

public struct FirmwareEntity: Codable, Equatable, Sendable {
    /// 0 main application, 1 bootloader, 2 hardware, 5 radio stack...
    public var kind: UInt8
    public var name: String
    public var version: String
    public var build: UInt16
}

public struct DeviceIdentity: Codable, Equatable, Sendable {
    public var unitID: String
    public var modelIDs: [UInt16]
    /// The most specific product id: Bluetooth LE, Bluetooth, receiver, USB.
    public var primaryModelID: UInt16?
    public var extendedModelID: UInt8
    public var serialSupported: Bool
    public var firmware: [FirmwareEntity]
}

public extension HIDPPDevice {
    /// Unit id, model ids and firmware versions (feature 0x0003).
    func readIdentity() async throws -> DeviceIdentity {
        let info = try await call(FeatureID.deviceFirmwareVersion, 0)
        let count = info.u8(0)
        let unitID = String(format: "%08X", info.u32(1))
        let transport = info.u16(5)
        var ids: [(bit: UInt16, pid: UInt16)] = []
        var offset = 7
        // Bits: 0 Bluetooth, 1 BLE, 2 receiver (eQuad), 3 USB.
        for bit: UInt16 in [0x01, 0x02, 0x04, 0x08] where transport & bit != 0 {
            let pid = info.u16(offset)
            if pid != 0 { ids.append((bit, pid)) }
            offset += 2
        }
        let preference: [UInt16] = [0x02, 0x01, 0x04, 0x08]
        let primary = preference.compactMap { b in ids.first { $0.bit == b }?.pid }.first
        var firmware: [FirmwareEntity] = []
        for i in 0..<count {
            let fw = try await call(FeatureID.deviceFirmwareVersion, 1, [i])
            let kind = fw.u8(0) & 0x0F
            let name = String(fw.slice(1, 3).filter { $0 >= 0x21 && $0 < 0x7F }.map { Character(UnicodeScalar($0)) })
            let (major, minor, build) = (fw.u8(4), fw.u8(5), fw.u16(6))
            // BCD encoded: hexadecimal formatting yields the decimal digits.
            let version: String
            if kind == 2 {
                version = "\(fw.u8(1))"
            } else if build != 0 {
                version = String(format: "%02X.%02X.B%04X", major, minor, build)
            } else {
                version = String(format: "%02X.%02X", major, minor)
            }
            firmware.append(FirmwareEntity(kind: kind, name: name, version: version, build: build))
        }
        return DeviceIdentity(unitID: unitID, modelIDs: ids.map(\.pid), primaryModelID: primary,
                              extendedModelID: info.u8(13), serialSupported: info.u8(14) & 0x01 != 0,
                              firmware: firmware)
    }

    /// Serial number (feature 0x0003 v4+).
    func readSerialNumber() async throws -> String {
        let r = try await call(FeatureID.deviceFirmwareVersion, 2)
        return String(r.slice(0, 12).filter { $0 >= 0x21 && $0 < 0x7F }.map { Character(UnicodeScalar($0)) })
    }

    /// Marketing name (feature 0x0005).
    func readName() async throws -> String {
        let length = Int(try await call(FeatureID.deviceName, 0).u8(0))
        var bytes: [UInt8] = []
        while bytes.count < length {
            let chunk = try await call(FeatureID.deviceName, 1, [UInt8(bytes.count)])
            let take = min(length - bytes.count, chunk.count)
            if take == 0 { break }
            bytes += chunk.slice(0, take)
        }
        return String(decoding: bytes.filter { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    func readKind() async throws -> DeviceKind {
        DeviceKind(hidpp20: try await call(FeatureID.deviceName, 2).u8(0))
    }
}

// MARK: - Battery (0x1004, 0x1000, 0x1001)

public struct Battery: Codable, Equatable, Sendable {
    public enum Level: String, Codable, Sendable { case critical, low, good, full }
    public enum State: String, Codable, Sendable { case discharging, charging, chargingSlow = "charging-slow", full, error, unknown }

    public var percent: UInt8?
    public var level: Level?
    public var state: State
    public var externalPower: Bool

    public var isCharging: Bool { state == .charging || state == .chargingSlow }

    /// Best effort percentage, falling back to the coarse level.
    public var approximatePercent: Int? {
        if let p = percent { return Int(p) }
        switch level {
        case .critical: return 5
        case .low: return 20
        case .good: return 60
        case .full: return 95
        case nil: return nil
        }
    }

    public static func decodeUnified(_ p: Params) -> Battery {
        let bits = p.u8(1)
        let level: Level? = bits & 0x08 != 0 ? .full : bits & 0x04 != 0 ? .good : bits & 0x02 != 0 ? .low : bits & 0x01 != 0 ? .critical : nil
        let state: State
        switch p.u8(2) {
        case 0: state = .discharging
        case 1: state = .charging
        case 2: state = .chargingSlow
        case 3: state = .full
        case 4: state = .error
        default: state = .unknown
        }
        let percent: UInt8? = p.u8(0) == 0 ? nil : min(p.u8(0), 100)
        return Battery(percent: percent, level: level, state: state, externalPower: p.u8(3) != 0)
    }

    public static func decodeStatus(_ p: Params) -> Battery {
        let state: State
        switch p.u8(2) {
        case 0: state = .discharging
        case 1, 2: state = .charging
        case 3: state = .full
        case 4: state = .chargingSlow
        case 5, 6: state = .error
        default: state = .unknown
        }
        let percent: UInt8? = p.u8(0) == 0 ? nil : min(p.u8(0), 100)
        return Battery(percent: percent, level: nil, state: state,
                       externalPower: state == .charging || state == .chargingSlow || state == .full)
    }

    public static func decodeVoltage(_ p: Params) -> Battery {
        let mv = p.u16(0)
        let flags = p.u8(2)
        let charging = flags & 0x80 != 0
        var state: State = .discharging
        if charging {
            switch flags & 0x07 {
            case 1: state = .full
            case 0: state = flags & 0x10 != 0 ? .chargingSlow : .charging
            default: state = .error
            }
        }
        return Battery(percent: voltageToPercent(mv), level: nil, state: state, externalPower: charging)
    }

    /// Approximates the state of charge of a single cell Li-ion battery.
    public static func voltageToPercent(_ mv: UInt16) -> UInt8 {
        let curve: [(UInt16, UInt8)] = [(4186, 100), (4067, 90), (3989, 80), (3922, 70), (3859, 60), (3811, 50),
                                        (3778, 40), (3751, 30), (3717, 20), (3671, 10), (3646, 5)]
        if mv >= curve[0].0 { return 100 }
        for i in 0..<(curve.count - 1) {
            let (hiV, hiP) = curve[i]
            let (loV, loP) = curve[i + 1]
            if mv >= loV {
                let span = UInt32(hiV - loV)
                let pos = UInt32(mv - loV)
                return loP + UInt8(UInt32(hiP - loP) * pos / span)
            }
        }
        return mv > 3500 ? 2 : 0
    }

    /// Decodes a battery event (function 0 of any battery feature).
    public static func decodeEvent(feature: UInt16, _ p: Params) -> Battery? {
        switch feature {
        case FeatureID.unifiedBattery: return decodeUnified(p)
        case FeatureID.batteryStatus: return decodeStatus(p)
        case FeatureID.batteryVoltage: return decodeVoltage(p)
        default: return nil
        }
    }
}

public extension HIDPPDevice {
    var batteryFeature: UInt16? {
        [FeatureID.unifiedBattery, FeatureID.batteryStatus, FeatureID.batteryVoltage].first { has($0) }
    }

    func readBattery() async throws -> Battery {
        switch batteryFeature {
        case FeatureID.unifiedBattery?: return Battery.decodeUnified(try await call(FeatureID.unifiedBattery, 1))
        case FeatureID.batteryStatus?: return Battery.decodeStatus(try await call(FeatureID.batteryStatus, 0))
        case FeatureID.batteryVoltage?: return Battery.decodeVoltage(try await call(FeatureID.batteryVoltage, 0))
        default: throw HIDPPError.featureNotSupported(FeatureID.unifiedBattery)
        }
    }
}

// MARK: - Sensor resolution (0x2201, 0x2202)

public enum DPIRange: Codable, Equatable, Sendable {
    case range(min: Int, max: Int, step: Int)
    case list([Int])

    public var minimum: Int {
        switch self {
        case .range(let lo, _, _): return lo
        case .list(let v): return v.first ?? 0
        }
    }

    public var maximum: Int {
        switch self {
        case .range(_, let hi, _): return hi
        case .list(let v): return v.last ?? 0
        }
    }

    /// Snaps a value to the closest supported one.
    public func snap(_ dpi: Int) -> Int {
        switch self {
        case .range(let lo, let hi, let step):
            let c = Swift.min(Swift.max(dpi, lo), hi)
            let s = Swift.max(step, 1)
            let steps = (c - lo + s / 2) / s
            return Swift.min(lo + steps * s, hi)
        case .list(let values):
            return values.min { abs($0 - dpi) < abs($1 - dpi) } ?? dpi
        }
    }

    /// Parses the packed list shared by 0x2201 and 0x2202: big endian values, where
    /// a value with the top three bits set is a step between its neighbours; 0 ends the list.
    public static func parse(_ bytes: [UInt8]) -> DPIRange? {
        var values: [Int] = []
        var range: (Int, Int, Int)?
        var i = 0
        func u16(_ k: Int) -> Int? {
            guard k + 1 < bytes.count else { return nil }
            return Int(bytes[k]) << 8 | Int(bytes[k + 1])
        }
        while let v = u16(i), v != 0 {
            if v >> 13 == 0b111 {
                let step = v & 0x1FFF
                guard let lo = values.last, let hi = u16(i + 2), hi > lo, step > 0 else { return nil }
                if values.count == 1 && range == nil {
                    range = (lo, hi, step)
                    values.removeAll()
                } else {
                    var x = lo + step
                    while x <= hi { values.append(x); x += step }
                }
                i += 4
            } else {
                values.append(v)
                i += 2
            }
        }
        switch (range, values.isEmpty) {
        case (let r?, true): return .range(min: r.0, max: r.1, step: r.2)
        case (let r?, false):
            var all = Array(stride(from: r.0, through: r.1, by: r.2)) + values
            all = Array(Set(all)).sorted()
            return .list(all)
        case (nil, false): return .list(values)
        case (nil, true): return nil
        }
    }
}

public struct DPIInfo: Codable, Equatable, Sendable {
    public var feature: UInt16
    public var range: DPIRange
    public var current: Int
    public var defaultValue: Int
}

public extension HIDPPDevice {
    var dpiFeature: UInt16? {
        [FeatureID.extendedAdjustableDPI, FeatureID.adjustableDPI].first { has($0) }
    }

    func readDPI() async throws -> DPIInfo {
        switch dpiFeature {
        case FeatureID.adjustableDPI?:
            let list = try await call(FeatureID.adjustableDPI, 1, [0])
            guard let range = DPIRange.parse(list.slice(1, list.count - 1)) else {
                throw HIDPPError.protocolError("invalid DPI list")
            }
            let cur = try await call(FeatureID.adjustableDPI, 2, [0])
            let current = Int(cur.u16(1)), def = Int(cur.u16(3))
            return DPIInfo(feature: FeatureID.adjustableDPI, range: range, current: current == 0 ? def : current, defaultValue: def)
        case FeatureID.extendedAdjustableDPI?:
            var bytes: [UInt8] = []
            for page: UInt8 in 0..<16 {
                let p = try await call(FeatureID.extendedAdjustableDPI, 2, [0, 0, page])
                let payload = p.slice(3, p.count - 3)
                bytes += payload
                if payload.count < 2 || payload.suffix(2) == [0, 0] { break }
            }
            guard let range = DPIRange.parse(bytes) else { throw HIDPPError.protocolError("invalid DPI ranges") }
            let cur = try await call(FeatureID.extendedAdjustableDPI, 5, [0])
            let current = Int(cur.u16(1)), def = Int(cur.u16(3))
            return DPIInfo(feature: FeatureID.extendedAdjustableDPI, range: range, current: current == 0 ? def : current, defaultValue: def)
        default:
            throw HIDPPError.featureNotSupported(FeatureID.adjustableDPI)
        }
    }

    func setDPI(_ dpi: Int) async throws {
        let hi = UInt8((dpi >> 8) & 0xFF), lo = UInt8(dpi & 0xFF)
        switch dpiFeature {
        case FeatureID.adjustableDPI?:
            try await call(FeatureID.adjustableDPI, 3, [0, hi, lo])
        case FeatureID.extendedAdjustableDPI?:
            let cur = try await call(FeatureID.extendedAdjustableDPI, 5, [0])
            try await call(FeatureID.extendedAdjustableDPI, 6, [0, hi, lo, hi, lo, cur.u8(9)])
        default:
            throw HIDPPError.featureNotSupported(FeatureID.adjustableDPI)
        }
    }
}

// MARK: - SmartShift (0x2110, 0x2111)

public enum WheelMode: String, Codable, Sendable {
    case freeSpin = "free-spin"
    case ratchet
}

public struct SmartShiftState: Codable, Equatable, Sendable {
    /// Auto disengage value meaning "never switch to free spin automatically".
    public static let alwaysRatchet: UInt8 = 0xFF

    public var feature: UInt16
    public var mode: WheelMode
    /// Scroll speed above which the wheel switches to free spin (1...254), or 0xFF when off.
    public var autoDisengage: UInt8
    public var defaultAutoDisengage: UInt8
    public var torque: UInt8?
    public var defaultTorque: UInt8?

    public var enabled: Bool { autoDisengage != Self.alwaysRatchet && autoDisengage != 0 }
}

public extension HIDPPDevice {
    var smartShiftFeature: UInt16? {
        [FeatureID.smartShiftEnhanced, FeatureID.smartShift].first { has($0) }
    }

    func readSmartShift() async throws -> SmartShiftState {
        switch smartShiftFeature {
        case FeatureID.smartShift?:
            let p = try await call(FeatureID.smartShift, 0)
            return SmartShiftState(feature: FeatureID.smartShift, mode: p.u8(0) == 1 ? .freeSpin : .ratchet,
                                   autoDisengage: p.u8(1), defaultAutoDisengage: p.u8(2), torque: nil, defaultTorque: nil)
        case FeatureID.smartShiftEnhanced?:
            let caps = try await call(FeatureID.smartShiftEnhanced, 0)
            let tunable = caps.u8(0) & 0x01 != 0
            let p = try await call(FeatureID.smartShiftEnhanced, 1)
            return SmartShiftState(feature: FeatureID.smartShiftEnhanced, mode: p.u8(0) == 1 ? .freeSpin : .ratchet,
                                   autoDisengage: p.u8(1), defaultAutoDisengage: caps.u8(1),
                                   torque: tunable ? p.u8(2) : nil, defaultTorque: tunable ? caps.u8(2) : nil)
        default:
            throw HIDPPError.featureNotSupported(FeatureID.smartShift)
        }
    }

    /// Changes the wheel configuration; nil leaves a value unchanged.
    func writeSmartShift(mode: WheelMode?, autoDisengage: UInt8?, torque: UInt8?) async throws {
        var modeByte: UInt8 = mode == nil ? 0 : (mode == .freeSpin ? 1 : 2)
        let disengage = autoDisengage ?? 0
        switch smartShiftFeature {
        case FeatureID.smartShift?:
            try await call(FeatureID.smartShift, 1, [modeByte, disengage, 0])
        case FeatureID.smartShiftEnhanced?:
            // Some devices only apply a new torque together with the mode.
            if modeByte == 0 && torque != nil {
                modeByte = try await call(FeatureID.smartShiftEnhanced, 1).u8(0)
            }
            try await call(FeatureID.smartShiftEnhanced, 2, [modeByte, disengage, torque ?? 0])
        default:
            throw HIDPPError.featureNotSupported(FeatureID.smartShift)
        }
    }
}

// MARK: - High resolution wheel (0x2121)

public struct WheelCapability: Codable, Equatable, Sendable {
    /// High resolution steps per ratchet notch.
    public var multiplier: Int
    public var hasRatchetSwitch: Bool
    public var hasInvert: Bool
}

public struct WheelReporting: Codable, Equatable, Sendable {
    /// Wheel movement reported as HID++ events instead of HID input.
    public var diverted: Bool
    public var hiRes: Bool
    /// Direction inverted by the device.
    public var inverted: Bool

    public init(diverted: Bool, hiRes: Bool, inverted: Bool) {
        self.diverted = diverted
        self.hiRes = hiRes
        self.inverted = inverted
    }

    init(byte b: UInt8) {
        diverted = b & 0x01 != 0
        hiRes = b & 0x02 != 0
        inverted = b & 0x04 != 0
    }

    var byte: UInt8 { (diverted ? 1 : 0) | (hiRes ? 2 : 0) | (inverted ? 4 : 0) }
}

public enum WheelEvent: Equatable, Sendable {
    /// Wheel movement while diverted; positive rolls away from the user.
    case movement(hiRes: Bool, periods: UInt8, delta: Int16)
    /// The ratchet engaged (true) or released (false).
    case ratchet(Bool)

    public static func decode(function: UInt8, _ p: Params) -> WheelEvent? {
        switch function {
        case 0: return .movement(hiRes: p.u8(0) & 0x10 != 0, periods: p.u8(0) & 0x0F, delta: p.i16(1))
        case 1 where p.u8(0) < 2: return .ratchet(p.u8(0) == 1)
        default: return nil
        }
    }
}

public extension HIDPPDevice {
    func wheelCapability() async throws -> WheelCapability {
        let p = try await call(FeatureID.hiresWheel, 0)
        return WheelCapability(multiplier: max(1, Int(p.u8(0))), hasRatchetSwitch: p.u8(1) & 0x04 != 0,
                               hasInvert: p.u8(1) & 0x08 != 0)
    }

    func wheelReporting() async throws -> WheelReporting {
        WheelReporting(byte: try await call(FeatureID.hiresWheel, 1).u8(0))
    }

    @discardableResult
    func setWheelReporting(_ mode: WheelReporting) async throws -> WheelReporting {
        WheelReporting(byte: try await call(FeatureID.hiresWheel, 2, [mode.byte]).u8(0))
    }

    func ratchetEngaged() async throws -> Bool {
        try await call(FeatureID.hiresWheel, 3).u8(0) & 0x01 != 0
    }
}

// MARK: - Thumb wheel (0x2150)

public struct ThumbwheelInfo: Codable, Equatable, Sendable {
    /// Increments per full turn reported as native HID scrolling.
    public var nativeResolution: Int
    /// Increments per full turn reported when diverted.
    public var divertedResolution: Int
    /// +1 when a positive rotation means "right", -1 otherwise.
    public var defaultDirection: Int
    public var hasTouch: Bool
    public var hasProximity: Bool
    public var hasSingleTap: Bool
}

public struct ThumbwheelStatus: Codable, Equatable, Sendable {
    public var diverted: Bool
    public var inverted: Bool
}

public struct ThumbwheelEvent: Equatable, Sendable {
    public enum Status: Sendable { case inactive, start, active, stop }
    /// Rotation in diverted resolution units, in the device's native direction.
    public var rotation: Int16
    public var status: Status
    public var touch: Bool
    public var proximity: Bool
    public var singleTap: Bool

    public init(rotation: Int16, status: Status, touch: Bool = false, proximity: Bool = false, singleTap: Bool = false) {
        self.rotation = rotation
        self.status = status
        self.touch = touch
        self.proximity = proximity
        self.singleTap = singleTap
    }

    public static func decode(function: UInt8, _ p: Params) -> ThumbwheelEvent? {
        guard function == 0 else { return nil }
        let status: Status
        switch p.u8(4) {
        case 1: status = .start
        case 2: status = .active
        case 3: status = .stop
        default: status = .inactive
        }
        let flags = p.u8(5)
        return ThumbwheelEvent(rotation: p.i16(0), status: status, touch: flags & 0x02 != 0,
                               proximity: flags & 0x04 != 0, singleTap: flags & 0x08 != 0)
    }
}

public extension HIDPPDevice {
    func thumbwheelInfo() async throws -> ThumbwheelInfo {
        let p = try await call(FeatureID.thumbWheel, 0)
        let caps = p.u8(5)
        return ThumbwheelInfo(nativeResolution: Int(p.u16(0)), divertedResolution: max(1, Int(p.u16(2))),
                              defaultDirection: p.u8(4) != 0 ? 1 : -1, hasTouch: caps & 0x02 != 0,
                              hasProximity: caps & 0x04 != 0, hasSingleTap: caps & 0x08 != 0)
    }

    func thumbwheelStatus() async throws -> ThumbwheelStatus {
        let p = try await call(FeatureID.thumbWheel, 1)
        return ThumbwheelStatus(diverted: p.u8(0) & 0x01 != 0, inverted: p.u8(1) & 0x01 != 0)
    }

    func setThumbwheelReporting(diverted: Bool, inverted: Bool) async throws {
        try await call(FeatureID.thumbWheel, 2, [diverted ? 1 : 0, inverted ? 1 : 0])
    }
}

// MARK: - Reprogrammable controls (0x1B04)

public struct ControlFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let mouseButton = ControlFlags(rawValue: 0x0001)
    public static let fnKey = ControlFlags(rawValue: 0x0002)
    public static let reprogrammable = ControlFlags(rawValue: 0x0010)
    public static let divertable = ControlFlags(rawValue: 0x0020)
    public static let persistentlyDivertable = ControlFlags(rawValue: 0x0040)
    public static let virtual = ControlFlags(rawValue: 0x0080)
    public static let rawXY = ControlFlags(rawValue: 0x0100)
    public static let forceRawXY = ControlFlags(rawValue: 0x0200)
    public static let analyticsKeyEvents = ControlFlags(rawValue: 0x0400)
    public static let rawWheel = ControlFlags(rawValue: 0x0800)
}

public struct ReportingFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let diverted = ReportingFlags(rawValue: 0x0001)
    public static let persistentlyDiverted = ReportingFlags(rawValue: 0x0004)
    public static let rawXYDiverted = ReportingFlags(rawValue: 0x0010)
    public static let forceRawXYDiverted = ReportingFlags(rawValue: 0x0040)
    public static let analyticsKeyEvents = ReportingFlags(rawValue: 0x0100)
}

public struct ReprogControl: Codable, Equatable, Sendable {
    public var cid: UInt16
    public var task: UInt16
    public var flags: ControlFlags
    public var group: UInt8
    public var groupMask: UInt8

    public var isDivertable: Bool { flags.contains(.divertable) }
    public var supportsRawXY: Bool { flags.contains(.rawXY) }
    public var isVirtual: Bool { flags.contains(.virtual) }
    public var supportsAnalytics: Bool { flags.contains(.analyticsKeyEvents) }
}

public enum ReprogEvent: Equatable, Sendable {
    /// The set of diverted controls currently held down (up to four).
    case divertedButtons([UInt16])
    /// Pointer motion while a raw XY diverted control is held.
    case rawXY(dx: Int16, dy: Int16)
    /// Analytics key events: (control, pressed).
    case analytics([(UInt16, Bool)])

    public static func == (a: ReprogEvent, b: ReprogEvent) -> Bool {
        switch (a, b) {
        case (.divertedButtons(let x), .divertedButtons(let y)): return x == y
        case (.rawXY(let a1, let a2), .rawXY(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.analytics(let x), .analytics(let y)): return x.map(\.0) == y.map(\.0) && x.map(\.1) == y.map(\.1)
        default: return false
        }
    }

    public static func decode(function: UInt8, _ p: Params) -> ReprogEvent? {
        switch function {
        case 0: return .divertedButtons((0..<4).map { p.u16($0 * 2) }.filter { $0 != 0 })
        case 1: return .rawXY(dx: p.i16(0), dy: p.i16(2))
        case 2:
            var events: [(UInt16, Bool)] = []
            for i in 0..<5 {
                let cid = p.u16(i * 3)
                if cid != 0 { events.append((cid, p.u8(i * 3 + 2) & 0x01 != 0)) }
            }
            return .analytics(events)
        default: return nil
        }
    }
}

public extension HIDPPDevice {
    func reprogControls() async throws -> [ReprogControl] {
        let n = try await call(FeatureID.reprogControlsV4, 0).u8(0)
        var out: [ReprogControl] = []
        for i in 0..<n {
            let p = try await call(FeatureID.reprogControlsV4, 1, [i])
            out.append(ReprogControl(cid: p.u16(0), task: p.u16(2),
                                     flags: ControlFlags(rawValue: UInt16(p.u8(4)) | UInt16(p.u8(8)) << 8),
                                     group: p.u8(6), groupMask: p.u8(7)))
        }
        return out
    }

    func controlReporting(_ cid: UInt16) async throws -> ReportingFlags {
        let p = try await call(FeatureID.reprogControlsV4, 2, [UInt8(cid >> 8), UInt8(cid & 0xFF)])
        return ReportingFlags(rawValue: UInt16(p.u8(2)) | UInt16(p.u8(5)) << 8)
    }

    /// Diverts a control (and its raw pointer motion) or gives it back. Only the first
    /// five bytes are sent: older firmware misbehaves when given the v4 extension byte.
    func setControlReporting(_ cid: UInt16, divert: Bool, rawXY: Bool?) async throws {
        var bits: UInt8 = 0x02 | (divert ? 0x01 : 0)
        if let rawXY { bits |= 0x20 | (rawXY ? 0x10 : 0) }
        try await call(FeatureID.reprogControlsV4, 3, [UInt8(cid >> 8), UInt8(cid & 0xFF), bits, 0, 0])
    }

    /// Analytics key events report presses of a control without changing what it does.
    func setControlAnalytics(_ cid: UInt16, enabled: Bool) async throws {
        try await call(FeatureID.reprogControlsV4, 3, [UInt8(cid >> 8), UInt8(cid & 0xFF), 0, 0, 0, 0x02 | (enabled ? 1 : 0)])
    }
}

// MARK: - Easy-Switch (0x1814, 0x1815)

public struct HostInfo: Codable, Equatable, Sendable {
    public var index: Int
    public var paired: Bool
    /// "bluetooth", "receiver", "usb" or "unknown".
    public var bus: String
    public var name: String
}

public struct Hosts: Codable, Equatable, Sendable {
    public var current: Int
    public var hosts: [HostInfo]
    public var canReadNames: Bool
    public var canWriteNames: Bool
}

public extension HIDPPDevice {
    func changeHostInfo() async throws -> (count: Int, current: Int) {
        let r = try await call(FeatureID.changeHost, 0)
        return (Int(r.u8(0)), Int(r.u8(1)))
    }

    /// Switches to another host. The device disconnects right away, so no reply is awaited.
    func switchHost(_ host: Int) async throws {
        try await send(FeatureID.changeHost, 1, [UInt8(host)])
    }

    func readHosts() async throws -> Hosts {
        let info = try await call(FeatureID.hostsInfo, 0)
        let caps = info.u8(0)
        let count = Int(info.u8(2))
        let current = Int(info.u8(3))
        let canRead = caps & 0x01 != 0
        var hosts: [HostInfo] = []
        for h in 0..<count {
            let e = try await call(FeatureID.hostsInfo, 1, [UInt8(h)])
            let paired = e.u8(1) != 0
            let bus: String
            switch e.u8(2) {
            case 1, 3: bus = "receiver"
            case 2: bus = "usb"
            case 4, 5: bus = "bluetooth"
            default: bus = "unknown"
            }
            let length = Int(e.u8(4))
            var name: [UInt8] = []
            if canRead && paired {
                while name.count < length {
                    let chunk = try await call(FeatureID.hostsInfo, 3, [UInt8(h), UInt8(name.count)])
                    let take = min(length - name.count, 14)
                    if take == 0 { break }
                    name += chunk.slice(2, take)
                }
            }
            hosts.append(HostInfo(index: h, paired: paired, bus: bus,
                                  name: String(decoding: name.filter { $0 != 0 }, as: UTF8.self)))
        }
        return Hosts(current: current, hosts: hosts, canReadNames: canRead, canWriteNames: caps & 0x02 != 0)
    }

    func setHostName(_ host: Int, name: String) async throws {
        let e = try await call(FeatureID.hostsInfo, 1, [UInt8(host)])
        let maxLength = max(1, Int(e.u8(5)))
        let bytes = Array(Array(name.utf8).prefix(maxLength))
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 14, bytes.count)
            try await call(FeatureID.hostsInfo, 4, [UInt8(host), UInt8(offset)] + Array(bytes[offset..<end]))
            offset = end
        }
    }
}

// MARK: - Wireless device status (0x1D4B)

public struct WirelessStatusEvent: Equatable, Sendable {
    public var reconnection: Bool
    /// Volatile settings (diversions, DPI...) were lost and must be applied again.
    public var reconfigurationNeeded: Bool

    public static func decode(function: UInt8, _ p: Params) -> WirelessStatusEvent? {
        guard function == 0 else { return nil }
        return WirelessStatusEvent(reconnection: p.u8(0) == 1, reconfigurationNeeded: p.u8(1) == 1)
    }
}

// MARK: - Haptic feedback (0x19B0, MX Master 4)

public struct HapticConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var level: Int
}

public extension HIDPPDevice {
    func readHaptics() async throws -> HapticConfig {
        let p = try await call(FeatureID.haptic, 1)
        return HapticConfig(enabled: p.u8(0) & 0x01 != 0, level: Int(min(p.u8(1), 100)))
    }

    func setHaptics(enabled: Bool, level: Int) async throws {
        let l = UInt8(enabled ? min(max(level, 1), 100) : min(max(level, 0), 100))
        try await call(FeatureID.haptic, 2, [enabled ? 1 : 0, l])
    }

    func playHaptic(_ waveform: UInt8) async throws {
        try await call(FeatureID.haptic, 4, [waveform])
    }
}
