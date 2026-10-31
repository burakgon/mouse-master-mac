import AppKit
import HIDPP
import MouseMasterKit

/// What does not change while a device is connected; cached between connections so a
/// device that wakes up is ready in a few requests.
struct StaticInfo: Codable, Equatable {
    var id: String
    var name: String
    var kind: DeviceKind
    var modelID: String
    var unitID: String
    var serial: String?
    var firmware: [FirmwareEntity]
    var protocolVersion: String
    var controls: [ReprogControl]
    var dpiRange: DPIRange?
    var dpiDefault: Int?
    var smartShiftFeature: UInt16?
    var smartShiftTorque: Bool
    var smartShiftDefault: Int?
    var wheel: WheelCapability?
    var thumb: ThumbwheelInfo?
    var hostCount: Int?
    var hostNamesWritable: Bool
    var haptics: Bool
    var battery: Bool
    var features: [FeatureEntry]
}

struct CachedDevice: Codable {
    var features: FeatureTable
    var info: StaticInfo
    var snapshot: DeviceSnapshot?
}

@MainActor
final class DeviceCache {
    private var entries: [String: CachedDevice] = [:]
    private var saveItem: DispatchWorkItem?

    func load() {
        guard let data = try? Data(contentsOf: MMPaths.deviceCacheURL),
              let decoded = try? JSONDecoder().decode([String: CachedDevice].self, from: data) else { return }
        entries = decoded
    }

    func get(_ key: String) -> CachedDevice? { entries[key] }

    func put(_ key: String, _ value: CachedDevice) {
        entries[key] = value
        scheduleSave()
    }

    func updateSnapshot(_ key: String, _ snapshot: DeviceSnapshot) {
        guard entries[key] != nil, entries[key]?.snapshot != snapshot else { return }
        entries[key]?.snapshot = snapshot
        scheduleSave()
    }

    func forget(deviceID: String) {
        entries = entries.filter { $0.value.info.id != deviceID }
        scheduleSave()
    }

    var snapshots: [DeviceSnapshot] { entries.values.compactMap(\.snapshot) }

    private func scheduleSave() {
        guard saveItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.saveItem = nil
                self?.saveNow()
            }
        }
        saveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    func saveNow() {
        saveItem?.cancel()
        saveItem = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: MMPaths.deviceCacheURL, options: .atomic)
        }
    }
}

/// Owns one device: reads it, applies the configuration, turns its events into actions.
@MainActor
final class DeviceController {
    unowned let agent: Agent
    let channel: HIDPPChannel
    let index: UInt8
    let connection: ConnectionInfo
    let cacheKey: String

    private(set) var device: HIDPPDevice?
    private(set) var info: StaticInfo?
    private(set) var snapshot: DeviceSnapshot?
    private(set) var isClosed = false
    private var ready = false
    private var reachable = true
    var id: String? { info?.id }

    private var hw = HardwareState()
    private var battery: BatteryInfo?
    private var batteryWarned = false
    private var baselineDPI: Int?

    // Buttons
    private struct Diversion: Equatable {
        var divert: Bool
        var rawXY: Bool
    }

    private var bindings = Bindings()
    private var profile: AppProfile?
    private var applied: [UInt16: Diversion] = [:]
    private var analytics: Set<UInt16> = []
    private var pressed: [UInt16] = []
    private var held: [UInt16: Action] = [:]
    private var gesture: (cid: UInt16, tracker: GestureTracker)?
    private var bindingsDirty = false
    private var skipFirstMotion = false

    // Wheels
    private struct ThumbState: Equatable {
        var diverted: Bool
        var inverted: Bool
    }

    private var wheelApplied: WheelReporting?
    private var thumbApplied: ThumbState?
    private var thumbTracker: ThumbwheelTracker?
    private var wheelAccel: WheelAccelerator?
    private var thumbLit = false
    private lazy var scroller = SmoothScroller(synth: agent.synth)

    // Settings
    private var appliedSettings: DeviceSettings?
    private var dpiBeforeShift: Int?
    private var reconciling = false
    private var reconcileAgain = false
    private var reconcileForce = false

    init(agent: Agent, channel: HIDPPChannel, index: UInt8, connection: ConnectionInfo, cacheKey: String) {
        self.agent = agent
        self.channel = channel
        self.index = index
        self.connection = connection
        self.cacheKey = cacheKey
    }

    private var label: String { info?.name ?? "device \(cacheKey)" }
    var config: DeviceConfig { id.flatMap { agent.store.config.devices[$0] } ?? DeviceConfig() }
    private var settings: DeviceSettings { config.settings }
    /// This mouse's scroll direction ("natural" when true).
    private var natural: Bool { settings.scrollDirection.map { $0 == .natural } ?? agent.systemNatural }

    // MARK: Lifecycle

    func start() {
        Task { await self.initializeWithRetry() }
    }

    /// The device went away (Bluetooth disconnect, receiver unplugged).
    func close() {
        guard !isClosed else { return }
        isClosed = true
        ready = false
        releaseAllHeld()
        scroller.stop()
        if var s = snapshot {
            s.online = false
            s.busy = false
            snapshot = s
            agent.deviceWentOffline(s)
        }
    }

    /// A device behind a receiver went to sleep or woke up.
    func setReachable(_ online: Bool) {
        guard online != reachable || !ready else { return }
        reachable = online
        if online {
            if ready {
                Log.info("\(label) is back")
                // It lost every volatile setting while asleep.
                applied.removeAll()
                wheelApplied = nil
                thumbApplied = nil
                appliedSettings = nil
                snapshot?.online = true
                Task {
                    await self.reconcile(force: true)
                    await self.refreshDynamicState()
                    self.publish()
                }
            } else {
                start()
            }
        } else {
            releaseAllHeld()
            scroller.stop()
            snapshot?.online = false
            agent.deviceChanged(self)
        }
    }

    private func initializeWithRetry() async {
        var attempt = 0
        while !isClosed {
            do {
                try await initialize()
                return
            } catch let e as HIDPPError where e.isOffline && attempt < 6 {
                attempt += 1
                if connection.transport == "receiver" && e == .unreachable {
                    reachable = false
                    return // the receiver tells us when it wakes up
                }
                Log.debug("\(label): not answering yet (\(e)), retry \(attempt)")
                try? await Task.sleep(nanoseconds: UInt64(350_000_000 * attempt))
            } catch {
                Log.error("\(label): cannot initialise: \(error)")
                if var s = snapshot {
                    s.error = "\(error)"
                    s.busy = false
                    snapshot = s
                    agent.deviceChanged(self)
                }
                return
            }
        }
    }

    private func initialize() async throws {
        let started = CACurrentMediaTime()
        let cached = agent.cache.get(cacheKey)
        let dev = try await HIDPPDevice.open(channel: channel, index: index, cached: cached?.features)
        device = dev
        let staticInfo: StaticInfo
        if let cached, cached.features == dev.features {
            staticInfo = cached.info
        } else {
            staticInfo = try await readStaticInfo(dev)
        }
        info = staticInfo
        skipFirstMotion = (dev.version(of: FeatureID.reprogControlsV4) ?? 0) >= 5
        if let cachedSnap = cached?.snapshot {
            battery = cachedSnap.battery
            hw = cachedSnap.state
        }

        let id = staticInfo.id
        if agent.store.config.devices[id] == nil {
            var dc = DeviceConfig()
            dc.name = staticInfo.name
            dc.bindings = DefaultBindings.make(controls: Self.controlInfos(staticInfo), thumbwheel: staticInfo.thumb != nil)
            agent.store.update { $0.devices[id] = dc }
            Log.info("\(staticInfo.name): new device, using the default setup")
        } else if agent.store.config.devices[id]?.name != staticInfo.name {
            agent.store.update { $0.devices[id]?.name = staticInfo.name }
        }

        ready = true
        reachable = true
        snapshot = makeSnapshot(busy: true)
        agent.deviceChanged(self)

        await reconcile(force: true)
        let ms = Int((CACurrentMediaTime() - started) * 1000)
        Log.info("\(staticInfo.name) (\(id)) ready in \(ms) ms via \(connection.label)\(cached == nil ? "" : " (cached)")")

        await refreshDynamicState()
        if monitoring { await updateAnalytics() }
        publish(busy: false)
        agent.cache.put(cacheKey, CachedDevice(features: dev.features, info: staticInfo, snapshot: snapshot))
    }

    private func readStaticInfo(_ dev: HIDPPDevice) async throws -> StaticInfo {
        let transportInfo = channel.transport.info
        let name = (try? await dev.readName()).flatMap { $0.isEmpty ? nil : $0 } ?? transportInfo.product
        let kind = (try? await dev.readKind()) ?? .unknown
        let identity = dev.has(FeatureID.deviceFirmwareVersion) ? try? await dev.readIdentity() : nil
        var serial: String?
        if identity?.serialSupported == true {
            serial = (try? await dev.readSerialNumber()).flatMap { $0.isEmpty ? nil : $0 }
        }
        let model = identity?.primaryModelID ?? UInt16(truncatingIfNeeded: transportInfo.productID)
        let unit = identity?.unitID ?? ""
        let modelHex = String(format: "%04x", model)
        let id: String
        if !unit.isEmpty && unit != "00000000" {
            id = "\(modelHex)-\(unit)"
        } else if let serial {
            id = "\(modelHex)-\(serial)"
        } else {
            id = "\(modelHex)-\(transportInfo.serial.isEmpty ? cacheKey : transportInfo.serial)"
        }
        let controls = dev.has(FeatureID.reprogControlsV4) ? (try await dev.reprogControls()) : []
        let dpi = dev.dpiFeature != nil ? try? await dev.readDPI() : nil
        let smartShift = dev.smartShiftFeature != nil ? try? await dev.readSmartShift() : nil
        let wheel = dev.has(FeatureID.hiresWheel) ? try? await dev.wheelCapability() : nil
        let thumb = dev.has(FeatureID.thumbWheel) ? try? await dev.thumbwheelInfo() : nil
        var hostCount: Int?
        var namesWritable = false
        if dev.has(FeatureID.hostsInfo), let h = try? await dev.readHosts() {
            hostCount = h.hosts.count
            namesWritable = h.canWriteNames
            hw.hosts = h.hosts.map { HostEntry(index: $0.index, paired: $0.paired, bus: $0.bus, name: $0.name, current: $0.index == h.current) }
            hw.currentHost = h.current
        } else if dev.has(FeatureID.changeHost), let h = try? await dev.changeHostInfo() {
            hostCount = h.count
            hw.currentHost = h.current
        }
        if let dpi {
            hw.dpi = dpi.current
            baselineDPI = dpi.current
        }
        return StaticInfo(
            id: id, name: name, kind: kind, modelID: modelHex, unitID: unit, serial: serial,
            firmware: identity?.firmware ?? [],
            protocolVersion: "\(dev.protocolVersion.major).\(dev.protocolVersion.minor)",
            controls: controls, dpiRange: dpi?.range, dpiDefault: dpi?.defaultValue,
            smartShiftFeature: dev.smartShiftFeature, smartShiftTorque: smartShift?.torque != nil,
            smartShiftDefault: smartShift.map { Int($0.defaultAutoDisengage) },
            wheel: wheel, thumb: thumb, hostCount: hostCount, hostNamesWritable: namesWritable,
            haptics: dev.has(FeatureID.haptic), battery: dev.batteryFeature != nil,
            features: dev.features.entries.sorted { $0.index < $1.index })
    }

    private func refreshDynamicState() async {
        guard let dev = device, let info, !isClosed else { return }
        if info.battery, let b = try? await dev.readBattery() { battery = Self.batteryInfo(b) }
        if info.dpiRange != nil, let d = try? await dev.readDPI() {
            hw.dpi = d.current
            if baselineDPI == nil { baselineDPI = d.current }
        }
        if info.smartShiftFeature != nil, let s = try? await dev.readSmartShift() { apply(s) }
        if dev.has(FeatureID.hostsInfo), let h = try? await dev.readHosts() {
            hw.hosts = h.hosts.map { HostEntry(index: $0.index, paired: $0.paired, bus: $0.bus, name: $0.name, current: $0.index == h.current) }
            hw.currentHost = h.current
        } else if dev.has(FeatureID.changeHost), let h = try? await dev.changeHostInfo() {
            hw.currentHost = h.current
        }
        if info.haptics, let h = try? await dev.readHaptics() {
            hw.haptics = h.enabled
            hw.hapticsLevel = h.level
        }
        checkBattery()
    }

    private func apply(_ s: SmartShiftState) {
        hw.wheelMode = s.mode.rawValue
        hw.smartShiftThreshold = Int(s.autoDisengage)
        hw.smartShiftTorque = s.torque.map(Int.init)
    }

    // MARK: Publishing

    private var monitoring: Bool { agent.monitoring }

    private func publish(busy: Bool? = nil) {
        snapshot = makeSnapshot(busy: busy ?? snapshot?.busy ?? false)
        agent.deviceChanged(self)
        if let s = snapshot { agent.cache.updateSnapshot(cacheKey, s) }
    }

    static func controlInfos(_ info: StaticInfo) -> [ControlInfo] {
        let order: [ControlRole] = [.middle, .back, .forward, .gesture, .modeShift, .dpi, .hapticPanel, .scrollLeft, .scrollRight, .other]
        return info.controls
            .filter { $0.isDivertable && !$0.isVirtual }
            .sorted { (order.firstIndex(of: ControlRole(cid: $0.cid)) ?? 99) < (order.firstIndex(of: ControlRole(cid: $1.cid)) ?? 99) }
            .map { ControlInfo(cid: Int($0.cid), key: controlKey($0.cid), name: controlName($0.cid),
                               role: ControlRole(cid: $0.cid).rawValue, gestures: $0.supportsRawXY) }
    }

    private func makeSnapshot(busy: Bool) -> DeviceSnapshot? {
        guard let info else { return nil }
        var caps = Capabilities()
        if let r = info.dpiRange {
            switch r {
            case .range(let lo, let hi, let step):
                caps.dpi = DPICaps(min: lo, max: hi, step: step, values: nil, defaultValue: info.dpiDefault ?? lo)
            case .list(let values):
                caps.dpi = DPICaps(min: values.first ?? 0, max: values.last ?? 0, step: nil, values: values,
                                   defaultValue: info.dpiDefault ?? values.first ?? 0)
            }
        }
        caps.smartShift = info.smartShiftFeature != nil
        caps.smartShiftTorque = info.smartShiftTorque
        caps.smartShiftDefaultThreshold = info.smartShiftDefault
        caps.hiresWheel = info.wheel != nil
        caps.wheelMultiplier = info.wheel?.multiplier
        caps.thumbwheel = info.thumb != nil
        caps.thumbwheelTouch = info.thumb?.hasTouch ?? false
        caps.thumbwheelTap = info.thumb?.hasSingleTap ?? false
        caps.hosts = info.hostCount
        caps.hostNamesWritable = info.hostNamesWritable
        caps.haptics = info.haptics
        caps.battery = info.battery
        caps.gestures = info.controls.contains { $0.isDivertable && !$0.isVirtual && $0.supportsRawXY }
        return DeviceSnapshot(
            id: info.id, name: info.name, kind: info.kind.rawValue, modelID: info.modelID, unitID: info.unitID,
            serial: info.serial,
            firmware: info.firmware.map { FirmwareInfo(kind: Int($0.kind), name: $0.name, version: $0.version) },
            protocolVersion: info.protocolVersion, connection: connection,
            online: !isClosed && ready && reachable, busy: busy, battery: battery, capabilities: caps, state: hw,
            controls: Self.controlInfos(info),
            features: info.features.map { FeatureInfo(id: Int($0.id), name: featureName($0.id), version: Int($0.version), hidden: $0.isHidden) },
            activeProfile: profile?.id, error: nil)
    }

    static func batteryInfo(_ b: Battery) -> BatteryInfo {
        BatteryInfo(percent: b.approximatePercent, level: b.level?.rawValue, charging: b.isCharging, full: b.state == .full)
    }

    // MARK: Applying the configuration

    /// Applies settings and bindings; repeated calls while one runs are coalesced.
    func scheduleReconcile(force: Bool = false) {
        if force { reconcileForce = true }
        Task { await self.reconcile(force: false) }
    }

    private func reconcile(force: Bool) async {
        guard ready, reachable, !isClosed else { return }
        if force { reconcileForce = true }
        if reconciling {
            reconcileAgain = true
            return
        }
        reconciling = true
        repeat {
            reconcileAgain = false
            let f = reconcileForce
            reconcileForce = false
            resolveProfile()
            await applySettings(force: f)
            await applyBindings(force: f)
        } while (reconcileAgain || reconcileForce) && !isClosed
        reconciling = false
        publish()
    }

    private func resolveProfile() {
        let cfg = config
        let p = agent.store.config.general.appProfiles ? cfg.profile(for: agent.apps.current?.bundleID) : nil
        if p?.id != profile?.id { Log.debug("\(label): profile \(p?.name ?? "default")") }
        profile = p
        bindings = p.map { cfg.bindings.overlay($0.bindings) } ?? cfg.bindings
    }

    private func snapDPI(_ v: Int) -> Int { info?.dpiRange?.snap(v) ?? v }

    private func applySettings(force: Bool) async {
        guard let dev = device, let info else { return }
        let s = settings
        let prev = force ? nil : appliedSettings

        // Pointer resolution: an application profile wins over the device setting.
        if info.dpiRange != nil, dpiBeforeShift == nil, let target = (profile?.dpi ?? s.dpi ?? baselineDPI).map(snapDPI),
           force || target != hw.dpi {
            do {
                try await dev.setDPI(target)
                hw.dpi = target
            } catch {
                Log.error("\(label): cannot set DPI: \(error)")
            }
        }

        if info.smartShiftFeature != nil {
            let anySet = s.smartShift != nil || s.smartShiftThreshold != nil || s.wheelMode != nil || s.smartShiftTorque != nil
            let changed = prev == nil || prev?.smartShift != s.smartShift || prev?.smartShiftThreshold != s.smartShiftThreshold
                || prev?.wheelMode != s.wheelMode || prev?.smartShiftTorque != s.smartShiftTorque
            if anySet && changed {
                var disengage: UInt8?
                if s.smartShift == false {
                    disengage = SmartShiftState.alwaysRatchet
                } else if s.smartShift == true || s.smartShiftThreshold != nil {
                    disengage = UInt8(min(max(s.smartShiftThreshold ?? info.smartShiftDefault ?? 10, 1), 50))
                }
                let mode: WheelMode? = s.wheelMode.map { $0 == .freeSpin ? .freeSpin : .ratchet }
                let torque = info.smartShiftTorque ? s.smartShiftTorque.map { UInt8(min(max($0, 1), 100)) } : nil
                do {
                    try await dev.writeSmartShift(mode: mode, autoDisengage: disengage, torque: torque)
                    if let st = try? await dev.readSmartShift() { apply(st) }
                } catch {
                    Log.error("\(label): cannot set SmartShift: \(error)")
                }
            }
        }

        if info.haptics, s.haptics != nil || s.hapticsLevel != nil,
           prev == nil || prev?.haptics != s.haptics || prev?.hapticsLevel != s.hapticsLevel {
            let enabled = s.haptics ?? hw.haptics ?? true
            let level = s.hapticsLevel ?? hw.hapticsLevel ?? 60
            if (try? await dev.setHaptics(enabled: enabled, level: level)) != nil {
                hw.haptics = enabled
                hw.hapticsLevel = level
            }
        }
        appliedSettings = s
    }

    private func applyBindings(force: Bool) async {
        guard let dev = device, let info else { return }
        if !pressed.isEmpty {
            // Never change a control while it is held: its release would be lost.
            bindingsDirty = true
            return
        }
        bindingsDirty = false
        let act = agent.canPerformActions

        for c in info.controls where c.isDivertable && !c.isVirtual {
            let key = controlKey(c.cid)
            let action = act ? (bindings.buttons[key] ?? .default) : .default
            let want = Diversion(divert: action.needsDivert, rawXY: action.needsRawXY && c.supportsRawXY)
            if !force, applied[c.cid] == want { continue }
            do {
                try await dev.setControlReporting(c.cid, divert: want.divert, rawXY: c.supportsRawXY ? want.rawXY : nil)
                applied[c.cid] = want
            } catch {
                Log.error("\(label): cannot set up \(key): \(error)")
                if (error as? HIDPPError)?.isOffline == true { return }
            }
        }

        if let t = info.thumb {
            let binding = act ? (bindings.thumbwheel ?? .native) : .native
            let invert = settings.thumbwheelInvert ?? false
            let divert = binding.isDiverted
            // Natively macOS applies its own direction; the device makes up the difference.
            let nativeInvert = (natural != agent.systemNatural) != invert
            let want = ThumbState(diverted: divert, inverted: divert ? false : nativeInvert)
            if force || thumbApplied != want {
                do {
                    try await dev.setThumbwheelReporting(diverted: want.diverted, inverted: want.inverted)
                    thumbApplied = want
                } catch {
                    Log.error("\(label): cannot set up the thumb wheel: \(error)")
                }
            }
            thumbTracker = divert ? ThumbwheelTracker(binding: binding, divertedResolution: t.divertedResolution,
                                                      defaultDirection: t.defaultDirection, invert: invert) : nil
            hw.thumbwheelDiverted = divert
        }

        if let w = info.wheel {
            let smooth = act && settings.effectiveSmoothScroll
            let want = smooth
                ? WheelReporting(diverted: true, hiRes: true, inverted: false)
                : WheelReporting(diverted: false, hiRes: false, inverted: w.hasInvert && natural != agent.systemNatural)
            if force || wheelApplied != want {
                do {
                    let reply = try await dev.setWheelReporting(want)
                    wheelApplied = want
                    Log.debug("\(label): wheel reporting \(reply)")
                } catch {
                    Log.error("\(label): cannot set up the wheel: \(error)")
                }
            }
            if smooth {
                if wheelAccel == nil || wheelAccel?.speed != settings.effectiveScrollSpeed
                    || wheelAccel?.acceleration != settings.effectiveScrollAcceleration {
                    wheelAccel = WheelAccelerator(unitsPerNotch: w.multiplier, speed: settings.effectiveScrollSpeed,
                                                  acceleration: settings.effectiveScrollAcceleration)
                }
            } else {
                wheelAccel = nil
                scroller.stop()
            }
            hw.smoothScrolling = smooth
        }

        if monitoring || !analytics.isEmpty { await updateAnalytics() }
    }

    /// Analytics key events report presses of controls that keep their native function,
    /// so the app can light them up. Only while the app is open.
    func updateAnalytics() async {
        guard let dev = device, let info, ready, reachable else { return }
        let wanted: Set<UInt16> = monitoring
            ? Set(info.controls.filter { $0.supportsAnalytics && !(applied[$0.cid]?.divert ?? false) }.map(\.cid))
            : []
        for cid in analytics.subtracting(wanted) {
            try? await dev.setControlAnalytics(cid, enabled: false)
        }
        var now = analytics.intersection(wanted)
        for cid in wanted.subtracting(analytics) where (try? await dev.setControlAnalytics(cid, enabled: true)) != nil {
            now.insert(cid)
        }
        analytics = now
    }

    /// Gives every control its native behaviour back (pause, quit).
    func restoreNative() async {
        guard let dev = device, let info, ready, reachable, !isClosed else { return }
        releaseAllHeld()
        scroller.stop()
        for cid in analytics { try? await dev.setControlAnalytics(cid, enabled: false) }
        analytics = []
        for c in info.controls where c.isDivertable && !c.isVirtual && applied[c.cid] != Diversion(divert: false, rawXY: false) {
            try? await dev.setControlReporting(c.cid, divert: false, rawXY: c.supportsRawXY ? false : nil)
            applied[c.cid] = Diversion(divert: false, rawXY: false)
        }
        if info.thumb != nil, thumbApplied?.diverted != false {
            let inverted = (natural != agent.systemNatural) != (settings.thumbwheelInvert ?? false)
            try? await dev.setThumbwheelReporting(diverted: false, inverted: inverted)
            thumbApplied = ThumbState(diverted: false, inverted: inverted)
        }
        if let w = info.wheel, wheelApplied?.diverted != false || wheelApplied?.hiRes != false {
            let native = WheelReporting(diverted: false, hiRes: false, inverted: w.hasInvert && natural != agent.systemNatural)
            _ = try? await dev.setWheelReporting(native)
            wheelApplied = native
        }
    }

    // MARK: Device events

    func handle(_ report: Report) {
        guard ready, reachable, let dev = device, report.isFeatureEvent,
              let feature = dev.feature(atIndex: report.featureIndex) else { return }
        let p = report.params
        let fn = report.function
        switch feature {
        case FeatureID.reprogControlsV4:
            switch ReprogEvent.decode(function: fn, p) {
            case .divertedButtons(let cids)?: buttons(cids)
            case .rawXY(let dx, let dy)?: motion(Int(dx), Int(dy))
            case .analytics(let events)?:
                guard let id else { return }
                for (cid, down) in events where analytics.contains(cid) {
                    agent.emitButton(device: id, control: controlKey(cid), pressed: down)
                }
            case nil: break
            }
        case FeatureID.thumbWheel:
            if let e = ThumbwheelEvent.decode(function: fn, p) { thumb(e) }
        case FeatureID.hiresWheel:
            switch WheelEvent.decode(function: fn, p) {
            case .movement(let hiRes, _, let delta)?:
                wheel(hiRes ? Int(delta) : Int(delta) * (info?.wheel?.multiplier ?? 1))
            case .ratchet(let engaged)?:
                hw.wheelMode = engaged ? WheelMode.ratchet.rawValue : WheelMode.freeSpin.rawValue
                publish()
            case nil: break
            }
        case FeatureID.unifiedBattery, FeatureID.batteryStatus, FeatureID.batteryVoltage:
            if fn == 0, let b = Battery.decodeEvent(feature: feature, p) {
                battery = Self.batteryInfo(b)
                checkBattery()
                publish()
            }
        case FeatureID.wirelessDeviceStatus:
            if let e = WirelessStatusEvent.decode(function: fn, p), e.reconfigurationNeeded {
                Log.info("\(label) reset its settings; applying them again")
                applied.removeAll()
                wheelApplied = nil
                thumbApplied = nil
                appliedSettings = nil
                scheduleReconcile(force: true)
            }
        default:
            break
        }
    }

    private func buttons(_ now: [UInt16]) {
        let released = pressed.filter { !now.contains($0) }
        let newlyPressed = now.filter { !pressed.contains($0) }
        pressed = now
        for cid in released { release(cid) }
        for cid in newlyPressed { press(cid) }
        if pressed.isEmpty && bindingsDirty { scheduleReconcile() }
    }

    /// What a diverted control without a binding does (it is only diverted while gestures need it).
    private static func nativeAction(_ cid: UInt16) -> Action {
        switch ControlRole(cid: cid) {
        case .middle: return .mouse(.middle)
        case .back: return .mouse(.back)
        case .forward: return .mouse(.forward)
        case .left: return .mouse(.left)
        case .right: return .mouse(.right)
        case .modeShift: return .builtin("wheel-mode-toggle")
        case .scrollLeft: return .builtin("scroll-left")
        case .scrollRight: return .builtin("scroll-right")
        case .dpi: return .builtin("dpi-cycle")
        default: return .nothing
        }
    }

    private func press(_ cid: UInt16) {
        let key = controlKey(cid)
        if let id { agent.emitButton(device: id, control: key, pressed: true) }
        var action = bindings.buttons[key] ?? .default
        if action == .default { action = Self.nativeAction(cid) }
        if case .gestures(let set) = action {
            gesture = (cid, GestureTracker(set: set, skipFirst: skipFirstMotion))
        } else {
            perform(agent.executor.press(action))
        }
        held[cid] = action
    }

    private func release(_ cid: UInt16) {
        let key = controlKey(cid)
        if let id { agent.emitButton(device: id, control: key, pressed: false) }
        guard let action = held.removeValue(forKey: cid) else { return }
        if case .gestures = action {
            if let g = gesture, g.cid == cid {
                var tracker = g.tracker
                gesture = nil
                gestureOutputs(tracker.release(), key: key, set: tracker.set)
            }
        } else {
            perform(agent.executor.release(action))
        }
    }

    private func motion(_ dx: Int, _ dy: Int) {
        if monitoring, let id { agent.emitMotion(device: id, dx: dx, dy: dy) }
        guard var g = gesture else { return }
        let outputs = g.tracker.motion(dx: dx, dy: dy, dpi: hw.dpi ?? 1000)
        gesture = g
        if !outputs.isEmpty { gestureOutputs(outputs, key: controlKey(g.cid), set: g.tracker.set) }
    }

    private func gestureOutputs(_ outputs: [GestureOutput], key: String, set: GestureSet) {
        for o in outputs {
            switch o {
            case .fire(let d):
                if let id { agent.emitGesture(device: id, control: key, gesture: d.rawValue) }
                perform(agent.executor.run(set.action(d)))
            case .click:
                if let id { agent.emitGesture(device: id, control: key, gesture: "click") }
                perform(agent.executor.run(set.click))
            case .scroll(let dx, let dy):
                scroller.direct(dx: dx, dy: dy)
            case .zoom(let step):
                perform(agent.executor.run(.builtin(step > 0 ? "zoom-in" : "zoom-out")))
            }
        }
    }

    private func thumb(_ e: ThumbwheelEvent) {
        if monitoring, let id {
            if e.rotation != 0 && !thumbLit {
                thumbLit = true
                agent.emitButton(device: id, control: "thumbwheel", pressed: true)
            } else if e.rotation == 0 && e.status == .stop && thumbLit {
                thumbLit = false
                agent.emitButton(device: id, control: "thumbwheel", pressed: false)
            }
        }
        guard var tracker = thumbTracker else { return }
        let status: ThumbInput.Status
        switch e.status {
        case .start: status = .start
        case .active: status = .active
        case .stop: status = .stop
        case .inactive: status = .inactive
        }
        let outputs = tracker.event(ThumbInput(rotation: Int(e.rotation), status: status, singleTap: e.singleTap))
        thumbTracker = tracker
        for o in outputs {
            switch o {
            case .scroll(let raw):
                // Positive reveals content to the right; natural scrolling reverses it.
                let points = raw * (Tuning.thumbwheelPointsPerTurn / 520)
                scroller.add(dx: natural ? -points : points, dy: 0)
            case .step(let d):
                if case .actions(let left, let right, _) = tracker.binding {
                    perform(agent.executor.run(d == .left ? left : right))
                }
            case .zoom(let step):
                perform(agent.executor.run(.builtin(step > 0 ? "zoom-in" : "zoom-out")))
            case .tap:
                if let id {
                    agent.emitButton(device: id, control: "thumbwheel-tap", pressed: true)
                    agent.emitButton(device: id, control: "thumbwheel-tap", pressed: false)
                }
                if let a = bindings.thumbwheelTap { perform(agent.executor.run(a)) }
            }
        }
    }

    private func wheel(_ units: Int) {
        guard var accel = wheelAccel, units != 0 else { return }
        let points = accel.points(delta: units, time: CACurrentMediaTime()) * (Tuning.pointsPerNotch / WheelAccelerator.pointsPerNotch)
        wheelAccel = accel
        // Rolling away from you scrolls up (reveals what is above) unless scrolling is natural.
        scroller.add(dx: 0, dy: natural ? points : -points)
    }

    private func releaseAllHeld() {
        for (_, action) in held where !action.isGestures {
            _ = agent.executor.release(action)
        }
        held.removeAll()
        pressed.removeAll()
        gesture = nil
    }

    // MARK: Device operations

    func perform(_ request: DeviceRequest?) {
        guard let request else { return }
        switch request {
        case .scroll(let dx, let dy):
            scroller.add(dx: dx, dy: dy)
        case .setDPI(let d):
            setUserDPI(d)
        case .shiftDPI(let d):
            guard let dev = device, info?.dpiRange != nil else { return }
            if dpiBeforeShift == nil { dpiBeforeShift = hw.dpi ?? baselineDPI ?? 1000 }
            let v = snapDPI(d)
            Task {
                try? await dev.setDPI(v)
                self.hw.dpi = v
            }
        case .unshiftDPI:
            guard let dev = device, let back = dpiBeforeShift else { return }
            dpiBeforeShift = nil
            Task {
                try? await dev.setDPI(back)
                self.hw.dpi = back
                self.publish()
            }
        case .cycleDPI, .dpiUp, .dpiDown:
            guard let info, info.dpiRange != nil else { return }
            var presets = settings.dpiPresets.isEmpty ? DeviceSettings.defaultDPIPresets : settings.dpiPresets
            presets = Array(Set(presets.map(snapDPI))).sorted()
            let current = hw.dpi ?? baselineDPI ?? presets[0]
            let next: Int
            switch request {
            case .dpiUp: next = presets.first { $0 > current } ?? presets.last!
            case .dpiDown: next = presets.last { $0 < current } ?? presets.first!
            default: next = presets.first { $0 > current } ?? presets[0]
            }
            setUserDPI(next)
        case .toggleWheelMode:
            guard let dev = device, info?.smartShiftFeature != nil else { return }
            let toFree = hw.wheelMode != WheelMode.freeSpin.rawValue
            Task {
                do {
                    try await dev.writeSmartShift(mode: toFree ? .freeSpin : .ratchet, autoDisengage: nil, torque: nil)
                    self.hw.wheelMode = toFree ? WheelMode.freeSpin.rawValue : WheelMode.ratchet.rawValue
                    self.agent.osd(symbol: toFree ? "circle.dashed" : "dial.medium", title: toFree ? "Free Spin" : "Ratchet")
                    self.publish()
                } catch {
                    Log.error("\(self.label): cannot switch the wheel mode: \(error)")
                }
            }
        case .toggleSmartShift:
            guard let id, info?.smartShiftFeature != nil else { return }
            let on = !(hw.smartShiftEnabled ?? true)
            agent.store.update { $0.devices[id]?.settings.smartShift = on }
            agent.osd(symbol: "bolt.circle", title: on ? "SmartShift On" : "SmartShift Off")
            scheduleReconcile()
        case .toggleSmoothScroll:
            guard let id, info?.wheel != nil else { return }
            let on = !settings.effectiveSmoothScroll
            agent.store.update { $0.devices[id]?.settings.smoothScroll = on }
            agent.osd(symbol: "scroll", title: on ? "Smooth Scrolling" : "Classic Scrolling")
            scheduleReconcile()
        case .toggleScrollDirection:
            guard let id else { return }
            let toNatural = !natural
            agent.store.update { $0.devices[id]?.settings.scrollDirection = toNatural ? .natural : .standard }
            agent.osd(symbol: "arrow.up.arrow.down", title: toNatural ? "Natural Scrolling" : "Standard Scrolling")
            scheduleReconcile()
        case .showBattery:
            if let p = battery?.percent {
                agent.osd(symbol: Self.batterySymbol(battery), title: "\(info?.name ?? "Mouse")  \(p)%",
                          level: Double(p) / 100)
            }
        case .switchHost(let h):
            switchHost(h)
        case .nextHost:
            guard let count = info?.hostCount, count > 1 else { return }
            switchHost(((hw.currentHost ?? 0) + 1) % count)
        }
    }

    func setUserDPI(_ value: Int, osd: Bool = true) {
        guard let id, info?.dpiRange != nil else { return }
        let v = snapDPI(value)
        agent.store.update { $0.devices[id]?.settings.dpi = v }
        if osd { agent.osd(symbol: "scope", title: "\(v) DPI") }
        scheduleReconcile()
    }

    func switchHost(_ host: Int) {
        guard let dev = device else { return }
        Task {
            do {
                try await dev.switchHost(host)
                Log.info("\(self.label): switched to host \(host + 1)")
            } catch {
                Log.error("\(self.label): cannot switch host: \(error)")
            }
        }
    }

    func setHostName(_ host: Int, _ name: String) async throws {
        guard let dev = device else { throw HIDPPError.disconnected }
        try await dev.setHostName(host, name: name)
        if let h = try? await dev.readHosts() {
            hw.hosts = h.hosts.map { HostEntry(index: $0.index, paired: $0.paired, bus: $0.bus, name: $0.name, current: $0.index == h.current) }
        }
        publish()
    }

    /// Sends a raw HID++ request (diagnostics). Returns the reply bytes.
    func raw(_ bytes: [UInt8]) async throws -> String {
        guard bytes.count >= 3 else { throw HIDPPError.protocolError("need feature index, function and parameters") }
        let p = try await channel.featureCall(deviceIndex: index, featureIndex: bytes[0], function: bytes[1],
                                              params: Array(bytes.dropFirst(2)))
        return p.bytes.hexString
    }

    /// Feeds a fabricated report through the event path (diagnostics and tests).
    func inject(_ bytes: [UInt8]) {
        if let r = Report(bytes) { handle(r) }
    }

    // MARK: Battery

    static func batterySymbol(_ b: BatteryInfo?) -> String {
        guard let b else { return "battery.0percent" }
        if b.charging { return "battery.100percent.bolt" }
        switch b.percent ?? 50 {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func checkBattery() {
        guard let b = battery, let p = b.percent else { return }
        let threshold = agent.store.config.general.lowBatteryPercent
        if b.charging || p > threshold + 2 {
            batteryWarned = false
            return
        }
        if p <= threshold && !batteryWarned {
            batteryWarned = true
            agent.lowBattery(name: info?.name ?? "Mouse", percent: p)
        }
    }

    // MARK: Reacting to the rest of the system

    func configChanged() {
        scheduleReconcile()
    }

    func environmentChanged() {
        // Permissions, pause, frontmost app or the system scroll direction changed.
        scheduleReconcile()
    }
}
