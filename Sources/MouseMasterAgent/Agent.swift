import AppKit
import HIDPP
import MouseMasterKit
import ServiceManagement
import UserNotifications

/// Ties everything together: configuration, devices, actions, the menu bar and clients.
@MainActor
final class Agent {
    static let shared = Agent()

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    let store = ConfigStore()
    let cache = DeviceCache()
    let synth = InputSynth()
    let apps = FrontmostAppWatcher()
    let permissions = PermissionWatcher()
    let conflicts = ConflictWatcher()
    let hud = HUD()
    lazy var executor = ActionExecutor(synth: synth)
    lazy var devices = DeviceManager(agent: self)
    lazy var server = IPCServer(agent: self)
    lazy var statusMenu = StatusMenu(agent: self)

    private(set) var systemNatural = NaturalScrolling.current
    private var offline: [String: DeviceSnapshot] = [:]
    private var publishScheduled = false
    private var observers: [NSObjectProtocol] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var terminating = false

    /// Actions can only be performed with the Accessibility permission; without it every
    /// control keeps its native function so nothing stops working.
    var canPerformActions: Bool { permissions.accessibility && !store.config.general.paused }
    var monitoring: Bool { server.monitoring }

    func start() {
        MMPaths.ensureSupportDirectory()
        store.load()
        cache.load()

        executor.frontmostBundleID = { [weak self] in self?.apps.current?.bundleID }
        executor.openSettings = { Agent.openSettingsApp() }

        permissions.onChange = { [weak self] in
            guard let self else { return }
            if self.devices.retryDenied() && self.permissions.inputMonitoring {
                // Some macOS versions only honour a new Input Monitoring grant in a new process.
                Log.info("Input Monitoring was allowed; restarting to open the devices")
                self.relaunch()
                return
            }
            self.environmentChanged()
        }
        permissions.start()

        server.start()

        apps.onChange = { [weak self] app in
            guard let self else { return }
            Log.debug("frontmost: \(app?.bundleID ?? "none")")
            if self.store.config.general.appProfiles {
                for c in self.devices.controllers { c.environmentChanged() }
            }
            self.setNeedsPublish()
        }
        apps.start()

        conflicts.onChange = { [weak self] quit in
            guard let self else { return }
            if !self.conflicts.running.isEmpty {
                Log.info("also running: \(self.conflicts.running.map(\.name).joined(separator: ", "))")
            }
            if quit {
                // It may have left controls diverted; take them back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    MainActor.assumeIsolated {
                        for c in self.devices.controllers { c.scheduleReconcile(force: true) }
                    }
                }
            }
            self.setNeedsPublish()
        }
        conflicts.start()

        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: NSNotification.Name("SwipeScrollDirectionDidChangeNotification"),
                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemScrollDirectionChanged() }
        })
        let wnc = NSWorkspace.shared.notificationCenter
        observers.append(wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Devices may have lost their settings while the Mac slept.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.permissions.recheck()
                    for c in self.devices.controllers { c.scheduleReconcile(force: true) }
                }
            }
        })

        devices.start()
        statusMenu.update()
        installSignalHandlers()
        Log.info("Mouse Master agent \(version) started (accessibility: \(permissions.accessibility))")
    }

    // MARK: State

    func setNeedsPublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.publishScheduled = false
                self.publishNow()
            }
        }
    }

    private func publishNow() {
        if server.hasSubscribers { server.broadcastState(makeState()) }
        statusMenu.update()
    }

    func makeState() -> AgentState {
        var byID: [String: DeviceSnapshot] = [:]
        for s in cache.snapshots where store.config.devices[s.id] != nil {
            var x = s
            x.online = false
            x.busy = false
            byID[s.id] = x
        }
        for (id, s) in offline { byID[id] = s }
        for c in devices.controllers {
            if let s = c.snapshot { byID[s.id] = s }
        }
        let list = byID.values.sorted {
            if $0.online != $1.online { return $0.online }
            return $0.name < $1.name
        }
        return AgentState(
            agentVersion: version, devices: list, config: store.config,
            permissions: Permissions(accessibility: permissions.accessibility,
                                     inputMonitoringNeeded: permissions.inputMonitoringNeeded,
                                     inputMonitoring: permissions.inputMonitoring),
            activeApp: apps.current, conflicts: conflicts.running, systemNaturalScrolling: systemNatural)
    }

    /// Online devices first.
    var onlineControllers: [DeviceController] {
        devices.controllers.filter { $0.snapshot?.online == true }
    }

    func deviceChanged(_ c: DeviceController) {
        if let id = c.id { offline.removeValue(forKey: id) }
        setNeedsPublish()
    }

    func deviceWentOffline(_ s: DeviceSnapshot) {
        offline[s.id] = s
        setNeedsPublish()
    }

    // MARK: Events for the app

    func emitButton(device: String, control: String, pressed: Bool) {
        guard monitoring else { return }
        server.broadcastEvent(IPCMessage(event: "button", device: device, control: control, pressed: pressed))
    }

    func emitGesture(device: String, control: String, gesture: String) {
        guard monitoring else { return }
        server.broadcastEvent(IPCMessage(event: "gesture", device: device, control: control, gesture: gesture))
    }

    func emitMotion(device: String, dx: Int, dy: Int) {
        server.broadcastEvent(IPCMessage(event: "motion", device: device, dx: dx, dy: dy))
    }

    func monitoringChanged() {
        for c in devices.controllers {
            Task { await c.updateAnalytics() }
        }
    }

    // MARK: Changes

    func setDeviceConfig(_ id: String, _ config: DeviceConfig) {
        store.update { $0.devices[id] = config }
        devices.controller(for: id)?.configChanged()
        setNeedsPublish()
    }

    func setGeneral(_ general: General) {
        let before = store.config.general
        store.update { $0.general = general }
        if before.paused != general.paused || before.appProfiles != general.appProfiles {
            if before.paused != general.paused {
                Log.info(general.paused ? "paused" : "resumed")
                osd(symbol: general.paused ? "pause.circle" : "play.circle",
                    title: general.paused ? "Mouse Master Paused" : "Mouse Master Resumed")
            }
            environmentChanged()
        }
        setNeedsPublish()
    }

    func environmentChanged() {
        for c in devices.controllers { c.environmentChanged() }
        setNeedsPublish()
    }

    private func systemScrollDirectionChanged() {
        let now = NaturalScrolling.current
        guard now != systemNatural else { return }
        systemNatural = now
        Log.info("system scroll direction is now \(now ? "natural" : "standard")")
        environmentChanged()
    }

    func forgetDevice(_ id: String) {
        store.update { $0.devices.removeValue(forKey: id) }
        cache.forget(deviceID: id)
        offline.removeValue(forKey: id)
        setNeedsPublish()
    }

    func resetDevice(_ id: String) {
        guard let c = devices.controller(for: id), let snap = c.snapshot else {
            store.update { $0.devices.removeValue(forKey: id) }
            setNeedsPublish()
            return
        }
        var dc = DeviceConfig()
        dc.name = snap.name
        dc.bindings = DefaultBindings.make(controls: snap.controls, thumbwheel: snap.capabilities.thumbwheel)
        store.update { $0.devices[id] = dc }
        c.scheduleReconcile(force: true)
        setNeedsPublish()
    }

    // MARK: Feedback

    func osd(symbol: String, title: String, level: Double? = nil) {
        guard store.config.general.osd else { return }
        hud.show(symbol: symbol, title: title, level: level)
    }

    func lowBattery(name: String, percent: Int) {
        Log.info("\(name) battery low: \(percent)%")
        osd(symbol: "battery.25percent", title: "\(name)  \(percent)%", level: Double(percent) / 100)
        // Notifications need a bundle (not available when run from a terminal).
        guard store.config.general.notifications, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(name) battery is low"
            content.body = "\(percent)% left. Charge it soon to keep it going."
            center.add(UNNotificationRequest(identifier: "low-battery-\(name)", content: content, trigger: nil))
        }
    }

    static func openSettingsApp() {
        // The settings app is the bundle this agent lives in.
        var url = Bundle.main.bundleURL
        for _ in 0..<4 { url.deleteLastPathComponent() }
        if url.pathExtension == "app" {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MMPaths.appBundleID) {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }

    // MARK: Quitting

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.terminate() }
            }
            s.resume()
            signalSources.append(s)
        }
    }

    /// Starts a fresh copy of the agent and quits this one.
    func relaunch() {
        if getppid() == 1 {
            // Under launchd: an unsuccessful exit makes it start the agent again.
            terminate(code: 75)
            return
        }
        SingleInstance.release()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Agent.shared.terminate() } }
        }
    }

    /// Gives every control its native function back, then exits.
    func terminate(code: Int32 = 0) {
        guard !terminating else { return }
        terminating = true
        Log.info("stopping")
        store.saveNow()
        cache.saveNow()
        server.stop()
        let controllers = devices.controllers
        Task {
            await withTaskGroup(of: Void.self) { group in
                for c in controllers {
                    group.addTask { @MainActor in await c.restoreNative() }
                }
            }
            exit(code)
        }
        // Never hang on a device that does not answer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { exit(code) }
    }
}
