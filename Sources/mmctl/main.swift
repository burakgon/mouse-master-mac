import Foundation
import MouseMasterKit

// mmctl: command line client for the Mouse Master agent.

let usage = """
usage: mmctl <command> [arguments]

  status                       devices, battery and the main settings
  state                        the full agent state as JSON
  watch                        follow button presses, gestures and changes
  actions                      list built-in actions
  set [--device ID] KEY=VALUE  change a device setting, e.g.
                                 dpi=1600 smoothScroll=true scrollSpeed=1.2
                                 scrollDirection=natural|standard|system
                                 smartShift=true smartShiftThreshold=12
                                 wheelMode=ratchet|free-spin thumbwheelInvert=false
  bind [--device ID] CONTROL ACTION
                               CONTROL: middle, back, forward, gesture, mode-shift,
                               thumbwheel, thumbwheel-tap, cid-xxxx
                               ACTION: a built-in id (see actions), "default",
                               "none", "gestures", or JSON
  run ACTION                   perform an action now (built-in id or JSON)
  switch-host N                Easy-Switch to computer N (1 based)
  pause | resume               give the mouse its native behaviour / take it back
  reapply                      write every setting to the devices again
  raw [--device ID] HEX        HID++ call: feature index, function, parameters
  inject [--device ID] HEX     feed a report through the event path (testing)
  quit                         stop the agent
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(1)
}
args.removeFirst()

var deviceID: String?
if let i = args.firstIndex(of: "--device"), i + 1 < args.count {
    deviceID = args[i + 1]
    args.removeSubrange(i...(i + 1))
}

let connection = AgentConnection()
guard connection.connect() else {
    FileHandle.standardError.write(Data("mmctl: the Mouse Master agent is not running (\(MMPaths.socketPath))\n".utf8))
    exit(2)
}
connection.onDisconnect = {
    FileHandle.standardError.write(Data("mmctl: connection closed\n".utf8))
    exit(3)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mmctl: \(message)\n".utf8))
    exit(1)
}

func request(_ r: IPCRequest, then: @escaping (IPCMessage) -> Void) {
    connection.send(r) { reply in
        if reply.ok == false { fail(reply.error ?? "failed") }
        then(reply)
    }
}

func withState(_ f: @escaping (AgentState) -> Void) {
    request(IPCRequest(cmd: "state")) { reply in
        guard let s = reply.state else { fail("no state") }
        f(s)
    }
}

func targetDevice(_ s: AgentState) -> DeviceSnapshot {
    if let deviceID {
        guard let d = s.devices.first(where: { $0.id == deviceID }) else { fail("no device \(deviceID)") }
        return d
    }
    guard let d = s.devices.first(where: \.online) ?? s.devices.first else { fail("no device") }
    return d
}

func parseAction(_ text: String) -> Action {
    if text.hasPrefix("{"), let data = text.data(using: .utf8) {
        do { return try JSONDecoder().decode(Action.self, from: data) } catch { fail("invalid action JSON: \(error)") }
    }
    switch text {
    case "default": return .default
    case "none": return .nothing
    case "gestures": return .gestures(GestureSet())
    case "pan": return .gestures(GesturePresets.all.first { $0.id == "pan" }!.set)
    default:
        guard Catalog.action(text) != nil else { fail("unknown action \(text) (see mmctl actions)") }
        return .builtin(text)
    }
}

func printJSON<T: Encodable>(_ value: T) {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let d = try? e.encode(value), let s = String(data: d, encoding: .utf8) { print(s) }
}

switch command {
case "status":
    withState { s in
        print("Mouse Master agent \(s.agentVersion)")
        print("Accessibility: \(s.permissions.accessibility ? "allowed" : "NOT ALLOWED (actions are off)")")
        if s.config.general.paused { print("Paused") }
        if let app = s.activeApp { print("Frontmost app: \(app.name) (\(app.bundleID))") }
        if !s.conflicts.isEmpty { print("Also running: \(s.conflicts.map(\.name).joined(separator: ", "))") }
        print("System scroll direction: \(s.systemNaturalScrolling ? "natural" : "standard")")
        if s.devices.isEmpty { print("No devices") }
        for d in s.devices {
            let battery = d.battery?.percent.map { "\($0)%\(d.battery?.charging == true ? " charging" : "")" } ?? "–"
            print("")
            print("\(d.online ? "●" : "○") \(d.name)  [\(d.id)]  \(d.connection.label)  battery \(battery)\(d.busy ? "  (busy)" : "")")
            if let e = d.error { print("  error: \(e)") }
            let st = d.state
            let cfg = s.config.devices[d.id]
            var parts: [String] = []
            if let dpi = st.dpi { parts.append("\(dpi) DPI") }
            if let m = st.wheelMode { parts.append("wheel \(m)") }
            if let t = st.smartShiftThreshold { parts.append(t == 255 || t == 0 ? "SmartShift off" : "SmartShift \(t)") }
            parts.append(st.smoothScrolling ? "smooth scrolling" : "native scrolling")
            if st.thumbwheelDiverted { parts.append("thumb wheel handled") }
            print("  " + parts.joined(separator: " · "))
            if let host = st.currentHost { print("  Easy-Switch: computer \(host + 1) of \(d.capabilities.hosts ?? 0)") }
            if let p = d.activeProfile, let name = cfg?.profiles.first(where: { $0.id == p })?.name { print("  profile: \(name)") }
            for c in d.controls {
                let action = cfg?.bindings.buttons[c.key] ?? .default
                print("  \(c.key.padding(toLength: 12, withPad: " ", startingAt: 0)) \(action.title(role: c.role))")
            }
            if d.capabilities.thumbwheel {
                let t = cfg?.bindings.thumbwheel ?? .native
                print("  thumbwheel   \(ThumbwheelPresets.match(t)?.title ?? "Custom actions")")
            }
        }
        exit(0)
    }

case "state":
    withState { s in
        printJSON(s)
        exit(0)
    }

case "actions":
    for cat in ActionCategory.allCases {
        print(cat.rawValue)
        for a in Catalog.actions where a.category == cat {
            print("  \(a.id.padding(toLength: 26, withPad: " ", startingAt: 0)) \(a.title)\(a.hint.map { "  \($0)" } ?? "")")
        }
    }
    exit(0)

case "watch":
    connection.onMessage = { m in
        let t = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        switch m.event {
        case "button": print("\(t) button  \(m.control ?? "?") \(m.pressed == true ? "down" : "up")")
        case "gesture": print("\(t) gesture \(m.control ?? "?") \(m.gesture ?? "?")")
        case "motion": break
        case "state":
            let d = m.state?.devices.filter(\.online).map { "\($0.name) \($0.battery?.percent.map { "\($0)%" } ?? "") \($0.state.dpi.map { "\($0)dpi" } ?? "")" } ?? []
            print("\(t) state   \(d.joined(separator: ", "))")
        default: break
        }
        fflush(stdout)
    }
    request(IPCRequest(cmd: "hello", flag: true)) { _ in print("watching (ctrl-c to stop)") }

case "set":
    withState { s in
        let d = targetDevice(s)
        var cfg = s.config.devices[d.id] ?? DeviceConfig()
        for pair in args {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { fail("expected KEY=VALUE, got \(pair)") }
            let (k, v) = (kv[0], kv[1])
            let b = ["true", "on", "yes", "1"].contains(v.lowercased())
            switch k {
            case "dpi": cfg.settings.dpi = Int(v)
            case "dpiPresets": cfg.settings.dpiPresets = v.split(separator: ",").compactMap { Int($0) }
            case "smoothScroll": cfg.settings.smoothScroll = b
            case "scrollSpeed": cfg.settings.scrollSpeed = Double(v)
            case "scrollAcceleration": cfg.settings.scrollAcceleration = Double(v)
            case "scrollDirection": cfg.settings.scrollDirection = ScrollDirection(rawValue: v)
            case "smartShift": cfg.settings.smartShift = b
            case "smartShiftThreshold": cfg.settings.smartShiftThreshold = Int(v)
            case "smartShiftTorque": cfg.settings.smartShiftTorque = Int(v)
            case "wheelMode": cfg.settings.wheelMode = WheelModeSetting(rawValue: v)
            case "thumbwheelInvert": cfg.settings.thumbwheelInvert = b
            default: fail("unknown setting \(k)")
            }
        }
        request(IPCRequest(cmd: "set-device-config", device: d.id, deviceConfig: cfg)) { _ in exit(0) }
    }

case "bind":
    guard args.count >= 2 else { fail("usage: mmctl bind CONTROL ACTION") }
    let control = args[0]
    withState { s in
        let d = targetDevice(s)
        var cfg = s.config.devices[d.id] ?? DeviceConfig()
        switch control {
        case "thumbwheel":
            switch args[1] {
            case "native", "default": cfg.bindings.thumbwheel = .native
            case "scroll": cfg.bindings.thumbwheel = .scroll(speed: Double(args.count > 2 ? args[2] : "1") ?? 1)
            case "zoom": cfg.bindings.thumbwheel = .zoom(speed: 1)
            default:
                guard let p = ThumbwheelPresets.all.first(where: { $0.id == args[1] }) else { fail("thumb wheel: native, scroll, zoom, volume, brightness, tabs, spaces, undo, tracks") }
                cfg.bindings.thumbwheel = p.binding
            }
        case "thumbwheel-tap":
            cfg.bindings.thumbwheelTap = parseAction(args[1])
        default:
            guard d.control(control) != nil else { fail("\(d.name) has no control \(control); it has \(d.controls.map(\.key).joined(separator: ", "))") }
            cfg.bindings.buttons[control] = parseAction(args[1])
        }
        request(IPCRequest(cmd: "set-device-config", device: d.id, deviceConfig: cfg)) { _ in exit(0) }
    }

case "run":
    guard let a = args.first else { fail("usage: mmctl run ACTION") }
    request(IPCRequest(cmd: "run-action", device: deviceID, action: parseAction(a))) { _ in exit(0) }

case "switch-host":
    guard let n = args.first.flatMap({ Int($0) }), n >= 1 else { fail("usage: mmctl switch-host N") }
    request(IPCRequest(cmd: "switch-host", device: deviceID, host: n - 1)) { _ in exit(0) }

case "pause", "resume":
    withState { s in
        var g = s.config.general
        g.paused = command == "pause"
        request(IPCRequest(cmd: "set-general", general: g)) { _ in exit(0) }
    }

case "reapply":
    request(IPCRequest(cmd: "reapply")) { _ in exit(0) }

case "raw":
    guard let hex = args.first else { fail("usage: mmctl raw HEX") }
    request(IPCRequest(cmd: "raw", device: deviceID, hex: args.joined(separator: " ").isEmpty ? hex : args.joined(separator: " "))) { r in
        print(r.text ?? "")
        exit(0)
    }

case "inject":
    guard !args.isEmpty else { fail("usage: mmctl inject HEX") }
    request(IPCRequest(cmd: "inject", device: deviceID, hex: args.joined(separator: " "))) { _ in exit(0) }

case "quit":
    request(IPCRequest(cmd: "quit")) { _ in exit(0) }

default:
    print(usage)
    exit(1)
}

dispatchMain()
