import AppKit
import MouseMasterKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 236, ideal: 256, max: 320)
        } detail: {
            DetailView()
                .background(StageBackground().ignoresSafeArea())
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    private var pages: [Page] {
        guard let d = model.device else { return [] }
        var p: [Page] = [.buttons, .pointScroll]
        if (d.capabilities.hosts ?? 0) > 1 { p.append(.easySwitch) }
        p.append(.info)
        return p
    }

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.page }, set: { if let p = $0 { model.page = p } })) {
            Section("Devices") {
                if let devices = model.state?.devices, !devices.isEmpty {
                    ForEach(devices) { d in
                        DeviceRow(device: d, selected: d.id == model.selectedDeviceID)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selectedDeviceID = d.id
                                model.selectedControl = nil
                                model.selectedProfileID = nil
                                if model.page == .settings { model.page = .buttons }
                            }
                    }
                } else {
                    Text(model.connected ? "No mouse found" : "Starting…")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            if !pages.isEmpty {
                Section(model.device?.name ?? "Device") {
                    ForEach(pages) { p in
                        Label(p.title, systemImage: p.symbol).tag(p)
                    }
                }
            }
            Section("Mouse Master") {
                Label("Settings", systemImage: Page.settings.symbol).tag(Page.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            PauseFooter()
        }
    }
}

struct DeviceRow: View {
    let device: DeviceSnapshot
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "computermouse.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 34, height: 34)
                    .background((selected ? Color.accentColor : Color.primary).opacity(selected ? 0.15 : 0.06),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Circle()
                    .fill(device.online ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if device.online {
                        BatteryBadge(battery: device.battery)
                    } else {
                        Text("Not connected")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct PauseFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let paused = model.general.paused
        HStack(spacing: 10) {
            Image(systemName: paused ? "pause.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(paused ? .orange : .green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(paused ? "Paused" : "Active").font(.callout.weight(.semibold))
                Text(paused ? "Native behaviour" : model.connected ? "Working in the background" : "Connecting…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { !paused }, set: { v in model.editGeneral { $0.paused = !v } }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!model.connected)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(10)
    }
}

// MARK: - Detail

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Banners()
            Group {
                if !model.connected {
                    ConnectingView()
                } else if model.needsPermissions && model.page != .settings {
                    PermissionsView()
                } else if model.page == .settings {
                    SettingsPage()
                } else if model.device == nil {
                    NoDeviceView()
                } else {
                    switch model.page {
                    case .buttons: ButtonsPage()
                    case .pointScroll: PointScrollPage()
                    case .easySwitch: EasySwitchPage()
                    case .info: DeviceInfoPage()
                    case .settings: SettingsPage()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.snappy(duration: 0.25), value: model.page)
    }
}

struct Banners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if let s = model.state {
                ForEach(s.conflicts) { c in
                    Banner(kind: .warning, title: "\(c.name) is running",
                           message: "It takes over the mouse too, so buttons and scrolling may act twice. Quit it to let Mouse Master do the work.",
                           actionTitle: "Quit \(c.name)") {
                        model.command(IPCRequest(cmd: "quit-conflict", name: c.id))
                    }
                }
            }
            if AgentLauncher.status == .requiresApproval {
                Banner(kind: .info, title: "Mouse Master is not allowed to start at login",
                       message: "Turn it on in Login Items so your buttons work after a restart.",
                       actionTitle: "Open Login Items") {
                    SMAppServiceHelper.openLoginItems()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, (model.state?.conflicts.isEmpty ?? true) && AgentLauncher.status != .requiresApproval ? 0 : 12)
    }
}

enum SMAppServiceHelper {
    static func openLoginItems() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ConnectingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            if model.connecting {
                ProgressView().controlSize(.large)
                Text("Starting Mouse Master…").font(.title3.weight(.semibold))
                Text("The background service is getting ready.").foregroundStyle(.secondary)
            } else {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(.secondary)
                Text("The background service is not running").font(.title3.weight(.semibold))
                Text("Mouse Master needs its small background service to work with your mouse.")
                    .foregroundStyle(.secondary)
                Button("Start It") { model.restartAgent() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoDeviceView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "computermouse")
                .font(.system(size: 60, weight: .thin))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse)
            Text("Waiting for your mouse").font(.title2.weight(.semibold))
            Text("Turn on your Logitech mouse, or connect it over Bluetooth or a Logi Bolt / Unifying receiver.\nIt shows up here on its own.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The soft backdrop behind every page.
struct StageBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color.accentColor.opacity(scheme == .dark ? 0.10 : 0.07), .clear],
                           center: UnitPoint(x: 0.42, y: 0.38), startRadius: 10, endRadius: 620)
        }
    }
}
