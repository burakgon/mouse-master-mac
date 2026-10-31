import Foundation

// Every HID++ report starts with the same four bytes:
//
// | byte | HID++ 1.0          | HID++ 2.0                            |
// |------|--------------------|--------------------------------------|
// | 0    | report id          | report id                            |
// | 1    | device index       | device index                         |
// | 2    | sub id             | feature index                        |
// | 3    | address (register) | function (high nibble) + software id |
//
// followed by the parameters (3, 16 or 60 bytes depending on the report type).

public enum ReportID {
    public static let short: UInt8 = 0x10
    public static let long: UInt8 = 0x11
    public static let veryLong: UInt8 = 0x12
    public static let djShort: UInt8 = 0x20
    public static let djLong: UInt8 = 0x21
}

/// Device index addressing a receiver itself, or a device connected directly over USB or Bluetooth.
public let deviceIndexSelf: UInt8 = 0xFF

/// Sub id of HID++ 1.0 error replies.
let subIDError10: UInt8 = 0x8F
/// Feature index of HID++ 2.0 error replies.
let featureIndexError20: UInt8 = 0xFF

public enum ReportKind: Sendable, CaseIterable {
    case short, long, veryLong

    public var reportID: UInt8 {
        switch self {
        case .short: return ReportID.short
        case .long: return ReportID.long
        case .veryLong: return ReportID.veryLong
        }
    }

    public var size: Int {
        switch self {
        case .short: return 7
        case .long: return 20
        case .veryLong: return 64
        }
    }

    public var paramLength: Int { size - 4 }
}

/// A single HID++ or DJ report, exactly as read from or written to the device.
public struct Report: Equatable, Sendable, CustomStringConvertible {
    public private(set) var bytes: [UInt8]

    /// Builds a HID++ report, zero padding (or truncating) the parameters.
    public init(kind: ReportKind, deviceIndex: UInt8, subID: UInt8, address: UInt8, params: [UInt8] = []) {
        var b = [UInt8](repeating: 0, count: kind.size)
        b[0] = kind.reportID
        b[1] = deviceIndex
        b[2] = subID
        b[3] = address
        let n = min(params.count, kind.paramLength)
        for i in 0..<n { b[4 + i] = params[i] }
        bytes = b
    }

    /// Parses an input report. Returns nil for reports that are neither HID++ nor DJ,
    /// or that are shorter than their nominal size. Longer reports are trimmed.
    public init?(_ data: [UInt8]) {
        guard let id = data.first else { return nil }
        let nominal: Int
        switch id {
        case ReportID.short: nominal = 7
        case ReportID.long: nominal = 20
        case ReportID.veryLong: nominal = 64
        case ReportID.djShort: nominal = 15
        case ReportID.djLong: nominal = 32
        default: return nil
        }
        guard data.count >= nominal else { return nil }
        bytes = Array(data[0..<nominal])
    }

    public var reportID: UInt8 { bytes[0] }
    public var deviceIndex: UInt8 { bytes[1] }
    public var subID: UInt8 { bytes[2] }
    public var address: UInt8 { bytes[3] }
    /// HID++ 2.0 feature index (same byte as the HID++ 1.0 sub id).
    public var featureIndex: UInt8 { bytes[2] }
    /// HID++ 2.0 function (or event) number.
    public var function: UInt8 { bytes[3] >> 4 }
    /// HID++ 2.0 software id. Unsolicited events carry 0.
    public var softwareID: UInt8 { bytes[3] & 0x0F }
    public var params: Params { Params(Array(bytes[4...])) }

    public var isHIDPP: Bool { reportID == ReportID.short || reportID == ReportID.long || reportID == ReportID.veryLong }
    public var isDJ: Bool { reportID == ReportID.djShort || reportID == ReportID.djLong }
    /// HID++ 1.0 register replies and errors (sub ids with the top bit set).
    public var isRegisterMessage: Bool { isHIDPP && subID & 0x80 == 0x80 && subID != featureIndexError20 }
    /// HID++ 1.0 notifications sent by receivers (sub ids 0x40..<0x80).
    public var isHIDPP10Notification: Bool { isHIDPP && (0x40..<0x80).contains(subID) }
    /// HID++ 2.0 feature events (unsolicited, software id 0).
    public var isFeatureEvent: Bool { isHIDPP && subID < 0x40 && softwareID == 0 }

    public var description: String {
        let head = bytes.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " ")
        let p = Array(bytes.dropFirst(4))
        let end = (p.lastIndex { $0 != 0 }).map { $0 + 1 } ?? 0
        var tail = p.prefix(end).map { String(format: "%02x", $0) }.joined(separator: " ")
        if end < p.count { tail += tail.isEmpty ? ".." : " .." }
        return "[\(head) | \(tail)]"
    }
}

/// The parameter bytes of a HID++ message. Reading past the end yields zeros,
/// mirroring how devices zero-pad replies.
public struct Params: Equatable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var count: Int { bytes.count }

    public func u8(_ i: Int) -> UInt8 { i >= 0 && i < bytes.count ? bytes[i] : 0 }
    public func i8(_ i: Int) -> Int8 { Int8(bitPattern: u8(i)) }
    public func u16(_ i: Int) -> UInt16 { UInt16(u8(i)) << 8 | UInt16(u8(i + 1)) }
    public func i16(_ i: Int) -> Int16 { Int16(bitPattern: u16(i)) }
    public func u32(_ i: Int) -> UInt32 {
        UInt32(u8(i)) << 24 | UInt32(u8(i + 1)) << 16 | UInt32(u8(i + 2)) << 8 | UInt32(u8(i + 3))
    }

    /// `length` bytes starting at `start`, clamped to the available data.
    public func slice(_ start: Int, _ length: Int) -> [UInt8] {
        let s = min(max(start, 0), bytes.count)
        let e = min(s + max(length, 0), bytes.count)
        return Array(bytes[s..<e])
    }

    public var description: String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }
}

public extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined(separator: " ") }

    init?(hexString: String) {
        let cleaned = hexString.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ":", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            let j = cleaned.index(i, offsetBy: 2)
            guard let b = UInt8(cleaned[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        self = out
    }
}
