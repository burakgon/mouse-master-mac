import Foundation

public enum ActionCategory: String, CaseIterable, Sendable {
    case desktop = "Mission Control & Spaces"
    case navigation = "Navigation"
    case editing = "Editing"
    case tabs = "Tabs & Browser"
    case zoom = "Zoom"
    case windows = "Windows & Apps"
    case media = "Media & Display"
    case system = "System"
    case mouse = "Mouse"
    case device = "Mouse Settings"

    public var symbol: String {
        switch self {
        case .desktop: return "rectangle.3.group"
        case .navigation: return "arrow.left.arrow.right"
        case .editing: return "doc.on.doc"
        case .tabs: return "safari"
        case .zoom: return "plus.magnifyingglass"
        case .windows: return "macwindow"
        case .media: return "playpause"
        case .system: return "gearshape"
        case .mouse: return "computermouse"
        case .device: return "dial.medium"
        }
    }
}

/// A built-in action. The agent knows how to perform each one.
public struct BuiltinAction: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let category: ActionCategory
    public let symbol: String
    /// The keyboard shortcut it stands for, shown next to the title.
    public let hint: String?

    public init(_ id: String, _ title: String, _ category: ActionCategory, _ symbol: String, _ hint: String? = nil) {
        self.id = id
        self.title = title
        self.category = category
        self.symbol = symbol
        self.hint = hint
    }
}

public enum Catalog {
    public static let actions: [BuiltinAction] = [
        // Mission Control & Spaces
        .init("mission-control", "Mission Control", .desktop, "rectangle.3.group"),
        .init("app-expose", "App Exposé", .desktop, "rectangle.stack"),
        .init("show-desktop", "Show Desktop", .desktop, "menubar.dock.rectangle"),
        .init("space-left", "Previous Space", .desktop, "arrow.left.square", "⌃←"),
        .init("space-right", "Next Space", .desktop, "arrow.right.square", "⌃→"),
        .init("apps", "Apps", .desktop, "square.grid.3x3"),
        .init("app-switcher", "App Switcher", .desktop, "square.on.square", "⌘⇥"),
        .init("notification-center", "Notification Center", .desktop, "bell.badge"),
        .init("spotlight", "Spotlight", .desktop, "magnifyingglass", "⌘Space"),

        // Navigation
        .init("back", "Back", .navigation, "chevron.backward"),
        .init("forward", "Forward", .navigation, "chevron.forward"),
        .init("page-up", "Page Up", .navigation, "chevron.up", "⇞"),
        .init("page-down", "Page Down", .navigation, "chevron.down", "⇟"),
        .init("home", "Top of Page", .navigation, "arrow.up.to.line", "⌘↑"),
        .init("end", "Bottom of Page", .navigation, "arrow.down.to.line", "⌘↓"),
        .init("return", "Return", .navigation, "return", "↩"),
        .init("escape", "Escape", .navigation, "escape", "⎋"),

        // Editing
        .init("copy", "Copy", .editing, "doc.on.doc", "⌘C"),
        .init("cut", "Cut", .editing, "scissors", "⌘X"),
        .init("paste", "Paste", .editing, "doc.on.clipboard", "⌘V"),
        .init("paste-plain", "Paste and Match Style", .editing, "doc.plaintext", "⌥⇧⌘V"),
        .init("undo", "Undo", .editing, "arrow.uturn.backward", "⌘Z"),
        .init("redo", "Redo", .editing, "arrow.uturn.forward", "⇧⌘Z"),
        .init("select-all", "Select All", .editing, "selection.pin.in.out", "⌘A"),
        .init("find", "Find", .editing, "doc.text.magnifyingglass", "⌘F"),
        .init("save", "Save", .editing, "square.and.arrow.down", "⌘S"),
        .init("new", "New", .editing, "plus.square", "⌘N"),
        .init("print", "Print", .editing, "printer", "⌘P"),

        // Tabs & Browser
        .init("new-tab", "New Tab", .tabs, "plus.rectangle.on.rectangle", "⌘T"),
        .init("close-tab", "Close Tab or Window", .tabs, "xmark.rectangle", "⌘W"),
        .init("reopen-tab", "Reopen Closed Tab", .tabs, "arrow.uturn.backward.circle", "⇧⌘T"),
        .init("next-tab", "Next Tab", .tabs, "chevron.right.2", "⌃⇥"),
        .init("previous-tab", "Previous Tab", .tabs, "chevron.left.2", "⌃⇧⇥"),
        .init("refresh", "Reload", .tabs, "arrow.clockwise", "⌘R"),

        // Zoom
        .init("zoom-in", "Zoom In", .zoom, "plus.magnifyingglass", "⌘+"),
        .init("zoom-out", "Zoom Out", .zoom, "minus.magnifyingglass", "⌘−"),
        .init("zoom-reset", "Actual Size", .zoom, "1.magnifyingglass", "⌘0"),

        // Windows & Apps
        .init("fullscreen", "Full Screen", .windows, "arrow.up.left.and.arrow.down.right", "⌃⌘F"),
        .init("minimize", "Minimize Window", .windows, "minus.rectangle", "⌘M"),
        .init("hide-app", "Hide App", .windows, "eye.slash", "⌘H"),
        .init("close-window", "Close Window", .windows, "xmark.square", "⌘W"),
        .init("quit-app", "Quit App", .windows, "power", "⌘Q"),
        .init("new-window", "New Window", .windows, "macwindow.badge.plus", "⌘N"),
        .init("tile-left", "Tile Window Left", .windows, "rectangle.lefthalf.filled", "fn⌃←"),
        .init("tile-right", "Tile Window Right", .windows, "rectangle.righthalf.filled", "fn⌃→"),
        .init("tile-fill", "Fill Screen", .windows, "rectangle.inset.filled", "fn⌃F"),
        .init("tile-center", "Center Window", .windows, "rectangle.center.inset.filled", "fn⌃C"),
        .init("finder", "Finder", .windows, "folder"),
        .init("terminal", "Terminal", .windows, "terminal"),
        .init("calculator", "Calculator", .windows, "plus.forwardslash.minus"),

        // Media & Display
        .init("play-pause", "Play / Pause", .media, "playpause"),
        .init("next-track", "Next Track", .media, "forward.end"),
        .init("previous-track", "Previous Track", .media, "backward.end"),
        .init("volume-up", "Volume Up", .media, "speaker.wave.3"),
        .init("volume-down", "Volume Down", .media, "speaker.wave.1"),
        .init("mute", "Mute", .media, "speaker.slash"),
        .init("brightness-up", "Brightness Up", .media, "sun.max"),
        .init("brightness-down", "Brightness Down", .media, "sun.min"),

        // System
        .init("screenshot", "Screenshot & Recording", .system, "camera.viewfinder", "⇧⌘5"),
        .init("screenshot-region", "Screenshot of a Region", .system, "rectangle.dashed", "⇧⌘4"),
        .init("screenshot-screen", "Screenshot of the Screen", .system, "display", "⇧⌘3"),
        .init("lock-screen", "Lock Screen", .system, "lock", "⌃⌘Q"),
        .init("display-sleep", "Turn Display Off", .system, "moon.zzz"),
        .init("emoji", "Emoji & Symbols", .system, "face.smiling", "⌃⌘Space"),
        .init("look-up", "Look Up", .system, "character.book.closed", "⌃⌘D"),
        .init("quick-note", "Quick Note", .system, "note.text", "fn Q"),
        .init("input-source", "Next Input Source", .system, "globe", "⌃Space"),

        // Mouse
        .init("left-click", "Left Click", .mouse, "cursorarrow.click"),
        .init("right-click", "Right Click", .mouse, "cursorarrow.click.2"),
        .init("middle-click", "Middle Click", .mouse, "computermouse"),
        .init("double-click", "Double Click", .mouse, "cursorarrow.click.badge.clock"),
        .init("scroll-up", "Scroll Up", .mouse, "arrow.up"),
        .init("scroll-down", "Scroll Down", .mouse, "arrow.down"),
        .init("scroll-left", "Scroll Left", .mouse, "arrow.left"),
        .init("scroll-right", "Scroll Right", .mouse, "arrow.right"),

        // Mouse settings
        .init("dpi-cycle", "Cycle Pointer Speed", .device, "speedometer"),
        .init("dpi-up", "Pointer Speed Up", .device, "hare"),
        .init("dpi-down", "Pointer Speed Down", .device, "tortoise"),
        .init("wheel-mode-toggle", "Ratchet / Free Spin", .device, "dial.medium"),
        .init("smartshift-toggle", "Toggle SmartShift", .device, "bolt.circle"),
        .init("smooth-scroll-toggle", "Toggle Smooth Scrolling", .device, "scroll"),
        .init("scroll-direction-toggle", "Toggle Scroll Direction", .device, "arrow.up.arrow.down"),
        .init("show-battery", "Show Battery Level", .device, "battery.75percent"),
        .init("next-host", "Switch to Next Computer", .device, "arrow.triangle.2.circlepath"),
        .init("mouse-master", "Open Mouse Master", .device, "slider.horizontal.3"),
    ]

    public static let byID: [String: BuiltinAction] = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })

    public static func action(_ id: String) -> BuiltinAction? { byID[id] }
}

/// What a control does when it is not remapped.
public enum NativeBehavior {
    public static func title(role: String) -> String {
        switch role {
        case "left": return "Left Click"
        case "right": return "Right Click"
        case "middle": return "Middle Click"
        case "back": return "Back Button"
        case "forward": return "Forward Button"
        case "gesture": return "Nothing"
        case "mode-shift": return "Ratchet / Free Spin"
        case "scroll-left": return "Scroll Left"
        case "scroll-right": return "Scroll Right"
        case "dpi": return "Cycle Pointer Speed"
        case "haptic-panel": return "Nothing"
        case "thumbwheel": return "Horizontal Scroll"
        default: return "Native Function"
        }
    }

    public static func symbol(role: String) -> String {
        switch role {
        case "left": return "cursorarrow.click"
        case "right": return "cursorarrow.click.2"
        case "middle": return "computermouse"
        case "back": return "chevron.backward"
        case "forward": return "chevron.forward"
        case "gesture": return "hand.raised"
        case "mode-shift": return "dial.medium"
        case "thumbwheel": return "arrow.left.and.right"
        case "dpi": return "speedometer"
        default: return "circle"
        }
    }
}

public extension Action {
    /// A short description for buttons and callouts.
    func title(role: String) -> String {
        switch self {
        case .default: return NativeBehavior.title(role: role)
        case .nothing: return "Do Nothing"
        case .builtin(let id): return Catalog.action(id)?.title ?? id
        case .keys(let k): return k.label
        case .mouse(let b): return b.title
        case .command: return "Run Command"
        case .open(let target): return "Open \(Self.displayName(ofTarget: target))"
        case .shortcut(let name): return name.isEmpty ? "Run Shortcut" : name
        case .text: return "Type Text"
        case .setDPI(let d): return "\(d) DPI"
        case .shiftDPI(let d): return "Precision (\(d) DPI)"
        case .switchHost(let h): return "Computer \(h + 1)"
        case .gestures(let set):
            switch set.mode {
            case .directional: return "Gestures"
            case .pan: return "Pan & Scroll"
            case .zoom: return "Zoom"
            }
        case .macro(let steps): return steps.count == 1 ? "Macro (1 step)" : "Macro (\(steps.count) steps)"
        }
    }

    var symbol: String {
        switch self {
        case .default: return "arrow.uturn.backward.circle"
        case .nothing: return "nosign"
        case .builtin(let id): return Catalog.action(id)?.symbol ?? "questionmark.circle"
        case .keys: return "keyboard"
        case .mouse: return "computermouse"
        case .command: return "terminal"
        case .open: return "arrow.up.forward.app"
        case .shortcut: return "square.2.layers.3d"
        case .text: return "character.cursor.ibeam"
        case .setDPI, .shiftDPI: return "scope"
        case .switchHost: return "laptopcomputer.and.arrow.down"
        case .gestures(let set):
            switch set.mode {
            case .directional: return "hand.draw"
            case .pan: return "arrow.up.and.down.and.arrow.left.and.right"
            case .zoom: return "plus.magnifyingglass"
            }
        case .macro: return "list.bullet.rectangle"
        }
    }

    static func displayName(ofTarget target: String) -> String {
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            return URL(string: target)?.host ?? target
        }
        let last = (target as NSString).lastPathComponent
        if last.hasSuffix(".app") { return String(last.dropLast(4)) }
        return last.isEmpty ? target : last
    }
}

/// Ready-made gesture sets.
public struct GesturePreset: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let set: GestureSet
}

public enum GesturePresets {
    public static let all: [GesturePreset] = {
        var desktop = GestureSet()
        desktop.up = .builtin("mission-control")
        desktop.down = .builtin("app-expose")
        desktop.left = .builtin("space-left")
        desktop.right = .builtin("space-right")
        desktop.click = .builtin("mission-control")

        var media = GestureSet()
        media.up = .builtin("volume-up")
        media.down = .builtin("volume-down")
        media.left = .builtin("previous-track")
        media.right = .builtin("next-track")
        media.click = .builtin("play-pause")
        media.repeatVertical = true
        media.thresholdMM = 5

        var windows = GestureSet()
        windows.up = .builtin("tile-fill")
        windows.down = .builtin("minimize")
        windows.left = .builtin("tile-left")
        windows.right = .builtin("tile-right")
        windows.click = .builtin("app-expose")

        var browser = GestureSet()
        browser.up = .builtin("new-tab")
        browser.down = .builtin("close-tab")
        browser.left = .builtin("previous-tab")
        browser.right = .builtin("next-tab")
        browser.click = .builtin("reopen-tab")

        var zoom = GestureSet()
        zoom.mode = .zoom
        zoom.click = .builtin("zoom-reset")

        var pan = GestureSet()
        pan.mode = .pan
        pan.click = .builtin("middle-click")

        return [
            GesturePreset(id: "desktop", title: "Mission Control & Spaces", symbol: "rectangle.3.group", set: desktop),
            GesturePreset(id: "media", title: "Media & Volume", symbol: "playpause", set: media),
            GesturePreset(id: "windows", title: "Window Tiling", symbol: "rectangle.split.2x1", set: windows),
            GesturePreset(id: "browser", title: "Browser Tabs", symbol: "safari", set: browser),
            GesturePreset(id: "zoom", title: "Zoom", symbol: "plus.magnifyingglass", set: zoom),
            GesturePreset(id: "pan", title: "Pan & Scroll", symbol: "arrow.up.and.down.and.arrow.left.and.right", set: pan),
        ]
    }()
}

/// Thumb wheel modes offered in the app.
public struct ThumbwheelPreset: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let binding: ThumbwheelBinding
}

public enum ThumbwheelPresets {
    public static let all: [ThumbwheelPreset] = [
        .init(id: "scroll", title: "Smooth Horizontal Scroll", symbol: "arrow.left.and.right", binding: .scroll(speed: 1)),
        .init(id: "native", title: "macOS Horizontal Scroll", symbol: "arrow.left.arrow.right", binding: .native),
        .init(id: "zoom", title: "Smooth Zoom", symbol: "plus.magnifyingglass", binding: .zoom(speed: 1)),
        .init(id: "zoom-keys", title: "Zoom with ⌘+ and ⌘−", symbol: "plus.square.on.square",
              binding: .actions(left: .builtin("zoom-out"), right: .builtin("zoom-in"), stepDegrees: 15)),
        .init(id: "volume", title: "Volume", symbol: "speaker.wave.2",
              binding: .actions(left: .builtin("volume-down"), right: .builtin("volume-up"), stepDegrees: 15)),
        .init(id: "brightness", title: "Brightness", symbol: "sun.max",
              binding: .actions(left: .builtin("brightness-down"), right: .builtin("brightness-up"), stepDegrees: 15)),
        .init(id: "tabs", title: "Switch Tabs", symbol: "chevron.left.2",
              binding: .actions(left: .builtin("previous-tab"), right: .builtin("next-tab"), stepDegrees: 25)),
        .init(id: "spaces", title: "Switch Spaces", symbol: "rectangle.3.group",
              binding: .actions(left: .builtin("space-left"), right: .builtin("space-right"), stepDegrees: 40)),
        .init(id: "undo", title: "Undo / Redo", symbol: "arrow.uturn.backward",
              binding: .actions(left: .builtin("undo"), right: .builtin("redo"), stepDegrees: 20)),
        .init(id: "tracks", title: "Previous / Next Track", symbol: "forward.end",
              binding: .actions(left: .builtin("previous-track"), right: .builtin("next-track"), stepDegrees: 40)),
    ]

    /// The preset a binding corresponds to, or nil for custom actions.
    public static func match(_ binding: ThumbwheelBinding) -> ThumbwheelPreset? {
        switch binding {
        case .native: return all.first { $0.id == "native" }
        case .scroll: return all.first { $0.id == "scroll" }
        case .zoom: return all.first { $0.id == "zoom" }
        case .actions(let l, let r, _):
            return all.first {
                if case .actions(let pl, let pr, _) = $0.binding { return pl == l && pr == r }
                return false
            }
        }
    }
}

public enum DefaultBindings {
    /// What a mouse does out of the box: gestures on the gesture button, Back and Forward
    /// that work in every app, and smooth horizontal scrolling with the thumb wheel.
    public static func make(controls: [ControlInfo], thumbwheel: Bool) -> Bindings {
        var b = Bindings()
        for c in controls {
            switch c.role {
            case "gesture" where c.gestures: b.buttons[c.key] = .gestures(GesturePresets.all[0].set)
            case "back": b.buttons[c.key] = .builtin("back")
            case "forward": b.buttons[c.key] = .builtin("forward")
            default: break
            }
        }
        if thumbwheel { b.thumbwheel = .scroll(speed: 1) }
        return b
    }
}
