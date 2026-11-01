import AppKit
import MouseMasterKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Easy-Switch

struct EasySwitchPage: View {
    @Environment(AppModel.self) private var model
    @State private var confirm: HostEntry?

    var body: some View {
        if let device = model.device {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(title: "Easy-Switch",
                               subtitle: "Your \(device.name) remembers \(device.capabilities.hosts ?? 0) computers. Switch with the button under the mouse, or from here.")
                        .padding(.horizontal, -28)
                    let hosts = device.state.hosts
                    if hosts.isEmpty {
                        Text("Reading the paired computers…").foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)], spacing: 16) {
                        ForEach(hosts) { h in
                            HostCard(host: h, writable: device.capabilities.hostNamesWritable) {
                                confirm = h
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
            .alert(item: $confirm) { h in
                Alert(title: Text("Switch to \(h.name.isEmpty ? "computer \(h.index + 1)" : h.name)?"),
                      message: Text("Your mouse will connect to that computer and stop working on this Mac until you switch back."),
                      primaryButton: .default(Text("Switch")) {
                          model.command(IPCRequest(cmd: "switch-host", device: device.id, host: h.index))
                      },
                      secondaryButton: .cancel())
            }
        }
    }
}

struct HostCard: View {
    @Environment(AppModel.self) private var model
    let host: HostEntry
    let writable: Bool
    let onSwitch: () -> Void
    @State private var name = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(host.index + 1)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(host.current ? Color.white : Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(host.current ? Color.accentColor : Color.accentColor.opacity(0.13), in: Circle())
                Spacer()
                if host.current {
                    Label("This Mac", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                } else if host.paired {
                    Image(systemName: host.bus == "bluetooth" ? "dot.radiowaves.left.and.right" : "cable.connector")
                        .foregroundStyle(.secondary)
                }
            }
            if writable && host.paired {
                TextField("Computer \(host.index + 1)", text: $name)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .focused($editing)
                    .onSubmit { save() }
            } else {
                Text(host.paired ? (host.name.isEmpty ? "Computer \(host.index + 1)" : host.name) : "Not paired")
                    .font(.headline)
                    .foregroundStyle(host.paired ? .primary : .secondary)
            }
            Text(host.paired ? (host.bus == "bluetooth" ? "Bluetooth" : host.bus == "receiver" ? "Logi receiver" : "USB") : "Hold the Easy-Switch button to pair")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if !host.current && host.paired {
                Button("Switch to This Computer", action: onSwitch)
                    .controlSize(.regular)
            }
        }
        .frame(minHeight: 170, alignment: .topLeading)
        .card(padding: 18)
        .overlay {
            if host.current {
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
            }
        }
        .onAppear { name = host.name }
        .onChange(of: host.name) { _, n in if !editing { name = n } }
        .onChange(of: editing) { _, e in if !e { save() } }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard n != host.name, let id = model.device?.id else { return }
        model.command(IPCRequest(cmd: "set-host-name", device: id, host: host.index, name: n))
    }
}

// MARK: - Device info

struct DeviceInfoPage: View {
    @Environment(AppModel.self) private var model
    @State private var showAllFeatures = false
    @State private var confirmReset = false
    @State private var confirmForget = false

    var body: some View {
        if let d = model.device {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(title: d.name, subtitle: d.online ? "Connected via \(d.connection.label)" : "Not connected")
                        .padding(.horizontal, -28)
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            CardTitle(symbol: "info.circle", title: "About")
                            InfoRow("Model", d.modelID.uppercased())
                            InfoRow("Unit ID", d.unitID)
                            if let s = d.serial { InfoRow("Serial number", s) }
                            InfoRow("Connection", d.connection.label)
                            InfoRow("HID++", d.protocolVersion)
                            ForEach(Array(d.firmware.enumerated()), id: \.offset) { _, f in
                                InfoRow(f.kindLabel, "\(f.name) \(f.version)".trimmingCharacters(in: .whitespaces))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(padding: 20)
                        VStack(alignment: .leading, spacing: 12) {
                            CardTitle(symbol: BatteryBadge(battery: d.battery).symbol, title: "Battery")
                            if let p = d.battery?.percent {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text("\(p)").font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                                    Text("%").font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                                }
                                ProgressView(value: Double(p), total: 100)
                                    .tint(p <= 15 ? .red : p <= 30 ? .orange : .green)
                                Text(d.battery?.charging == true ? "Charging" : d.battery?.full == true ? "Fully charged" : "On battery")
                                    .font(.callout).foregroundStyle(.secondary)
                            } else {
                                Text("Unknown").foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 240, alignment: .leading)
                        .card(padding: 20)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            CardTitle(symbol: "cpu", title: "Features", subtitle: "\(d.features.count) HID++ features")
                            Spacer()
                            Toggle("Show internal", isOn: $showAllFeatures).toggleStyle(.switch).controlSize(.small)
                        }
                        let list = d.features.filter { showAllFeatures || !$0.hidden }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], alignment: .leading, spacing: 6) {
                            ForEach(list, id: \.id) { f in
                                HStack(spacing: 6) {
                                    Text(String(format: "%04X", f.id)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                    Text(f.name).font(.caption).lineLimit(1)
                                    if f.version > 0 { Text("v\(f.version)").font(.caption2).foregroundStyle(.tertiary) }
                                }
                            }
                        }
                    }
                    .card(padding: 20)
                    HStack {
                        Button("Restore Default Setup…") { confirmReset = true }
                        Button("Forget This Device…", role: .destructive) { confirmForget = true }
                            .disabled(d.online)
                            .help(d.online ? "Only a device that is not connected can be forgotten" : "")
                        Spacer()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
            .confirmationDialog("Restore the default setup of \(d.name)?", isPresented: $confirmReset) {
                Button("Restore Defaults", role: .destructive) {
                    model.command(IPCRequest(cmd: "reset-device", device: d.id))
                }
            } message: {
                Text("Every button, gesture, application profile and setting of this mouse goes back to how Mouse Master sets it up the first time.")
            }
            .confirmationDialog("Forget \(d.name)?", isPresented: $confirmForget) {
                Button("Forget", role: .destructive) {
                    model.command(IPCRequest(cmd: "forget-device", device: d.id))
                }
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

// MARK: - App settings

struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var loginStatus = AgentLauncher.status

    var body: some View {
        let g = model.general
        let perms = model.state?.permissions
        Form {
            Section {
                Toggle(isOn: Binding(get: { loginStatus == .enabled }, set: { v in
                    AgentLauncher.setLaunchAtLogin(v)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { loginStatus = AgentLauncher.status }
                })) {
                    Text("Start at login")
                    Text(loginStatus == .requiresApproval ? "Waiting for your approval in Login Items" : "Keeps your buttons working after a restart.")
                }
                .disabled(loginStatus == .unavailable)
                if loginStatus == .requiresApproval {
                    Button("Open Login Items") { SMAppServiceHelper.openLoginItems() }
                }
                Toggle("Show in the menu bar", isOn: bind(\.showMenuBarIcon))
                Toggle("Show battery level in the menu bar", isOn: bind(\.showBatteryInMenuBar))
                    .disabled(!g.showMenuBarIcon)
            } header: {
                Text("General")
            }

            Section {
                Toggle(isOn: bind(\.osd)) {
                    Text("On-screen display")
                    Text("A small heads-up display when pointer speed or the wheel mode changes.")
                }
                Toggle("Low battery notification", isOn: bind(\.notifications))
                Stepper(value: bind(\.lowBatteryPercent), in: 5...50, step: 5) {
                    Text("Warn at \(g.lowBatteryPercent)%")
                }
                .disabled(!g.notifications)
            } header: {
                Text("Notifications")
            }

            Section {
                Toggle(isOn: bind(\.appProfiles)) {
                    Text("Application profiles")
                    Text("Use each app's own button setup while it is in front. Add apps on the Buttons page.")
                }
                if let app = model.state?.activeApp {
                    LabeledContent("In front now") {
                        HStack(spacing: 6) {
                            AppIconView(bundleID: app.bundleID, size: 16)
                            Text(app.name)
                        }
                    }
                }
            } header: {
                Text("Applications")
            }

            Section {
                PermissionRow(title: "Accessibility", detail: "To press keys, click and scroll for you.",
                              granted: perms?.accessibility ?? false) {
                    model.command(IPCRequest(cmd: "request-accessibility"))
                    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                }
                if perms?.inputMonitoringNeeded == true {
                    PermissionRow(title: "Input Monitoring", detail: "Needed by macOS for some devices.",
                                  granted: perms?.inputMonitoring ?? false) {
                        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
                    }
                }
            } header: {
                Text("Permissions")
            }

            if let conflicts = model.state?.conflicts, !conflicts.isEmpty {
                Section {
                    ForEach(conflicts) { c in
                        LabeledContent(c.name) {
                            Button("Quit") { model.command(IPCRequest(cmd: "quit-conflict", name: c.id)) }
                        }
                    }
                } header: {
                    Text("Other mouse software")
                } footer: {
                    Text("These take over the mouse too. Running them side by side makes buttons and scrolling act twice.")
                }
            }

            if let update = model.state?.update {
                Section {
                    Toggle(isOn: bind(\.checkForUpdates)) {
                        Text("Check for updates automatically")
                        Text("Looks for a new version on GitHub a few times a day.")
                    }
                    UpdateRow(update: update, current: model.state?.agentVersion ?? "") { cmd in
                        model.command(IPCRequest(cmd: cmd))
                    }
                } header: {
                    Text("Updates")
                }
            }

            Section {
                LabeledContent("Mouse Master", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                LabeledContent("Background service", value: model.connected ? "Running (\(model.state?.agentVersion ?? "?"))" : "Not running")
                HStack {
                    Button("Export Settings…") { exportConfig() }
                    Button("Import Settings…") { importConfig() }
                    Spacer()
                    Button("Restart Background Service") { model.restartAgent() }
                }
            } header: {
                Text("About")
            } footer: {
                Text("Your settings live in ~/Library/Application Support/Mouse Master. Logitech, MX Master and Logi Bolt are trademarks of Logitech; Mouse Master is not affiliated with Logitech.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top) {
            PageHeader(title: "Settings", subtitle: "How Mouse Master behaves on this Mac.")
        }
        .onAppear { loginStatus = AgentLauncher.status }
    }

    private func bind<T>(_ key: WritableKeyPath<General, T>) -> Binding<T> {
        Binding(get: { model.general[keyPath: key] }, set: { v in model.editGeneral { $0[keyPath: key] = v } })
    }

    private func open(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    private func exportConfig() {
        guard let cfg = model.state?.config else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Mouse Master Settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? cfg.save(to: url)
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
              (try? JSONDecoder().decode(Config.self, from: data)) != nil else { return }
        model.command(IPCRequest(cmd: "set-config", name: text))
    }
}

/// Where updates stand, and the button for the next step.
struct UpdateRow: View {
    let update: UpdateStatus
    let current: String
    let send: (String) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            switch update.phase {
            case .checking, .downloading, .installing:
                ProgressView().controlSize(.small)
            case .idle:
                if update.available {
                    if let page = update.pageURL.flatMap(URL.init(string:)) {
                        Button("Release Notes") { NSWorkspace.shared.open(page) }
                    }
                    Button("Install and Restart") { send("install-update") }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Check Now") { send("check-updates") }
                }
            }
        }
    }

    private var title: String {
        let v = update.latestVersion ?? ""
        switch update.phase {
        case .checking: return "Checking for updates…"
        case .downloading: return "Downloading Mouse Master \(v)…"
        case .installing: return "Installing Mouse Master \(v)…"
        case .idle:
            if update.available { return "Mouse Master \(v) is available" }
            if update.error != nil { return "Could not check for updates" }
            return update.lastChecked == nil ? "Version \(current)" : "Mouse Master is up to date"
        }
    }

    private var detail: String? {
        if update.phase == .idle, let error = update.error { return error }
        if update.available { return "You have version \(current). Mouse Master restarts to finish." }
        if let checked = update.lastChecked {
            return "Version \(current) · checked \(checked.formatted(.relative(presentation: .named)))"
        }
        return nil
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Allowed").foregroundStyle(.secondary)
            } else {
                Button("Allow…", action: action)
            }
        }
    }
}

// MARK: - Choosing an application

struct AppPicker: View {
    let onPick: (String, String) -> Void
    let cancel: () -> Void
    @State private var apps: [AppEntry] = []
    @State private var search = ""

    struct AppEntry: Identifiable, Hashable {
        let id: String
        let name: String
        let url: URL
        let running: Bool
    }

    private var filtered: [AppEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose an Application").font(.title3.weight(.semibold))
            Text("Its buttons start out like All Apps; change only what should be different.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            List(filtered) { app in
                Button {
                    onPick(app.name, app.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable().frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name)
                            Text(app.id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if app.running { Text("Open").font(.caption).foregroundStyle(.green) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 560)
        .task { apps = await Self.loadApps() }
    }

    static func loadApps() async -> [AppEntry] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return await Task.detached(priority: .userInitiated) {
            var found: [String: AppEntry] = [:]
            let fm = FileManager.default
            let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                         NSHomeDirectory() + "/Applications", "/Applications/Setapp"]
            for root in roots {
                guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
                for item in items where item.hasSuffix(".app") {
                    let url = URL(fileURLWithPath: root).appendingPathComponent(item)
                    guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, found[id] == nil else { continue }
                    let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                        ?? String(item.dropLast(4))
                    found[id] = AppEntry(id: id, name: name, url: url, running: running.contains(id))
                }
            }
            return found.values.sorted {
                if $0.running != $1.running { return $0.running }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }.value
    }
}
