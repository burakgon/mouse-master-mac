import Foundation
import HIDPP
import IOKit
import IOKit.hid
import MouseMasterKit

/// A Logitech receiver and the devices paired with it.
@MainActor
final class ReceiverController {
    unowned let agent: Agent
    let receiver: HIDPPReceiver
    let location: Int
    private(set) var slots: [UInt8: DeviceController] = [:]
    private var key: String

    init(agent: Agent, receiver: HIDPPReceiver, location: Int) {
        self.agent = agent
        self.receiver = receiver
        self.location = location
        key = String(format: "rcv-%08x", location)
    }

    func start() {
        Task {
            do {
                if let serial = try? await receiver.serial(), !serial.isEmpty { key = "rcv-\(serial)" }
                try await receiver.enableNotifications()
                // Every paired device answers with a connection notification.
                try await receiver.triggerDeviceArrival()
                Log.info("\(receiver.model.name) ready")
            } catch {
                Log.error("\(receiver.model.name): \(error)")
            }
        }
    }

    var controllers: [DeviceController] { Array(slots.values) }

    func handle(_ report: Report) {
        if let event = ReceiverEvent.decode(report) {
            switch event {
            case .connection(let slot, let online, let kind, let wpid):
                guard kind.isPointer || kind == .unknown else { return }
                if let c = slots[slot] {
                    c.setReachable(online)
                } else {
                    Log.info(String(format: "%@: device %d (wpid %04x) %@", receiver.model.name, slot, wpid, online ? "online" : "offline"))
                    let c = DeviceController(agent: agent, channel: receiver.channel, index: slot,
                                             connection: ConnectionInfo(transport: "receiver", receiverName: receiver.model.name, slot: Int(slot)),
                                             cacheKey: "\(key)-\(slot)")
                    slots[slot] = c
                    if online { c.start() } else { c.setReachable(false) }
                }
            case .unpaired(let slot):
                slots.removeValue(forKey: slot)?.close()
            }
            return
        }
        slots[report.deviceIndex]?.handle(report)
    }

    func close() {
        for c in slots.values { c.close() }
    }
}

/// Finds Logitech HID++ devices and receivers and keeps one controller per device.
@MainActor
final class DeviceManager {
    unowned let agent: Agent

    @MainActor private final class Node {
        let transport: HIDTransport
        let channel: HIDPPChannel
        var direct: DeviceController?
        var receiver: ReceiverController?

        init(transport: HIDTransport, channel: HIDPPChannel) {
            self.transport = transport
            self.channel = channel
        }

        func route(_ report: Report) {
            if let receiver {
                receiver.handle(report)
            } else {
                direct?.handle(report)
            }
        }

        var controllers: [DeviceController] {
            if let receiver { return receiver.controllers }
            return direct.map { [$0] } ?? []
        }
    }

    private var manager: IOHIDManager?
    private var nodes: [ObjectIdentifier: Node] = [:]
    private var denied: [IOHIDDevice] = []

    init(agent: Agent) {
        self.agent = agent
    }

    var controllers: [DeviceController] { nodes.values.flatMap(\.controllers) }

    func controller(for id: String) -> DeviceController? {
        controllers.first { $0.id == id }
    }

    func start() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Any]] = [
            [kIOHIDVendorIDKey: logitechVendorID],
            [kIOHIDVendorIDKey: lenovoVendorID, kIOHIDProductIDKey: 0x6042],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(m, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { context, _, _, device in
            guard let context else { return }
            let manager = Unmanaged<DeviceManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { manager.added(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { context, _, _, device in
            guard let context else { return }
            let manager = Unmanaged<DeviceManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { manager.removed(device) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        manager = m
    }

    private func added(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        guard nodes[key] == nil else { return }
        let info = HIDDeviceInfo(device: device)
        guard info.isLogitech, info.hasVendorCollection, info.reports.isHIDPP else { return }
        let receiverModel = receiverModel(vendorID: info.vendorID, productID: info.productID)
        if receiverModel == nil && info.isKeyboard {
            // Keyboards are not supported yet, and opening them needs Input Monitoring.
            Log.debug("skipping keyboard \(info.product)")
            return
        }
        let transport = HIDTransport(device: device)
        let result = transport.open()
        guard result == kIOReturnSuccess else {
            Log.error(String(format: "cannot open %@: 0x%08x", info.product, UInt32(bitPattern: result)))
            if result == kIOReturnNotPermitted {
                denied.append(device)
                agent.permissions.markInputMonitoringNeeded()
                agent.setNeedsPublish()
            }
            return
        }
        let channel = HIDPPChannel(transport: transport)
        if Log.traceHIDPP {
            channel.trace = { Log.debug("[\(info.product)] \($0)") }
        }
        let node = Node(transport: transport, channel: channel)
        channel.onEvent = { [weak node] report in node?.route(report) }
        nodes[key] = node
        if let model = receiverModel {
            Log.info("found \(model.name)")
            let r = ReceiverController(agent: agent, receiver: HIDPPReceiver(channel: channel, model: model), location: info.locationID)
            node.receiver = r
            r.start()
        } else {
            Log.info("found \(info.product) over \(info.transport)")
            let transportName = info.isBluetooth ? "bluetooth" : "usb"
            let cacheKey = String(format: "%04x-%@", info.productID, info.serial.isEmpty ? String(format: "%08x", info.locationID) : info.serial)
            let c = DeviceController(agent: agent, channel: channel, index: deviceIndexSelf,
                                     connection: ConnectionInfo(transport: transportName), cacheKey: cacheKey)
            node.direct = c
            c.start()
        }
    }

    private func removed(_ device: IOHIDDevice) {
        denied.removeAll { $0 === device }
        guard let node = nodes.removeValue(forKey: ObjectIdentifier(device)) else { return }
        Log.info("\(node.transport.info.product) disconnected")
        node.channel.close()
        node.direct?.close()
        node.receiver?.close()
        node.transport.close()
        agent.setNeedsPublish()
    }

    /// Devices macOS refused to open; tried again once Input Monitoring is allowed.
    /// Returns true while some device still cannot be opened.
    @discardableResult
    func retryDenied() -> Bool {
        let list = denied
        denied.removeAll()
        for d in list { added(d) }
        return !denied.isEmpty
    }

    func closeAll() {
        for node in nodes.values {
            node.channel.close()
            node.transport.close()
        }
        nodes.removeAll()
    }
}
