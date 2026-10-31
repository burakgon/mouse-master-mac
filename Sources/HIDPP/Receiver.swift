import Foundation

public enum ReceiverKind: String, Codable, Sendable {
    case unifying, bolt, nano, lightspeed
}

public struct ReceiverModel: Equatable, Sendable {
    public var productID: Int
    public var kind: ReceiverKind
    public var name: String
    public var maxDevices: Int
}

/// Looks up a known receiver by USB vendor and product id.
public func receiverModel(vendorID: Int, productID: Int) -> ReceiverModel? {
    switch (vendorID, productID) {
    case (0x046D, 0xC548):
        return ReceiverModel(productID: productID, kind: .bolt, name: "Bolt Receiver", maxDevices: 6)
    case (0x046D, 0xC52B), (0x046D, 0xC532):
        return ReceiverModel(productID: productID, kind: .unifying, name: "Unifying Receiver", maxDevices: 6)
    case (0x046D, 0xC52F), (0x046D, 0xC518), (0x046D, 0xC51A), (0x046D, 0xC51B), (0x046D, 0xC521),
         (0x046D, 0xC525), (0x046D, 0xC526), (0x046D, 0xC52E), (0x046D, 0xC531), (0x046D, 0xC535),
         (0x046D, 0xC537), (0x17EF, 0x6042):
        return ReceiverModel(productID: productID, kind: .nano, name: "Nano Receiver", maxDevices: 1)
    case (0x046D, 0xC534):
        return ReceiverModel(productID: productID, kind: .nano, name: "Nano Receiver", maxDevices: 2)
    case (0x046D, 0xC539), (0x046D, 0xC53A), (0x046D, 0xC53D), (0x046D, 0xC53F), (0x046D, 0xC541),
         (0x046D, 0xC545), (0x046D, 0xC547), (0x046D, 0xC54D):
        return ReceiverModel(productID: productID, kind: .lightspeed, name: "Lightspeed Receiver", maxDevices: 2)
    default:
        return nil
    }
}

public struct PairedDevice: Equatable, Sendable {
    public var slot: UInt8
    public var wirelessPID: UInt16
    public var kind: DeviceKind
    public var serial: String?
    public var codename: String?
}

/// HID++ 1.0 notifications sent by receivers.
public enum ReceiverEvent: Equatable, Sendable {
    /// A paired device went on- or offline (sub id 0x41).
    case connection(slot: UInt8, online: Bool, kind: DeviceKind, wirelessPID: UInt16)
    /// A device was unpaired (sub id 0x40).
    case unpaired(slot: UInt8)

    public static func decode(_ r: Report) -> ReceiverEvent? {
        guard r.isHIDPP10Notification else { return nil }
        let p = r.params
        switch r.subID {
        case 0x41 where r.address != 0x02:
            let flags = p.u8(0)
            return .connection(slot: r.deviceIndex, online: flags & 0x40 == 0, kind: DeviceKind(hidpp10: flags),
                               wirelessPID: UInt16(p.u8(2)) << 8 | UInt16(p.u8(1)))
        case 0x40 where r.address == 0x02:
            return .unpaired(slot: r.deviceIndex)
        default:
            return nil
        }
    }
}

/// A Logitech receiver and the HID++ 1.0 registers used to manage its devices.
@MainActor
public final class HIDPPReceiver {
    public let channel: HIDPPChannel
    public let model: ReceiverModel

    private enum Register {
        static let notifications: UInt16 = 0x00
        static let connectionState: UInt16 = 0x02
        static let receiverInfo: UInt16 = 0x2B5
        static let boltUniqueID: UInt16 = 0x2FB
    }

    public init(channel: HIDPPChannel, model: ReceiverModel) {
        self.channel = channel
        self.model = model
    }

    /// Asks the receiver to report device connections and disconnections.
    public func enableNotifications() async throws {
        let current = try await channel.readRegister(deviceIndex: deviceIndexSelf, register: Register.notifications)
        let value = UInt32(current.u8(0)) << 16 | UInt32(current.u8(1)) << 8 | UInt32(current.u8(2))
        let wanted = value | 0x000100 | 0x000800 // wireless notifications, software present
        try await channel.writeRegister(deviceIndex: deviceIndexSelf, register: Register.notifications,
                                        params: [UInt8((wanted >> 16) & 0xFF), UInt8((wanted >> 8) & 0xFF), UInt8(wanted & 0xFF)])
    }

    /// Makes the receiver send a connection notification for every paired device.
    public func triggerDeviceArrival() async throws {
        try await channel.writeRegister(deviceIndex: deviceIndexSelf, register: Register.connectionState, params: [0x02])
    }

    public func serial() async throws -> String {
        if model.kind == .bolt {
            let p = try await channel.readRegister(deviceIndex: deviceIndexSelf, register: Register.boltUniqueID)
            let end = (p.bytes.lastIndex { $0 != 0 }).map { $0 + 1 } ?? 0
            return Array(p.bytes.prefix(end)).map { String(format: "%02X", $0) }.joined()
        }
        let p = try await channel.readRegister(deviceIndex: deviceIndexSelf, register: Register.receiverInfo, params: [0x03])
        return p.slice(1, 4).map { String(format: "%02X", $0) }.joined()
    }

    /// What the receiver knows about the device paired in `slot` (1 based).
    public func pairedDevice(slot: UInt8) async throws -> PairedDevice {
        if model.kind == .bolt {
            let p = try await channel.readRegister(deviceIndex: deviceIndexSelf, register: Register.receiverInfo, params: [0x50 + slot])
            return PairedDevice(slot: slot, wirelessPID: UInt16(p.u8(3)) << 8 | UInt16(p.u8(2)),
                                kind: DeviceKind(hidpp10: p.u8(1)),
                                serial: p.slice(4, 4).map { String(format: "%02X", $0) }.joined(), codename: nil)
        }
        let p = try await channel.readRegister(deviceIndex: deviceIndexSelf, register: Register.receiverInfo, params: [0x20 + slot - 1])
        return PairedDevice(slot: slot, wirelessPID: p.u16(3), kind: DeviceKind(hidpp10: p.u8(7)), serial: nil, codename: nil)
    }
}
