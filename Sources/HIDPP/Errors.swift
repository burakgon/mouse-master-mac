import Foundation

public enum HIDPPError: Error, Equatable, CustomStringConvertible, Sendable {
    /// The device went away (unplugged, out of range, asleep over Bluetooth).
    case disconnected
    case timeout(deviceIndex: UInt8)
    /// The receiver says the device is asleep, switched off or out of range.
    case unreachable
    case hidpp10(UInt8)
    case hidpp20(UInt8)
    case featureNotSupported(UInt16)
    case protocolError(String)
    case io(Int32)

    /// Errors that mean the device is (temporarily) gone, as opposed to a bad request.
    public var isOffline: Bool {
        switch self {
        case .disconnected, .unreachable, .timeout: return true
        case .hidpp10(let code): return code == 0x09 || code == 0x08 || code == 0x04
        default: return false
        }
    }

    public var isBusy: Bool {
        switch self {
        case .hidpp20(0x08), .hidpp10(0x07): return true
        default: return false
        }
    }

    public var description: String {
        switch self {
        case .disconnected: return "the device was disconnected"
        case .timeout(let i): return String(format: "no reply from device 0x%02x", i)
        case .unreachable: return "the device is not reachable (asleep, switched off or out of range)"
        case .hidpp10(let c): return "HID++ 1.0 error \(Self.name10(c))"
        case .hidpp20(let c): return "HID++ 2.0 error \(Self.name20(c))"
        case .featureNotSupported(let f): return String(format: "feature 0x%04x is not supported by this device", f)
        case .protocolError(let s): return "protocol error: \(s)"
        case .io(let r): return String(format: "I/O error 0x%08x", UInt32(bitPattern: r))
        }
    }

    static func name10(_ c: UInt8) -> String {
        switch c {
        case 0x01: return "invalid sub id"
        case 0x02: return "invalid address"
        case 0x03: return "invalid value"
        case 0x04: return "connection request failed"
        case 0x05: return "too many devices"
        case 0x06: return "already exists"
        case 0x07: return "busy"
        case 0x08: return "unknown device"
        case 0x09: return "resource error"
        case 0x0A: return "request unavailable"
        case 0x0B: return "unsupported parameter value"
        case 0x0C: return "wrong pin code"
        default: return String(format: "0x%02x", c)
        }
    }

    static func name20(_ c: UInt8) -> String {
        switch c {
        case 0x01: return "unknown"
        case 0x02: return "invalid argument"
        case 0x03: return "out of range"
        case 0x04: return "hardware error"
        case 0x05: return "internal error"
        case 0x06: return "invalid feature index"
        case 0x07: return "invalid function"
        case 0x08: return "busy"
        case 0x09: return "unsupported"
        default: return String(format: "0x%02x", c)
        }
    }
}
