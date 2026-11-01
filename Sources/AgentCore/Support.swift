import AppKit
import ApplicationServices
import IOKit.hid
import MouseMasterKit
import os

enum Log {
    private static let logger = Logger(subsystem: "com.burakgon.MouseMaster", category: "agent")
    nonisolated(unsafe) static var verbose = false
    nonisolated(unsafe) static var traceHIDPP = false

    static func info(_ message: @autoclosure () -> String) {
        let m = message()
        logger.info("\(m, privacy: .public)")
        if verbose { FileHandle.standardError.write(Data("[\(stamp())] \(m)\n".utf8)) }
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        let m = message()
        logger.debug("\(m, privacy: .public)")
        FileHandle.standardError.write(Data("[\(stamp())] \(m)\n".utf8))
    }

    static func error(_ message: @autoclosure () -> String) {
        let m = message()
        logger.error("\(m, privacy: .public)")
        if verbose { FileHandle.standardError.write(Data("[\(stamp())] ERROR \(m)\n".utf8)) }
    }

    private static func stamp() -> String {
        let t = Date().timeIntervalSince1970
        let ms = Int((t - floor(t)) * 1000)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date()) + String(format: ".%03d", ms)
    }
}

// MARK: - Configuration persistence

@MainActor
final class ConfigStore {
    private(set) var config = Config()
    private var saveItem: DispatchWorkItem?

    func load() {
        do {
            config = try Config.load(from: MMPaths.configURL)
            Log.info("loaded configuration (\(config.devices.count) devices)")
        } catch {
            // Keep the broken file for the user and start fresh.
            Log.error("cannot read configuration: \(error); starting with defaults")
            let broken = MMPaths.configURL.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.moveItem(at: MMPaths.configURL, to: broken)
            config = Config()
        }
    }

    func update(_ change: (inout Config) -> Void) {
        let before = config
        change(&config)
        if config != before { scheduleSave() }
    }

    func replace(_ new: Config) {
        config = new
        scheduleSave()
    }

    private func scheduleSave() {
        saveItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    func saveNow() {
        saveItem?.cancel()
        saveItem = nil
        do {
            try config.save(to: MMPaths.configURL)
        } catch {
            Log.error("cannot save configuration: \(error)")
        }
    }
}

// MARK: - Frontmost application

@MainActor
final class FrontmostAppWatcher {
    private(set) var current: ActiveApp?
    var onChange: ((ActiveApp?) -> Void)?
    private var observer: NSObjectProtocol?

    func start() {
        current = Self.describe(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self else { return }
                let described = Self.describe(app)
                guard described != self.current else { return }
                self.current = described
                self.onChange?(described)
            }
        }
    }

    static func describe(_ app: NSRunningApplication?) -> ActiveApp? {
        guard let app, let id = app.bundleIdentifier else { return nil }
        return ActiveApp(bundleID: id, name: app.localizedName ?? id)
    }
}

// MARK: - Permissions

@MainActor
final class PermissionWatcher {
    private(set) var accessibility = AXIsProcessTrusted()
    var inputMonitoringNeeded = false
    var onChange: (() -> Void)?
    /// Tries the devices macOS refused to open again; true while some still cannot be opened.
    var retryDeniedDevices: (() -> Bool)?
    /// The permission is there, but this process still cannot use it.
    var onNeedsRelaunch: (() -> Void)?
    private var timer: Timer?
    private var prompted = false
    private var grantedSince: Date?

    var inputMonitoring: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }

    /// Never prompts by itself: the app asks when the user opens it, with an explanation.
    func start() {
        if !accessibility { startPolling() }
    }

    func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: !prompted] as CFDictionary)
        prompted = true
    }

    /// macOS refused to open a device: remember it, and wait for the user to allow it.
    func markInputMonitoringNeeded() {
        inputMonitoringNeeded = true
        startPolling()
    }

    func requestInputMonitoring() {
        inputMonitoringNeeded = true
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        startPolling()
    }

    private func startPolling() {
        guard timer == nil else { return }
        // Cheap and only while something is missing.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let ax = AXIsProcessTrusted()
        var changed = false
        if ax != accessibility {
            accessibility = ax
            changed = true
            Log.info("accessibility permission \(ax ? "granted" : "revoked")")
        }
        if inputMonitoringNeeded {
            if retryDeniedDevices?() == false {
                inputMonitoringNeeded = false
                grantedSince = nil
                changed = true
                Log.info("Input Monitoring allowed; devices opened")
            } else if inputMonitoring {
                // Allowed, yet still refused: some macOS versions only honour it in a new process.
                if let since = grantedSince {
                    if Date().timeIntervalSince(since) > 3 { onNeedsRelaunch?() }
                } else {
                    grantedSince = Date()
                }
            }
        }
        if accessibility && !inputMonitoringNeeded {
            timer?.invalidate()
            timer = nil
        }
        if changed { onChange?() }
    }

    /// Accessibility can be revoked while running; check again before relying on it.
    func recheck() {
        let ax = AXIsProcessTrusted()
        if ax != accessibility {
            accessibility = ax
            if !ax { startPolling() }
            onChange?()
        }
    }
}

// MARK: - Other tools that take over the mouse

@MainActor
final class ConflictWatcher {
    static let known: [String: String] = [
        "com.naotanhaocan.BetterMouse": "BetterMouse",
        "com.logi.optionsplus": "Logi Options+",
        "com.logi.cp-dev-mgr": "Logi Options+",
        "com.logitech.manager.daemon": "Logitech Options",
        "com.logitech.LogiOptionsPlus.agent": "Logi Options+",
        "com.plentycom.app.SteerMouse": "SteerMouse",
        "com.plentycom.SteerMouse": "SteerMouse",
        "com.nuebling.mac-mouse-fix": "Mac Mouse Fix",
        "com.nuebling.mac-mouse-fix.helper": "Mac Mouse Fix",
        "com.lujjjh.LinearMouse": "LinearMouse",
        "com.caldis.Mos": "Mos",
        "com.pilotmoon.scroll-reverser": "Scroll Reverser",
        "com.smoothscroll.SmoothScroll": "SmoothScroll",
    ]

    private(set) var running: [ConflictInfo] = []
    /// Called with true when one of them quit (settings should be applied again).
    var onChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    func start() {
        refresh(quit: false)
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let quit = name == NSWorkspace.didTerminateApplicationNotification
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let id = app?.bundleIdentifier, ConflictWatcher.matches(id) else { return }
                MainActor.assumeIsolated { self?.refresh(quit: quit) }
            })
        }
    }

    static func matches(_ bundleID: String) -> Bool {
        known[bundleID] != nil || bundleID.lowercased().contains("logioptionsplus")
    }

    private func refresh(quit: Bool) {
        var found: [ConflictInfo] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, Self.matches(id) else { continue }
            let name = Self.known[id] ?? app.localizedName ?? id
            if !found.contains(where: { $0.name == name }) {
                found.append(ConflictInfo(id: id, name: name, pid: app.processIdentifier))
            }
        }
        let changed = found != running
        running = found
        if changed || quit { onChange?(quit) }
    }

    func quit(_ bundleID: String) {
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundleID {
            if !app.terminate() { app.forceTerminate() }
        }
    }
}

// MARK: - System scroll direction

enum NaturalScrolling {
    /// The system setting shared by trackpads and mice ("Natural scrolling").
    static var current: Bool {
        let key = "com.apple.swipescrolldirection" as CFString
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return (CFPreferencesCopyAppValue(key, kCFPreferencesAnyApplication) as? Bool) ?? true
    }
}

// MARK: - What is under the pointer

/// The window server sends scroll and gesture events to the window under the pointer,
/// which need not belong to the frontmost application.
@MainActor
enum PointerTarget {
    private static var chromium: [String: Bool] = [:]
    /// Bundles laid out differently that are Chromium all the same.
    private static let chromiumBundleIDs: Set<String> = ["company.thebrowser.Browser", "company.thebrowser.dia"]

    /// Whether the window under the pointer belongs to a Chromium browser (see `ChromiumPinch`).
    /// `defaults write com.burakgon.MouseMaster ChromiumPinchOpening -bool false` turns this off.
    static func isChromiumBrowser() -> Bool {
        guard UserDefaults.standard.object(forKey: "ChromiumPinchOpening") as? Bool ?? true,
              let pid = windowOwnerUnderPointer(),
              let app = NSRunningApplication(processIdentifier: pid), let url = app.bundleURL else { return false }
        if let known = chromium[url.path] { return known }
        let result = app.bundleIdentifier.map(chromiumBundleIDs.contains) == true || isChromiumBrowser(bundle: url)
        chromium[url.path] = result
        return result
    }

    /// Owner of the frontmost window under the pointer, floating windows and panels included
    /// (they get the events). The Dock level and above is left out: the Dock spans the whole
    /// screen and lets the pointer through, and so do many overlays up there. Taking the wrong
    /// window can only make `isChromiumBrowser` answer no.
    static func windowOwnerUnderPointer() -> pid_t? {
        guard let point = CGEvent(source: nil)?.location,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let me = getpid()
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        for w in windows {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer >= 0, layer < dockLevel,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point) else { continue }
            return pid
        }
        return nil
    }

    /// Chromium browsers keep their helper apps inside "<Name> Framework.framework"; Electron
    /// apps keep them next to it (and leave pinch zoom off).
    nonisolated static func isChromiumBrowser(bundle: URL) -> Bool {
        let fm = FileManager.default
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        guard let items = try? fm.contentsOfDirectory(atPath: frameworks.path) else { return false }
        for name in items where name.hasSuffix(".framework") && name != "Electron Framework.framework" {
            let helpers = frameworks.appendingPathComponent(name).appendingPathComponent("Versions/Current/Helpers")
            if let h = try? fm.contentsOfDirectory(atPath: helpers.path), h.contains(where: { $0.hasSuffix("Helper (Renderer).app") }) {
                return true
            }
        }
        return false
    }
}

/// Hidden knobs for the feel of scrolling, read once at start:
///   defaults write com.burakgon.MouseMaster ScrollSmoothing -float 0.065
///   defaults write com.burakgon.MouseMaster ScrollPointsPerNotch -float 42
///   defaults write com.burakgon.MouseMaster ThumbwheelPointsPerTurn -float 520
enum Tuning {
    private static func value(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
        guard let v = UserDefaults.standard.object(forKey: key) as? Double else { return fallback }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    static let smoothing = value("ScrollSmoothing", 0.065, 0.005...0.4)
    static let pointsPerNotch = value("ScrollPointsPerNotch", 42, 5...300)
    static let thumbwheelPointsPerTurn = value("ThumbwheelPointsPerTurn", 520, 50...3000)
}
