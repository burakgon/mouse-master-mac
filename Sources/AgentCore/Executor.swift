import AppKit
import MouseMasterKit

/// Something only the device controller can do (it owns the device).
enum DeviceRequest {
    case setDPI(Int)
    case shiftDPI(Int)
    case unshiftDPI
    case cycleDPI
    case dpiUp
    case dpiDown
    case toggleWheelMode
    case toggleSmartShift
    case toggleSmoothScroll
    case toggleScrollDirection
    case showBattery
    case switchHost(Int)
    case nextHost
    /// Scroll by points through the device's smooth scroller.
    case scroll(dx: Double, dy: Double)
}

/// Performs actions. `press`/`release` give keys and mouse buttons hold semantics;
/// everything else fires on press.
@MainActor
final class ActionExecutor {
    let synth: InputSynth
    let hotKeys = SymbolicHotKeys()
    var frontmostBundleID: () -> String? = { nil }
    var openSettings: () -> Void = {}

    init(synth: InputSynth) {
        self.synth = synth
    }

    private enum Behavior {
        case combo(KeyCombo)
        case hotKey(Int32, fallback: KeyCombo?)
        case media(InputSynth.MediaKey)
        case mouse(MouseButton)
        case doubleClick
        case scroll(dx: Double, dy: Double)
        case device(DeviceRequest)
        case run(@MainActor (ActionExecutor) -> Void)
        case navigate(forward: Bool)
    }

    private static func k(_ code: Int, _ mods: Modifiers = []) -> KeyCombo { KeyCombo(keyCode: code, modifiers: mods) }

    private func behavior(_ id: String) -> Behavior? {
        typealias K = KeyCode
        switch id {
        case "mission-control": return .hotKey(SymbolicHotKeys.missionControl, fallback: Self.k(K.upArrow, .control))
        case "app-expose": return .hotKey(SymbolicHotKeys.appWindows, fallback: Self.k(K.downArrow, .control))
        case "show-desktop": return .hotKey(SymbolicHotKeys.showDesktop, fallback: Self.k(K.f11, .function))
        case "space-left": return .hotKey(SymbolicHotKeys.spaceLeft, fallback: Self.k(K.leftArrow, .control))
        case "space-right": return .hotKey(SymbolicHotKeys.spaceRight, fallback: Self.k(K.rightArrow, .control))
        case "apps": return .run { $0.openApp(["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"]) }
        case "app-switcher": return .combo(Self.k(K.tab, .command))
        case "notification-center": return .hotKey(SymbolicHotKeys.notificationCenter, fallback: nil)
        case "spotlight": return .hotKey(SymbolicHotKeys.spotlight, fallback: Self.k(K.space, .command))
        case "back": return .navigate(forward: false)
        case "forward": return .navigate(forward: true)
        case "page-up": return .combo(Self.k(K.pageUp))
        case "page-down": return .combo(Self.k(K.pageDown))
        case "home": return .combo(Self.k(K.upArrow, .command))
        case "end": return .combo(Self.k(K.downArrow, .command))
        case "return": return .combo(Self.k(K.returnKey))
        case "escape": return .combo(Self.k(K.escape))
        case "copy": return .combo(Self.k(K.c, .command))
        case "cut": return .combo(Self.k(K.x, .command))
        case "paste": return .combo(Self.k(K.v, .command))
        case "paste-plain": return .combo(Self.k(K.v, [.command, .option, .shift]))
        case "undo": return .combo(Self.k(K.z, .command))
        case "redo": return .combo(Self.k(K.z, [.command, .shift]))
        case "select-all": return .combo(Self.k(K.a, .command))
        case "find": return .combo(Self.k(K.f, .command))
        case "save": return .combo(Self.k(K.s, .command))
        case "new", "new-window": return .combo(Self.k(K.n, .command))
        case "print": return .combo(Self.k(K.p, .command))
        case "new-tab": return .combo(Self.k(K.t, .command))
        case "close-tab", "close-window": return .combo(Self.k(K.w, .command))
        case "reopen-tab": return .combo(Self.k(K.t, [.command, .shift]))
        case "next-tab": return .combo(Self.k(K.tab, .control))
        case "previous-tab": return .combo(Self.k(K.tab, [.control, .shift]))
        case "refresh": return .combo(Self.k(K.r, .command))
        case "zoom-in": return .combo(Self.k(K.equal, .command))
        case "zoom-out": return .combo(Self.k(K.minus, .command))
        case "zoom-reset": return .combo(Self.k(K.zero, .command))
        case "fullscreen": return .combo(Self.k(K.f, [.control, .command]))
        case "minimize": return .combo(Self.k(K.m, .command))
        case "hide-app": return .combo(Self.k(K.h, .command))
        case "quit-app": return .combo(Self.k(K.q, .command))
        case "tile-left": return .combo(Self.k(K.leftArrow, [.function, .control]))
        case "tile-right": return .combo(Self.k(K.rightArrow, [.function, .control]))
        case "tile-fill": return .combo(Self.k(K.f, [.function, .control]))
        case "tile-center": return .combo(Self.k(K.c, [.function, .control]))
        case "finder": return .run { $0.openApp(["/System/Library/CoreServices/Finder.app"]) }
        case "terminal": return .run { $0.openApp(["/System/Applications/Utilities/Terminal.app"]) }
        case "calculator": return .run { $0.openApp(["/System/Applications/Calculator.app"]) }
        case "play-pause": return .media(.play)
        case "next-track": return .media(.next)
        case "previous-track": return .media(.previous)
        case "volume-up": return .media(.volumeUp)
        case "volume-down": return .media(.volumeDown)
        case "mute": return .media(.mute)
        case "brightness-up": return .media(.brightnessUp)
        case "brightness-down": return .media(.brightnessDown)
        case "screenshot": return .hotKey(SymbolicHotKeys.screenshotOptions, fallback: Self.k(K.five, [.command, .shift]))
        case "screenshot-region": return .hotKey(SymbolicHotKeys.screenshotRegionFile, fallback: Self.k(K.four, [.command, .shift]))
        case "screenshot-screen": return .hotKey(SymbolicHotKeys.screenshotFile, fallback: Self.k(K.three, [.command, .shift]))
        case "lock-screen": return .combo(Self.k(K.q, [.control, .command]))
        case "display-sleep": return .run { _ in ActionExecutor.shell("/usr/bin/pmset displaysleepnow") }
        case "emoji": return .combo(Self.k(K.space, [.control, .command]))
        case "look-up": return .combo(Self.k(K.d, [.control, .command]))
        case "quick-note": return .hotKey(SymbolicHotKeys.quickNote, fallback: Self.k(K.q, .function))
        case "input-source": return .hotKey(SymbolicHotKeys.previousInputSource, fallback: Self.k(K.space, .control))
        case "left-click": return .mouse(.left)
        case "right-click": return .mouse(.right)
        case "middle-click": return .mouse(.middle)
        case "double-click": return .doubleClick
        case "scroll-up": return .scroll(dx: 0, dy: -WheelAccelerator.pointsPerNotch * 2)
        case "scroll-down": return .scroll(dx: 0, dy: WheelAccelerator.pointsPerNotch * 2)
        case "scroll-left": return .scroll(dx: -WheelAccelerator.pointsPerNotch * 2, dy: 0)
        case "scroll-right": return .scroll(dx: WheelAccelerator.pointsPerNotch * 2, dy: 0)
        case "dpi-cycle": return .device(.cycleDPI)
        case "dpi-up": return .device(.dpiUp)
        case "dpi-down": return .device(.dpiDown)
        case "wheel-mode-toggle": return .device(.toggleWheelMode)
        case "smartshift-toggle": return .device(.toggleSmartShift)
        case "smooth-scroll-toggle": return .device(.toggleSmoothScroll)
        case "scroll-direction-toggle": return .device(.toggleScrollDirection)
        case "show-battery": return .device(.showBattery)
        case "next-host": return .device(.nextHost)
        case "mouse-master": return .run { $0.openSettings() }
        default: return nil
        }
    }

    // MARK: Back and forward

    /// Apps where Back/Forward are ⌘[ and ⌘] (mouse buttons 4 and 5 do nothing there).
    private static let bracketNavigation: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.apple.finder", "com.apple.systempreferences",
        "com.apple.AppStore", "com.apple.Music", "com.apple.TV", "com.apple.podcasts", "com.apple.Dictionary",
        "com.apple.helpviewer", "com.apple.iBooksX", "com.apple.Maps", "com.apple.news", "com.apple.stocks",
        "com.apple.weather", "com.apple.Passwords", "com.apple.Home",
    ]
    /// Xcode navigates with ⌃⌘← and ⌃⌘→.
    private static let arrowNavigation: Set<String> = ["com.apple.dt.Xcode"]

    private func navigationBehavior(forward: Bool) -> Behavior {
        let app = frontmostBundleID() ?? ""
        if Self.bracketNavigation.contains(app) {
            return .combo(Self.k(forward ? KeyCode.rightBracket : KeyCode.leftBracket, .command))
        }
        if Self.arrowNavigation.contains(app) {
            return .combo(Self.k(forward ? KeyCode.rightArrow : KeyCode.leftArrow, [.control, .command]))
        }
        // Browsers, editors and most other apps understand the mouse buttons themselves.
        return .mouse(forward ? .forward : .back)
    }

    // MARK: Running actions

    private var heldNavigation: [String: Behavior] = [:]

    /// The control was pressed. Returns work for the device controller, if any.
    func press(_ action: Action) -> DeviceRequest? {
        switch action {
        case .default, .nothing, .gestures:
            return nil
        case .keys(let combo):
            synth.press(combo)
            return nil
        case .mouse(let b):
            synth.mouse(b, down: true)
            return nil
        case .builtin(let id):
            guard var b = behavior(id) else {
                Log.error("unknown action \(id)")
                return nil
            }
            if case .navigate(let forward) = b {
                b = navigationBehavior(forward: forward)
                heldNavigation[id] = b
            }
            return begin(b)
        case .shiftDPI(let dpi):
            return .shiftDPI(dpi)
        default:
            return run(action)
        }
    }

    func release(_ action: Action) -> DeviceRequest? {
        switch action {
        case .keys(let combo):
            synth.release(combo)
        case .mouse(let b):
            synth.mouse(b, down: false)
        case .builtin(let id):
            var b = behavior(id)
            if case .navigate? = b { b = heldNavigation.removeValue(forKey: id) }
            if let b { end(b) }
        case .shiftDPI:
            return .unshiftDPI
        default:
            break
        }
        return nil
    }

    /// Performs an action once (gesture directions, wheel steps, the menu, the app).
    @discardableResult
    func run(_ action: Action) -> DeviceRequest? {
        switch action {
        case .default, .nothing, .gestures:
            return nil
        case .keys(let combo):
            synth.tap(combo)
        case .mouse(let b):
            synth.click(b)
        case .builtin(let id):
            guard var b = behavior(id) else { return nil }
            if case .navigate(let forward) = b { b = navigationBehavior(forward: forward) }
            let request = begin(b)
            end(b)
            return request
        case .command(let cmd):
            Self.shell(cmd)
        case .open(let target):
            open(target)
        case .shortcut(let name):
            Self.run("/usr/bin/shortcuts", ["run", name])
        case .text(let s):
            synth.type(s)
        case .setDPI(let d):
            return .setDPI(d)
        case .shiftDPI(let d):
            return .setDPI(d)
        case .switchHost(let h):
            return .switchHost(h)
        case .macro(let steps):
            runMacro(steps)
        }
        return nil
    }

    private func begin(_ b: Behavior) -> DeviceRequest? {
        switch b {
        case .combo(let c): synth.press(c)
        case .hotKey(let id, let fallback):
            if !hotKeys.post(id, synth: synth), let fallback { synth.tap(fallback) }
        case .media(let key): synth.media(key, down: true)
        case .mouse(let m): synth.mouse(m, down: true)
        case .doubleClick: synth.click(.left, count: 2)
        case .scroll(let dx, let dy): return .scroll(dx: dx, dy: dy)
        case .device(let r): return r
        case .run(let f): f(self)
        case .navigate: break
        }
        return nil
    }

    private func end(_ b: Behavior) {
        switch b {
        case .combo(let c): synth.release(c)
        case .media(let key): synth.media(key, down: false)
        case .mouse(let m): synth.mouse(m, down: false)
        default: break
        }
    }

    private var macroTask: Task<Void, Never>?

    private func runMacro(_ steps: [MacroStep]) {
        macroTask?.cancel()
        macroTask = Task { @MainActor [weak self] in
            for step in steps {
                guard let self, !Task.isCancelled else { return }
                switch step {
                case .keys(let k): self.synth.tap(k)
                case .builtin(let id): self.run(.builtin(id))
                case .click(let b): self.synth.click(b)
                case .delay(let ms): try? await Task.sleep(nanoseconds: UInt64(max(ms, 0)) * 1_000_000)
                case .command(let c): Self.shell(c)
                case .text(let t): self.synth.type(t)
                }
                // Let the target app process each step.
                try? await Task.sleep(nanoseconds: 12_000_000)
            }
        }
    }

    // MARK: Apps, files and commands

    func openApp(_ candidates: [String]) {
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
            return
        }
    }

    func open(_ target: String) {
        let t = target.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: t), let scheme = url.scheme, scheme.count > 1, !t.hasPrefix("/") {
            NSWorkspace.shared.open(url)
            return
        }
        let path = (t as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if path.hasSuffix(".app") {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            } else {
                NSWorkspace.shared.open(url)
            }
            return
        }
        // A bundle identifier.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: t) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else {
            Log.error("cannot open \(t)")
        }
    }

    static func shell(_ command: String) {
        run("/bin/zsh", ["-lc", command])
    }

    static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        do {
            try p.run()
        } catch {
            Log.error("cannot run \(path): \(error)")
        }
    }
}

/// Smooth zoom: turns zoom amounts into a trackpad pinch, spread over display frames so the
/// zoom glides. The pinch ends a moment after the last input.
@MainActor
final class PinchZoomer {
    private let synth: InputSynth
    private var pending = 0.0          // zoom still to apply, on a log scale
    private var active = false
    private var timer: DispatchSourceTimer?
    private var lastTick: CFTimeInterval = 0
    private var lastInput: CFTimeInterval = 0
    private var endRequested = false
    private var activity: NSObjectProtocol?
    private static let interval = 1.0 / 120.0
    private static let tau = 0.045
    /// How long without input before the pinch is over.
    private static let idleEnd = 0.25

    init(synth: InputSynth) {
        self.synth = synth
    }

    /// Positive zooms in; ln(2) doubles the zoom.
    func add(_ logScale: Double) {
        guard logScale.isFinite, logScale != 0 else { return }
        pending += logScale
        lastInput = CACurrentMediaTime()
        endRequested = false
        if !active {
            active = true
            synth.pinch(0, phase: .began)
        }
        if timer == nil {
            start()
            tick()
        }
    }

    /// The input is over (wheel stopped, button released): end once the rest has played out.
    func finish() {
        guard active else { return }
        endRequested = true
    }

    func cancel() {
        pending = 0
        if active { synth.pinch(0, phase: .ended) }
        active = false
        stopTimer()
    }

    private func start() {
        lastTick = CACurrentMediaTime() - Self.interval
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        t.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .microseconds(500))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = t
        t.resume()
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                             reason: "Smooth zoom")
        }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now
        if pending != 0 {
            var step = pending * (1 - exp(-dt / Self.tau))
            if abs(pending) < 0.0008 { step = pending }
            pending -= step
            synth.pinch(exp(step) - 1, phase: .changed)
        }
        let idle = now - lastInput
        if pending == 0 && (endRequested || idle > Self.idleEnd) {
            synth.pinch(0, phase: .ended)
            active = false
            endRequested = false
            stopTimer()
        }
    }
}

/// Spreads scroll distance over display frames so wheel notches glide instead of jump.
@MainActor
final class SmoothScroller {
    private let synth: InputSynth
    private var animator = ScrollAnimator(tau: Tuning.smoothing)
    private var timer: DispatchSourceTimer?
    private var lastTick: CFTimeInterval = 0
    private var carryX = 0.0, carryY = 0.0
    private var activity: NSObjectProtocol?
    private static let interval = 1.0 / 120.0

    init(synth: InputSynth) {
        self.synth = synth
    }

    /// Animated scrolling (wheel notches).
    func add(dx: Double, dy: Double) {
        animator.add(dx: dx, dy: dy)
        if timer == nil {
            start()
            tick() // the first part goes out right away
        }
    }

    /// Unanimated scrolling that follows the hand (pan gestures).
    func direct(dx: Double, dy: Double) {
        carryX += dx
        carryY += dy
        let x = carryX.rounded(.towardZero), y = carryY.rounded(.towardZero)
        carryX -= x
        carryY -= y
        if x != 0 || y != 0 { synth.scroll(dx: Int(x), dy: Int(y)) }
    }

    func stop() {
        animator.stop()
        carryX = 0
        carryY = 0
        stopTimer()
    }

    private func start() {
        lastTick = CACurrentMediaTime() - Self.interval
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        t.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .microseconds(500))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = t
        t.resume()
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                             reason: "Smooth scrolling")
        }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now
        let (x, y) = animator.step(dt: dt)
        if x != 0 || y != 0 { synth.scroll(dx: x, dy: y) }
        if animator.isIdle { stopTimer() }
    }
}
