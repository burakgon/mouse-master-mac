import Foundation
import IOKit
import IOKit.hid

public let logitechVendorID = 0x046D
/// Lenovo branded Logitech nano receiver.
public let lenovoVendorID = 0x17EF

/// Which HID++ related reports a device declares in its report descriptor.
public struct ReportSupport: Equatable, Sendable, Codable {
    public var short = false
    public var long = false
    public var veryLong = false
    public var dj = false

    public init(short: Bool = false, long: Bool = false, veryLong: Bool = false, dj: Bool = false) {
        self.short = short
        self.long = long
        self.veryLong = veryLong
        self.dj = dj
    }

    public var isHIDPP: Bool { short || long || veryLong }

    /// Parses a HID report descriptor and records the vendor specific report ids
    /// used by HID++ (0x10, 0x11, 0x12) and DJ (0x20, 0x21).
    public static func parse(descriptor: [UInt8]) -> ReportSupport {
        var support = ReportSupport()
        var usagePage: UInt32 = 0
        var stack: [UInt32] = []
        var i = 0
        while i < descriptor.count {
            let prefix = descriptor[i]
            if prefix == 0xFE {
                // Long item: 0xFE, size, tag, data...
                guard i + 1 < descriptor.count else { break }
                i += 3 + Int(descriptor[i + 1])
                continue
            }
            let size: Int
            switch prefix & 0x03 {
            case 0: size = 0
            case 1: size = 1
            case 2: size = 2
            default: size = 4
            }
            if i + 1 + size > descriptor.count { break }
            var value: UInt32 = 0
            for k in 0..<size { value |= UInt32(descriptor[i + 1 + k]) << (8 * UInt32(k)) }
            let itemType = (prefix >> 2) & 0x03
            let tag = prefix >> 4
            if itemType == 1 { // global
                switch tag {
                case 0x0: usagePage = value
                case 0x8: // report id
                    if usagePage >= 0xFF00 {
                        switch value {
                        case 0x10: support.short = true
                        case 0x11: support.long = true
                        case 0x12: support.veryLong = true
                        case 0x20, 0x21: support.dj = true
                        default: break
                        }
                    }
                case 0xA: stack.append(usagePage) // push
                case 0xB: usagePage = stack.popLast() ?? usagePage // pop
                default: break
                }
            }
            i += 1 + size
        }
        return support
    }
}

/// Static information about a HID device, read from IOKit properties.
public struct HIDDeviceInfo: Sendable {
    public var vendorID: Int
    public var productID: Int
    public var product: String
    public var serial: String
    public var transport: String
    public var locationID: Int
    public var usagePairs: [UsagePair]
    public var reports: ReportSupport
    public var maxInputReportSize: Int
    public var maxOutputReportSize: Int

    public struct UsagePair: Sendable, Equatable {
        public var page: Int
        public var usage: Int
    }

    public var isBluetooth: Bool { transport.localizedCaseInsensitiveContains("bluetooth") }
    public var isUSB: Bool { transport.localizedCaseInsensitiveContains("usb") }
    public var hasVendorCollection: Bool { usagePairs.contains { $0.page >= 0xFF00 } }
    public var isKeyboard: Bool { usagePairs.contains { $0.page == 1 && ($0.usage == 6 || $0.usage == 7) } }
    public var isLogitech: Bool {
        vendorID == logitechVendorID || (vendorID == lenovoVendorID && productID == 0x6042)
    }

    public init(device: IOHIDDevice) {
        func int(_ key: String) -> Int { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0 }
        func str(_ key: String) -> String { (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? "" }
        vendorID = int(kIOHIDVendorIDKey)
        productID = int(kIOHIDProductIDKey)
        product = str(kIOHIDProductKey)
        serial = str(kIOHIDSerialNumberKey)
        transport = str(kIOHIDTransportKey)
        locationID = int(kIOHIDLocationIDKey)
        maxInputReportSize = int(kIOHIDMaxInputReportSizeKey)
        maxOutputReportSize = int(kIOHIDMaxOutputReportSizeKey)
        var pairs: [UsagePair] = []
        if let list = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] {
            for p in list {
                let page = (p[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue ?? 0
                let usage = (p[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue ?? 0
                pairs.append(UsagePair(page: page, usage: usage))
            }
        }
        if pairs.isEmpty {
            pairs.append(UsagePair(page: int(kIOHIDPrimaryUsagePageKey), usage: int(kIOHIDPrimaryUsageKey)))
        }
        usagePairs = pairs
        if let data = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data {
            reports = ReportSupport.parse(descriptor: [UInt8](data))
        } else {
            reports = ReportSupport()
        }
    }
}

/// An open HID device carrying HID++ reports. Input reports are delivered on the
/// main run loop (in common modes, so menus do not stall them).
@MainActor
public final class HIDTransport {
    public nonisolated(unsafe) let device: IOHIDDevice
    public let info: HIDDeviceInfo
    public var onReport: (([UInt8]) -> Void)?
    public private(set) var isOpen = false

    /// Writes block until the report is on its way; keep them off the main thread.
    public nonisolated let writeQueue = DispatchQueue(label: "com.burakgon.MouseMaster.hid-write", qos: .userInteractive)

    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize: Int

    public init(device: IOHIDDevice) {
        self.device = device
        info = HIDDeviceInfo(device: device)
        bufferSize = max(64, info.maxInputReportSize)
        buffer = .allocate(capacity: bufferSize)
        buffer.initialize(repeating: 0, count: bufferSize)
    }

    deinit {
        buffer.deallocate()
    }

    /// Opens the device and starts delivering input reports.
    public func open() -> IOReturn {
        guard !isOpen else { return kIOReturnSuccess }
        let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else { return r }
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, hidInputReportCallback,
                                               Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        isOpen = true
        return r
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Sends an output report (the first byte is the report id). Safe to call from any thread.
    public nonisolated func write(_ bytes: [UInt8]) -> IOReturn {
        guard let id = bytes.first else { return kIOReturnBadArgument }
        return bytes.withUnsafeBufferPointer { p in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(id), p.baseAddress!, p.count)
        }
    }

    fileprivate func deliver(_ bytes: [UInt8]) {
        onReport?(bytes)
    }
}

private func hidInputReportCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                                    sender: UnsafeMutableRawPointer?, type: IOHIDReportType,
                                    reportID: UInt32, report: UnsafeMutablePointer<UInt8>,
                                    length: CFIndex) {
    guard let context, length > 0 else { return }
    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
    let transport = Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated {
        transport.deliver(bytes)
    }
}
