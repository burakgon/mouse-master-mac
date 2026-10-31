import MouseMasterKit
import SwiftUI

struct PointScrollPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let device = model.device, let cfg = model.deviceConfig {
            let s = cfg.settings
            let caps = device.capabilities
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let dpi = caps.dpi {
                        PointerCard(caps: dpi, current: s.dpi ?? device.state.dpi ?? dpi.defaultValue, presets: s.dpiPresets)
                    }
                    if caps.hiresWheel || caps.smartShift {
                        ScrollCard(device: device, settings: s)
                    }
                    if caps.smartShift {
                        SmartShiftCard(device: device, settings: s)
                    }
                    if caps.thumbwheel {
                        VStack(alignment: .leading, spacing: 12) {
                            CardTitle(symbol: "arrow.left.and.right", title: "Thumb wheel",
                                      subtitle: "Also on the Buttons page, where it can do other things too.")
                            ThumbwheelEditor()
                        }
                        .card(padding: 20)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .top) {
                PageHeader(title: "Point & Scroll", subtitle: "Pointer speed, scrolling and the wheels of your \(device.name).")
                    .background(.bar.opacity(0))
            }
        }
    }
}

struct CardTitle: View {
    let symbol: String
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

struct PointerCard: View {
    @Environment(AppModel.self) private var model
    let caps: DPICaps
    let current: Int
    let presets: [Int]
    @State private var newPreset = ""

    private var effectivePresets: [Int] {
        Array(Set((presets.isEmpty ? DeviceSettings.defaultDPIPresets : presets).map { caps.snap($0) })).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(symbol: "scope", title: "Pointer speed",
                      subtitle: "The sensor's resolution: higher moves the pointer further for the same hand movement.")
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "\(current)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("DPI").font(.headline).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.editDevice { $0.settings.dpi = caps.defaultValue }
                } label: {
                    Text(verbatim: "Default (\(caps.defaultValue))")
                }
                .controlSize(.small)
                .disabled(current == caps.defaultValue)
            }
            Slider(value: Binding(get: { Double(current) }, set: { v in
                let snapped = caps.snap(Int(v))
                model.editDevice(throttle: true) { $0.settings.dpi = snapped }
            }), in: Double(caps.min)...Double(caps.max)) {
                EmptyView()
            } minimumValueLabel: {
                Image(systemName: "tortoise").foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: "hare").foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Speeds for Cycle Pointer Speed").font(.callout.weight(.medium))
                Text("Assign Cycle Pointer Speed to a button to switch between these. Click one to use it now.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(effectivePresets, id: \.self) { v in
                        Chip(title: "\(v)", selected: v == current) {
                            model.editDevice { $0.settings.dpi = v }
                        }
                        .contextMenu {
                            Button("Remove") {
                                model.editDevice { $0.settings.dpiPresets = effectivePresets.filter { $0 != v } }
                            }
                            .disabled(effectivePresets.count <= 2)
                        }
                    }
                    TextField("Add", text: $newPreset)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onSubmit {
                            guard let v = Int(newPreset) else { return }
                            model.editDevice { $0.settings.dpiPresets = Array(Set(effectivePresets + [caps.snap(v)])).sorted() }
                            newPreset = ""
                        }
                }
            }
        }
        .card(padding: 20)
    }
}

struct ScrollCard: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot
    let settings: DeviceSettings

    var body: some View {
        let systemNatural = model.state?.systemNaturalScrolling ?? true
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(symbol: "scroll", title: "Scrolling",
                      subtitle: "Applies to this mouse only. Your trackpad keeps its own setting.")
            if device.capabilities.hiresWheel {
                Toggle(isOn: Binding(get: { settings.effectiveSmoothScroll }, set: { v in model.editDevice { $0.settings.smoothScroll = v } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Smooth scrolling")
                        Text("Every notch glides like a trackpad, using the wheel's high resolution sensor.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scroll direction")
                    Text(settings.scrollDirection == nil ? "Same as your trackpad (\(systemNatural ? "natural" : "standard"))" : "Independent from your trackpad")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: Binding(get: { settings.scrollDirection?.rawValue ?? "system" }, set: { v in
                    model.editDevice { $0.settings.scrollDirection = ScrollDirection(rawValue: v) }
                })) {
                    Text("Like Trackpad").tag("system")
                    Text("Natural").tag(ScrollDirection.natural.rawValue)
                    Text("Standard").tag(ScrollDirection.standard.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
            }
            if device.capabilities.hiresWheel && settings.effectiveSmoothScroll {
                LabeledSlider(title: "Scroll speed", value: settings.effectiveScrollSpeed, range: 0.3...3, step: 0.05,
                              format: { String(format: "%.2f×", $0) }) { v in model.editDevice(throttle: true) { $0.settings.scrollSpeed = v } }
                LabeledSlider(title: "Acceleration", value: settings.effectiveScrollAcceleration, range: 0...2, step: 0.05,
                              format: { v in v < 0.05 ? "Off" : v < 0.75 ? "Gentle" : v < 1.35 ? "Normal" : "Strong" }) { v in
                    model.editDevice(throttle: true) { $0.settings.scrollAcceleration = v }
                }
                Text("Acceleration makes fast flicks travel further while slow, careful scrolling stays precise.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card(padding: 20)
    }
}

struct SmartShiftCard: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot
    let settings: DeviceSettings

    var body: some View {
        let threshold = settings.smartShiftThreshold ?? device.state.smartShiftThreshold.flatMap { $0 == 255 || $0 == 0 ? nil : $0 }
            ?? device.capabilities.smartShiftDefaultThreshold ?? 10
        let enabled = settings.smartShift ?? device.state.smartShiftEnabled ?? true
        let freeSpin = device.state.wheelMode == "free-spin"
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(symbol: "dial.medium", title: "Scroll wheel",
                      subtitle: "The MagSpeed wheel clicks notch by notch (ratchet) or spins freely.")
            HStack {
                Text("Mode")
                Spacer()
                Picker("", selection: Binding(get: { freeSpin ? "free-spin" : "ratchet" }, set: { v in
                    model.editDevice { $0.settings.wheelMode = WheelModeSetting(rawValue: v) }
                })) {
                    Label("Ratchet", systemImage: "dial.medium").tag("ratchet")
                    Label("Free Spin", systemImage: "circle.dashed").tag("free-spin")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            Toggle(isOn: Binding(get: { enabled }, set: { v in model.editDevice { $0.settings.smartShift = v } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SmartShift")
                    Text("Switches to free spin by itself when you flick the wheel fast.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            if enabled {
                LabeledSlider(title: "Sensitivity", value: Double(51 - min(max(threshold, 1), 50)), range: 1...50, step: 1,
                              format: { v in "\(Int(v))" }) { v in
                    model.editDevice(throttle: true) { $0.settings.smartShiftThreshold = 51 - Int(v) }
                }
                Text("Higher sensitivity switches to free spin with a lighter flick.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if device.capabilities.smartShiftTorque {
                LabeledSlider(title: "Ratchet force", value: Double(settings.smartShiftTorque ?? device.state.smartShiftTorque ?? 50),
                              range: 1...100, step: 1, format: { "\(Int($0))%" }) { v in
                    model.editDevice(throttle: true) { $0.settings.smartShiftTorque = Int(v) }
                }
            }
        }
        .card(padding: 20)
    }
}
