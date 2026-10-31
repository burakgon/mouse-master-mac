import Foundation
import IOKit

/// A HID++ channel: one HID device shared by everything reachable through it
/// (a receiver and its paired devices, or a single directly connected device).
///
/// One request is in flight at a time. Replies are matched against it; everything
/// else (HID++ 1.0 notifications, HID++ 2.0 feature events) goes to `onEvent`.
@MainActor
public final class HIDPPChannel {
    /// Software id used for our requests. Bit 3 set distinguishes replies from
    /// unsolicited events (software id 0). Others: kernel 0x01, Solaar 0x0B, G HUB 0x0D.
    public static let softwareID: UInt8 = 0x0E

    public static let receiverTimeout: TimeInterval = 1.5
    public static let deviceTimeout: TimeInterval = 2.5

    public let transport: HIDTransport
    public var onEvent: ((Report) -> Void)?
    public private(set) var isClosed = false
    /// Logs every report when set (diagnostics).
    public var trace: ((String) -> Void)?

    private struct Pending {
        let matcher: Matcher
        let continuation: CheckedContinuation<Report, Error>
        let token: UInt64
    }

    private var pending: Pending?
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var nextToken: UInt64 = 0
    private var pingCounter: UInt8 = 0x5A

    public init(transport: HIDTransport) {
        self.transport = transport
        transport.onReport = { [weak self] bytes in self?.received(bytes) }
    }

    public var reports: ReportSupport { transport.info.reports }

    /// Fails the request in flight and refuses new ones (the device went away).
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        if let p = pending {
            pending = nil
            p.continuation.resume(throwing: HIDPPError.disconnected)
        }
        let w = waiters
        waiters.removeAll()
        for c in w { c.resume() }
    }

    // MARK: Requests

    /// Calls a HID++ 2.0 feature function and returns the reply parameters.
    public func featureCall(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8,
                            params: [UInt8] = [], timeout: TimeInterval? = nil) async throws -> Params {
        let address = (function << 4) | Self.softwareID
        let report = Report(kind: pickKind(params.count), deviceIndex: deviceIndex, subID: featureIndex,
                            address: address, params: params)
        let matcher = Matcher.feature(deviceIndex: deviceIndex, featureIndex: featureIndex, address: address)
        let reply = try await transact(report, matcher, timeout: timeout ?? Self.deviceTimeout)
        return reply.params
    }

    /// Calls a HID++ 2.0 feature function without waiting for a reply.
    public func featureSend(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8, params: [UInt8] = []) async throws {
        let address = (function << 4) | Self.softwareID
        let report = Report(kind: pickKind(params.count), deviceIndex: deviceIndex, subID: featureIndex,
                            address: address, params: params)
        await acquire()
        defer { release() }
        if isClosed { throw HIDPPError.disconnected }
        try await write(report)
    }

    /// Reads a HID++ 1.0 register. Registers above 0xFF are long registers.
    public func readRegister(deviceIndex: UInt8, register: UInt16, params: [UInt8] = []) async throws -> Params {
        let long = register > 0xFF
        let subID: UInt8 = long ? 0x83 : 0x81
        let address = UInt8(register & 0xFF)
        let report = Report(kind: pickKind(params.count), deviceIndex: deviceIndex, subID: subID,
                            address: address, params: params)
        // Replies to the multi purpose info registers must also echo the sub register.
        let echo = (long && address == 0xB5) || (!long && address == 0xF1) ? params.first : nil
        let matcher = Matcher.register(deviceIndex: deviceIndex, subID: subID, address: address, firstParam: echo)
        var timeout = deviceIndex == deviceIndexSelf ? Self.receiverTimeout : Self.deviceTimeout
        if long { timeout *= 2 }
        return try await transact(report, matcher, timeout: timeout).params
    }

    /// Writes a HID++ 1.0 register.
    @discardableResult
    public func writeRegister(deviceIndex: UInt8, register: UInt16, params: [UInt8]) async throws -> Params {
        let long = register > 0xFF || params.count > ReportKind.short.paramLength
        let subID: UInt8 = long ? 0x82 : 0x80
        let address = UInt8(register & 0xFF)
        let report = Report(kind: pickKind(params.count, forceLong: long), deviceIndex: deviceIndex,
                            subID: subID, address: address, params: params)
        let matcher = Matcher.register(deviceIndex: deviceIndex, subID: subID, address: address, firstParam: nil)
        let timeout = deviceIndex == deviceIndexSelf ? Self.receiverTimeout : Self.deviceTimeout
        return try await transact(report, matcher, timeout: timeout).params
    }

    /// Pings a device; returns its HID++ protocol version. HID++ 1.0 devices report (1, 0).
    public func ping(deviceIndex: UInt8, timeout: TimeInterval? = nil) async throws -> (UInt8, UInt8) {
        pingCounter = pingCounter &+ 0x3D
        let mark = pingCounter | 1
        let address = (1 << 4) | Self.softwareID // root feature, function 1: getProtocolVersion
        let report = Report(kind: pickKind(3), deviceIndex: deviceIndex, subID: 0x00, address: address,
                            params: [0, 0, mark])
        do {
            let reply = try await transact(report, .ping(deviceIndex: deviceIndex, address: address, mark: mark),
                                           timeout: timeout ?? Self.deviceTimeout)
            return (reply.params.u8(0), reply.params.u8(1))
        } catch HIDPPError.hidpp10(0x01) {
            return (1, 0)
        } catch HIDPPError.hidpp10(0x08) {
            throw HIDPPError.unreachable
        }
    }

    /// Picks the smallest report type the device supports that fits the parameters.
    func pickKind(_ paramCount: Int, forceLong: Bool = false) -> ReportKind {
        let s = reports
        if !forceLong && paramCount <= ReportKind.short.paramLength && s.short { return .short }
        if paramCount <= ReportKind.long.paramLength && s.long { return .long }
        if s.veryLong { return .veryLong }
        if s.long { return .long }
        return .short
    }

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }

    private func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func write(_ report: Report) async throws {
        let transport = self.transport
        let bytes = report.bytes
        trace?("-> \(report)")
        let result: IOReturn = await withCheckedContinuation { c in
            transport.writeQueue.async { c.resume(returning: transport.write(bytes)) }
        }
        if result != kIOReturnSuccess {
            throw Self.mapWriteError(result)
        }
    }

    static func mapWriteError(_ r: IOReturn) -> HIDPPError {
        if r == kIOReturnNotAttached || r == kIOReturnNoDevice || r == kIOReturnNotOpen || r == kIOReturnAborted {
            return .disconnected
        }
        return .io(r)
    }

    private func transact(_ report: Report, _ matcher: Matcher, timeout: TimeInterval) async throws -> Report {
        await acquire()
        defer { release() }
        if isClosed { throw HIDPPError.disconnected }
        nextToken &+= 1
        let token = nextToken
        let transport = self.transport
        let bytes = report.bytes
        trace?("-> \(report)")
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Report, Error>) in
            pending = Pending(matcher: matcher, continuation: c, token: token)
            transport.writeQueue.async { [weak self] in
                let r = transport.write(bytes)
                guard r != kIOReturnSuccess else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.fail(token: token, error: Self.mapWriteError(r)) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    self?.fail(token: token, error: .timeout(deviceIndex: report.deviceIndex))
                }
            }
        }
    }

    private func fail(token: UInt64, error: HIDPPError) {
        guard let p = pending, p.token == token else { return }
        pending = nil
        p.continuation.resume(throwing: error)
    }

    // MARK: Input

    private func received(_ bytes: [UInt8]) {
        guard let report = Report(bytes) else { return }
        if let p = pending, let result = p.matcher.check(report) {
            pending = nil
            trace?("<- \(report) (reply)")
            switch result {
            case .success(let r): p.continuation.resume(returning: r)
            case .failure(let e): p.continuation.resume(throwing: e)
            }
            return
        }
        if report.isDJ {
            // DJ input reports (type < 0x10) are plain input.
            if report.subID < 0x10 { return }
        } else if report.isRegisterMessage {
            return // replies to somebody else's register requests
        } else if report.isHIDPP && report.subID < 0x40 && report.softwareID != 0 {
            return // replies to other software's feature calls
        }
        trace?("<- \(report) (event)")
        onEvent?(report)
    }
}

enum Matcher {
    case feature(deviceIndex: UInt8, featureIndex: UInt8, address: UInt8)
    case register(deviceIndex: UInt8, subID: UInt8, address: UInt8, firstParam: UInt8?)
    case ping(deviceIndex: UInt8, address: UInt8, mark: UInt8)

    var deviceIndex: UInt8 {
        switch self {
        case .feature(let d, _, _), .register(let d, _, _, _), .ping(let d, _, _): return d
        }
    }

    /// Some Bluetooth devices answer requests sent to 0xFF with index 0x00.
    static func sameDevice(_ expected: UInt8, _ actual: UInt8) -> Bool {
        actual == expected || actual == expected ^ 0xFF
    }

    /// Returns a result if the report answers the request this matcher describes.
    func check(_ r: Report) -> Result<Report, HIDPPError>? {
        guard r.isHIDPP, Self.sameDevice(deviceIndex, r.deviceIndex) else { return nil }
        let p = r.params
        switch self {
        case .feature(_, let featureIndex, let address):
            if r.subID == featureIndexError20 && r.address == featureIndex && p.u8(0) == address {
                return .failure(.hidpp20(p.u8(1)))
            }
            if r.subID == subIDError10 && r.address == featureIndex && p.u8(0) == address {
                return .failure(Self.map10(p.u8(1)))
            }
            if r.subID == featureIndex && r.address == address { return .success(r) }
            return nil
        case .register(_, let subID, let address, let firstParam):
            if r.subID == subIDError10 && r.address == subID && p.u8(0) == address {
                return .failure(Self.map10(p.u8(1)))
            }
            if r.subID == subID && r.address == address && (firstParam == nil || p.u8(0) == firstParam) {
                return .success(r)
            }
            return nil
        case .ping(_, let address, let mark):
            if r.subID == 0x00 && r.address == address && p.u8(2) == mark { return .success(r) }
            if r.subID == subIDError10 && r.address == 0x00 && p.u8(0) == address { return .failure(.hidpp10(p.u8(1))) }
            if r.subID == featureIndexError20 && r.address == 0x00 && p.u8(0) == address { return .failure(.hidpp20(p.u8(1))) }
            return nil
        }
    }

    static func map10(_ code: UInt8) -> HIDPPError {
        code == 0x09 || code == 0x04 ? .unreachable : .hidpp10(code)
    }
}
