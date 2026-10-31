import AppKit
import MouseMasterKit
import Observation
import ServiceManagement

enum Page: String, CaseIterable, Identifiable, Hashable {
    case buttons, pointScroll, easySwitch, info, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .buttons: return "Buttons"
        case .pointScroll: return "Point & Scroll"
        case .easySwitch: return "Easy-Switch"
        case .info: return "Device Info"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .buttons: return "cursorarrow.click.2"
        case .pointScroll: return "scroll"
        case .easySwitch: return "laptopcomputer.and.arrow.down"
        case .info: return "info.circle"
        case .settings: return "gearshape"
        }
    }
}

/// Mirrors the agent's state and sends it the user's changes.
@Observable
@MainActor
final class AppModel {
    var state: AgentState?
    var connected = false
    var connecting = true
    var selectedDeviceID: String?
    var page: Page = .buttons
    var selectedControl: String?
    /// nil edits the bindings for all applications.
    var selectedProfileID: String?
    /// Controls held down right now (live highlighting).
    var pressed: Set<String> = []
    /// The last recognised gesture, for feedback in the gesture editor.
    var lastGesture: (control: String, gesture: String, at: Date)?
    var agentStatus = AgentLauncher.Status.unknown

    @ObservationIgnored private let connection = AgentConnection()
    @ObservationIgnored private var retryTimer: Timer?
    @ObservationIgnored private var lastLocalEdit = Date.distantPast
    @ObservationIgnored private var pendingSends: [String: DispatchWorkItem] = [:]
    @ObservationIgnored private var lastSent: [String: Date] = [:]
    @ObservationIgnored private var launchAttempts = 0

    init() {
        connection.onMessage = { [weak self] msg in
            MainActor.assumeIsolated { self?.received(msg) }
        }
        connection.onDisconnect = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.connected = false
                self.pressed.removeAll()
                self.scheduleReconnect()
            }
        }
    }

    func start() {
        agentStatus = AgentLauncher.status
        // Launch arguments open a page directly: --page pointScroll --control gesture
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--page"), i + 1 < args.count, let p = Page(rawValue: args[i + 1]) { page = p }
        if let i = args.firstIndex(of: "--control"), i + 1 < args.count { selectedControl = args[i + 1] }
        connect()
    }

    private func connect() {
        guard !connected else { return }
        if connection.connect() {
            connected = true
            connecting = false
            retryTimer?.invalidate()
            retryTimer = nil
            connection.send(IPCRequest(cmd: "hello", flag: true)) { [weak self] reply in
                MainActor.assumeIsolated {
                    if let s = reply.state { self?.apply(s) }
                }
            }
        } else {
            if launchAttempts == 0 {
                AgentLauncher.ensureRunning()
                agentStatus = AgentLauncher.status
            } else if launchAttempts == 6 || launchAttempts % 40 == 0 {
                AgentLauncher.reregister()
                agentStatus = AgentLauncher.status
            }
            launchAttempts += 1
            connecting = launchAttempts < 20
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.connect() }
        }
    }

    func restartAgent() {
        launchAttempts = 0
        connecting = true
        AgentLauncher.restart()
    }

    private func received(_ msg: IPCMessage) {
        switch msg.event {
        case "state":
            if let s = msg.state { apply(s) }
        case "button":
            guard let c = msg.control, msg.device == selectedDeviceID else { return }
            if msg.pressed == true {
                pressed.insert(c)
            } else {
                pressed.remove(c)
            }
        case "gesture":
            guard let c = msg.control, let g = msg.gesture, msg.device == selectedDeviceID else { return }
            lastGesture = (c, g, Date())
        default:
            break
        }
    }

    private func apply(_ incoming: AgentState) {
        var s = incoming
        // Keep what the user is editing right now instead of an older echo.
        if Date().timeIntervalSince(lastLocalEdit) < 0.6, let local = state?.config {
            s.config = local
        }
        state = s
        if let id = selectedDeviceID, !s.devices.contains(where: { $0.id == id }) {
            selectedDeviceID = nil
        }
        if selectedDeviceID == nil {
            selectedDeviceID = s.devices.first(where: \.online)?.id ?? s.devices.first?.id
        }
        if let pid = selectedProfileID, deviceConfig?.profiles.contains(where: { $0.id == pid }) != true {
            selectedProfileID = nil
        }
    }

    // MARK: Convenience

    var device: DeviceSnapshot? {
        guard let id = selectedDeviceID else { return nil }
        return state?.devices.first { $0.id == id }
    }

    var deviceConfig: DeviceConfig? {
        guard let id = selectedDeviceID else { return nil }
        return state?.config.devices[id] ?? DeviceConfig()
    }

    var general: General { state?.config.general ?? General() }

    var selectedProfile: AppProfile? {
        guard let pid = selectedProfileID else { return nil }
        return deviceConfig?.profiles.first { $0.id == pid }
    }

    /// The scroll direction this mouse ends up with.
    var naturalScrolling: Bool {
        if let d = deviceConfig?.settings.scrollDirection { return d == .natural }
        return state?.systemNaturalScrolling ?? true
    }

    // MARK: Editing

    func editDevice(throttle: Bool = false, _ change: (inout DeviceConfig) -> Void) {
        guard let id = selectedDeviceID, var s = state else { return }
        var cfg = s.config.devices[id] ?? DeviceConfig()
        change(&cfg)
        guard cfg != s.config.devices[id] else { return }
        s.config.devices[id] = cfg
        state = s
        lastLocalEdit = Date()
        send(key: "device-\(id)", throttle: throttle) { [weak self] in
            guard let self, let latest = self.state?.config.devices[id] else { return }
            self.connection.send(IPCRequest(cmd: "set-device-config", device: id, deviceConfig: latest))
        }
    }

    func editGeneral(_ change: (inout General) -> Void) {
        guard var s = state else { return }
        var g = s.config.general
        change(&g)
        guard g != s.config.general else { return }
        s.config.general = g
        state = s
        lastLocalEdit = Date()
        connection.send(IPCRequest(cmd: "set-general", general: g))
    }

    /// Sliders send at most every 60 ms, and always their final value.
    private func send(key: String, throttle: Bool, _ work: @escaping @MainActor () -> Void) {
        pendingSends[key]?.cancel()
        let now = Date()
        let last = lastSent[key] ?? .distantPast
        if !throttle || now.timeIntervalSince(last) > 0.06 {
            lastSent[key] = now
            work()
            return
        }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.lastSent[key] = Date()
                work()
            }
        }
        pendingSends[key] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: item)
    }

    func command(_ request: IPCRequest, completion: ((IPCMessage) -> Void)? = nil) {
        connection.send(request) { reply in
            MainActor.assumeIsolated { completion?(reply) }
        }
    }

    // MARK: Bindings (with application profiles)

    func action(for control: String) -> Action {
        guard let cfg = deviceConfig else { return .default }
        if let p = selectedProfile, let a = p.bindings.buttons[control] { return a }
        return cfg.bindings.buttons[control] ?? .default
    }

    func isOverridden(_ control: String) -> Bool {
        selectedProfile?.bindings.buttons[control] != nil
    }

    func setAction(_ action: Action, for control: String) {
        let pid = selectedProfileID
        editDevice { cfg in
            if let pid, let i = cfg.profiles.firstIndex(where: { $0.id == pid }) {
                cfg.profiles[i].bindings.buttons[control] = action
            } else if action == .default {
                cfg.bindings.buttons.removeValue(forKey: control)
            } else {
                cfg.bindings.buttons[control] = action
            }
        }
    }

    /// Drops a profile's own setting so the control does what it does everywhere else.
    func clearOverride(_ control: String) {
        guard let pid = selectedProfileID else { return }
        editDevice { cfg in
            guard let i = cfg.profiles.firstIndex(where: { $0.id == pid }) else { return }
            if control == "thumbwheel" {
                cfg.profiles[i].bindings.thumbwheel = nil
            } else if control == "thumbwheel-tap" {
                cfg.profiles[i].bindings.thumbwheelTap = nil
            } else {
                cfg.profiles[i].bindings.buttons.removeValue(forKey: control)
            }
        }
    }

    var thumbwheelBinding: ThumbwheelBinding {
        if let t = selectedProfile?.bindings.thumbwheel { return t }
        return deviceConfig?.bindings.thumbwheel ?? .native
    }

    var thumbwheelOverridden: Bool { selectedProfile?.bindings.thumbwheel != nil }

    func setThumbwheel(_ binding: ThumbwheelBinding, throttle: Bool = false) {
        let pid = selectedProfileID
        editDevice(throttle: throttle) { cfg in
            if let pid, let i = cfg.profiles.firstIndex(where: { $0.id == pid }) {
                cfg.profiles[i].bindings.thumbwheel = binding
            } else {
                cfg.bindings.thumbwheel = binding
            }
        }
    }

    var thumbwheelTap: Action {
        if let t = selectedProfile?.bindings.thumbwheelTap { return t }
        return deviceConfig?.bindings.thumbwheelTap ?? .default
    }

    func setThumbwheelTap(_ action: Action) {
        let pid = selectedProfileID
        editDevice { cfg in
            if let pid, let i = cfg.profiles.firstIndex(where: { $0.id == pid }) {
                cfg.profiles[i].bindings.thumbwheelTap = action
            } else {
                cfg.bindings.thumbwheelTap = action == .default ? nil : action
            }
        }
    }

    // MARK: Profiles

    func addProfile(name: String, bundleID: String) {
        if let existing = deviceConfig?.profiles.first(where: { $0.apps.contains(bundleID) }) {
            selectedProfileID = existing.id
            return
        }
        let p = AppProfile(name: name, apps: [bundleID])
        editDevice { $0.profiles.append(p) }
        selectedProfileID = p.id
    }

    func removeProfile(_ id: String) {
        editDevice { $0.profiles.removeAll { $0.id == id } }
        if selectedProfileID == id { selectedProfileID = nil }
    }

    func setProfileEnabled(_ id: String, _ enabled: Bool) {
        editDevice { cfg in
            if let i = cfg.profiles.firstIndex(where: { $0.id == id }) { cfg.profiles[i].enabled = enabled }
        }
    }
}

/// Registers, starts and restarts the background agent.
enum AgentLauncher {
    enum Status: Equatable {
        case unknown, enabled, requiresApproval, notRegistered, notFound, unavailable
    }

    static var service: SMAppService { SMAppService.agent(plistName: MMPaths.agentPlistName) }

    static var agentAppURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/MouseMasterAgent.app")
    }

    static var isBundled: Bool { FileManager.default.fileExists(atPath: agentAppURL.path) }

    static var status: Status {
        guard isBundled else { return .unavailable }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    /// Registers the launch agent again. macOS ties the registration to the app's signature,
    /// so it has to be renewed whenever the app is updated.
    static func reregister() {
        guard isBundled else { return }
        try? service.unregister()
        do {
            try service.register()
        } catch {
            NSLog("Mouse Master: cannot register the agent: \(error)")
        }
        if service.status == .enabled {
            kickstart(restart: false)
        } else {
            NSWorkspace.shared.openApplication(at: agentAppURL, configuration: .init())
        }
    }

    /// Registers the launch agent if needed and makes sure it is running.
    static func ensureRunning() {
        guard isBundled else { return }
        if service.status != .enabled {
            do {
                try service.register()
            } catch {
                NSLog("Mouse Master: cannot register the agent: \(error)")
            }
        }
        if service.status == .enabled {
            kickstart(restart: false)
        } else {
            // Not allowed to run at login: run it for this session anyway.
            NSWorkspace.shared.openApplication(at: agentAppURL, configuration: .init())
        }
    }

    static func restart() {
        reregister()
    }

    private static func kickstart(restart: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart"] + (restart ? ["-k"] : []) + ["gui/\(getuid())/\(MMPaths.agentLabel)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    static func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
                kickstart(restart: false)
            } else {
                try service.unregister()
                // Keep it running until logout.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    NSWorkspace.shared.openApplication(at: agentAppURL, configuration: .init())
                }
            }
        } catch {
            NSLog("Mouse Master: launch at login: \(error)")
        }
    }
}
