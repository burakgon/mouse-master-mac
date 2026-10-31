import Foundation

/// One entry of a device's feature table.
public struct FeatureEntry: Codable, Equatable, Sendable {
    public var id: UInt16
    public var index: UInt8
    public var version: UInt8
    /// 0x80 obsolete, 0x40 hidden (software), 0x20 internal (engineering).
    public var flags: UInt8

    public var isHidden: Bool { flags & 0x60 != 0 }
}

/// The feature table of a device.
public struct FeatureTable: Codable, Equatable, Sendable {
    public var entries: [FeatureEntry] = []

    public init(entries: [FeatureEntry] = []) { self.entries = entries }

    public func entry(_ feature: UInt16) -> FeatureEntry? { entries.first { $0.id == feature } }
    public func entry(atIndex index: UInt8) -> FeatureEntry? { entries.first { $0.index == index } }
    public func contains(_ feature: UInt16) -> Bool { entry(feature) != nil }
    public var count: Int { entries.count }
}

/// A HID++ 2.0 device: a channel, a device index and its feature table.
@MainActor
public final class HIDPPDevice {
    public let channel: HIDPPChannel
    public let index: UInt8
    public private(set) var protocolVersion: (major: UInt8, minor: UInt8) = (0, 0)
    public private(set) var features = FeatureTable()

    init(channel: HIDPPChannel, index: UInt8) {
        self.channel = channel
        self.index = index
    }

    /// Pings the device and reads its feature table. A cached table is reused when the
    /// device still reports the same feature set.
    public static func open(channel: HIDPPChannel, index: UInt8, cached: FeatureTable? = nil,
                            pingTimeout: TimeInterval? = nil) async throws -> HIDPPDevice {
        let device = HIDPPDevice(channel: channel, index: index)
        let version = try await channel.ping(deviceIndex: index, timeout: pingTimeout)
        guard version.0 >= 2 else {
            throw HIDPPError.protocolError("HID++ \(version.0).\(version.1) devices are not supported")
        }
        device.protocolVersion = (version.0, version.1)
        if let cached, try await device.validate(cached) {
            device.features = cached
        } else {
            device.features = try await device.readFeatureTable()
        }
        return device
    }

    private func validate(_ table: FeatureTable) async throws -> Bool {
        guard let fs = table.entry(FeatureID.featureSet) else { return false }
        guard let found = try await rootGetFeature(FeatureID.featureSet), found.index == fs.index else { return false }
        let count = try await channel.featureCall(deviceIndex: index, featureIndex: fs.index, function: 0).u8(0)
        // The table holds the root feature plus `count` entries.
        return Int(count) + 1 == table.count
    }

    private func readFeatureTable() async throws -> FeatureTable {
        var table = FeatureTable(entries: [FeatureEntry(id: FeatureID.root, index: 0, version: 0, flags: 0)])
        guard let fs = try await rootGetFeature(FeatureID.featureSet) else {
            throw HIDPPError.protocolError("device has no feature set feature")
        }
        table.entries.append(FeatureEntry(id: FeatureID.featureSet, index: fs.index, version: fs.version, flags: fs.flags))
        let count = try await channel.featureCall(deviceIndex: index, featureIndex: fs.index, function: 0).u8(0)
        if count > 1 {
            for i in 1...count where i != fs.index {
                let r = try await channel.featureCall(deviceIndex: index, featureIndex: fs.index, function: 1, params: [i])
                table.entries.append(FeatureEntry(id: r.u16(0), index: i, version: r.u8(3), flags: r.u8(2)))
            }
        }
        return table
    }

    /// IRoot.getFeature: index, flags and version of a feature, or nil if unsupported.
    public func rootGetFeature(_ feature: UInt16) async throws -> (index: UInt8, flags: UInt8, version: UInt8)? {
        let r = try await channel.featureCall(deviceIndex: index, featureIndex: 0, function: 0,
                                              params: [UInt8(feature >> 8), UInt8(feature & 0xFF)])
        let i = r.u8(0)
        if i == 0 && feature != FeatureID.root { return nil }
        return (i, r.u8(1), r.u8(2))
    }

    public func has(_ feature: UInt16) -> Bool { features.contains(feature) }
    public func version(of feature: UInt16) -> UInt8? { features.entry(feature)?.version }
    /// Feature id at a feature index, used to dispatch events.
    public func feature(atIndex index: UInt8) -> UInt16? { features.entry(atIndex: index)?.id }

    private func indexOf(_ feature: UInt16) throws -> UInt8 {
        guard let e = features.entry(feature) else { throw HIDPPError.featureNotSupported(feature) }
        return e.index
    }

    /// Calls a feature function, retrying a few times while the device reports busy.
    @discardableResult
    public func call(_ feature: UInt16, _ function: UInt8, _ params: [UInt8] = []) async throws -> Params {
        let i = try indexOf(feature)
        var attempt = 0
        while true {
            do {
                return try await channel.featureCall(deviceIndex: index, featureIndex: i, function: function, params: params)
            } catch let e as HIDPPError where e.isBusy && attempt < 4 {
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(40_000_000 * attempt))
            }
        }
    }

    /// Calls a feature function without waiting for a reply.
    public func send(_ feature: UInt16, _ function: UInt8, _ params: [UInt8] = []) async throws {
        try await channel.featureSend(deviceIndex: index, featureIndex: try indexOf(feature), function: function, params: params)
    }
}
