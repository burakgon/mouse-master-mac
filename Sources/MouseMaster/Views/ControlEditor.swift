import AppKit
import MouseMasterKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Inspector

struct ControlInspector: View {
    @Environment(AppModel.self) private var model
    let key: String

    private var control: ControlInfo? { model.device?.control(key) }
    private var name: String { key == "thumbwheel" ? "Thumb wheel" : control?.name ?? key }
    private var role: String { key == "thumbwheel" ? "thumbwheel" : control?.role ?? "other" }
    private var overridden: Bool { key == "thumbwheel" ? model.thumbwheelOverridden : model.isOverridden(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(symbol: NativeBehavior.symbol(role: role), size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.title3.weight(.semibold))
                    Text(model.selectedProfile.map { "In \($0.name)" } ?? "In all apps")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.selectedControl = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            if let p = model.selectedProfile {
                HStack(spacing: 8) {
                    Image(systemName: overridden ? "app.badge.fill" : "arrow.turn.down.right")
                        .foregroundStyle(overridden ? Color.accentColor : .secondary)
                    Text(overridden ? "Set just for \(p.name)" : "Same as in all apps")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if overridden {
                        Button("Use All Apps Setting") { model.clearOverride(key) }
                            .controlSize(.small)
                    }
                }
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            Divider()
            if key == "thumbwheel" {
                ScrollView { ThumbwheelEditor().padding(.trailing, 4) }
            } else if control?.gestures == true {
                GestureCapableEditor(key: key, role: role)
            } else {
                ActionPicker(current: model.action(for: key), role: role) { model.setAction($0, for: key) }
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
        }
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// A control that can either run one action or do gestures.
struct GestureCapableEditor: View {
    @Environment(AppModel.self) private var model
    let key: String
    let role: String
    @State private var showGestures = false

    var body: some View {
        let action = model.action(for: key)
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: Binding(get: { action.isGestures || showGestures }, set: { on in
                showGestures = on
                if on, !action.isGestures {
                    model.setAction(.gestures(GesturePresets.all[0].set), for: key)
                } else if !on, action.isGestures {
                    model.setAction(.default, for: key)
                }
            })) {
                Label("Single Action", systemImage: "cursorarrow.click").tag(false)
                Label("Gestures", systemImage: "hand.draw").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if case .gestures(let set) = action {
                ScrollView {
                    GestureEditor(key: key, set: set) { model.setAction(.gestures($0), for: key) }
                        .padding(.trailing, 4)
                }
            } else {
                ActionPicker(current: action, role: role) { model.setAction($0, for: key) }
            }
        }
    }
}

// MARK: - Choosing an action

struct ActionPicker: View {
    let current: Action
    let role: String
    var compact = false
    let onPick: (Action) -> Void

    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var expanded: Custom?

    enum Custom: String, CaseIterable, Identifiable {
        case keys, open, shortcut, command, text, mouse, precision, host

        var id: String { rawValue }

        var title: String {
            switch self {
            case .keys: return "Keyboard Shortcut"
            case .open: return "Open App, File or Website"
            case .shortcut: return "Run a Shortcut"
            case .command: return "Run Shell Command"
            case .text: return "Type Text"
            case .mouse: return "Mouse Button"
            case .precision: return "Precision Mode (slow while held)"
            case .host: return "Easy-Switch to Computer"
            }
        }

        var symbol: String {
            switch self {
            case .keys: return "keyboard"
            case .open: return "arrow.up.forward.app"
            case .shortcut: return "square.2.layers.3d"
            case .command: return "terminal"
            case .text: return "character.cursor.ibeam"
            case .mouse: return "computermouse"
            case .precision: return "scope"
            case .host: return "laptopcomputer.and.arrow.down"
            }
        }

        func matches(_ a: Action) -> Bool {
            switch (self, a) {
            case (.keys, .keys), (.open, .open), (.shortcut, .shortcut), (.command, .command), (.text, .text),
                 (.mouse, .mouse), (.precision, .shiftDPI), (.host, .switchHost): return true
            default: return false
            }
        }
    }

    private var customs: [Custom] {
        var c = Custom.allCases
        if (model.device?.capabilities.hosts ?? 0) < 2 { c.removeAll { $0 == .host } }
        if model.device?.capabilities.dpi == nil { c.removeAll { $0 == .precision } }
        return c
    }

    private func matches(_ a: BuiltinAction) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return a.title.localizedCaseInsensitiveContains(q) || a.category.rawValue.localizedCaseInsensitiveContains(q)
            || (a.hint?.localizedCaseInsensitiveContains(q) ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search actions", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    if search.isEmpty {
                        groupTitle("Basics")
                        ActionRow(title: "Default: \(NativeBehavior.title(role: role))", symbol: NativeBehavior.symbol(role: role),
                                  hint: nil, selected: current == .default) { onPick(.default) }
                        ActionRow(title: "Do Nothing", symbol: "nosign", hint: nil, selected: current == .nothing) { onPick(.nothing) }
                        groupTitle("Your Own")
                        ForEach(customs) { c in
                            ActionRow(title: c.title, symbol: c.symbol, hint: c.matches(current) ? current.title(role: role) : nil,
                                      selected: c.matches(current), disclosure: expanded == c) {
                                withAnimation(.snappy(duration: 0.2)) { expanded = expanded == c ? nil : c }
                            }
                            if expanded == c {
                                CustomActionEditor(kind: c, current: current, onPick: onPick)
                                    .padding(.leading, 30)
                                    .padding(.vertical, 6)
                            }
                        }
                    }
                    ForEach(ActionCategory.allCases, id: \.self) { cat in
                        let items = Catalog.actions.filter { $0.category == cat && matches($0) }
                        if !items.isEmpty {
                            groupTitle(cat.rawValue)
                            ForEach(items) { a in
                                ActionRow(title: a.title, symbol: a.symbol, hint: a.hint, selected: current == .builtin(a.id)) {
                                    onPick(.builtin(a.id))
                                }
                                .id(a.id)
                            }
                        }
                    }
                }
                .padding(.trailing, 6)
            }
            .onAppear {
                if case .builtin(let id) = current {
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                }
            }
            }
        }
        .onAppear {
            expanded = Custom.allCases.first { $0.matches(current) }
        }
    }

    private func groupTitle(_ s: String) -> some View {
        SectionLabel(text: s).padding(.top, 10).padding(.bottom, 3).padding(.leading, 6)
    }
}

struct ActionRow: View {
    let title: String
    let symbol: String
    let hint: String?
    let selected: Bool
    var disclosure: Bool? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 22)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let disclosure {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(disclosure ? 90 : 0))
                } else if selected {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : hovering ? Color.primary.opacity(0.06) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Editors for actions that need a value.
struct CustomActionEditor: View {
    let kind: ActionPicker.Custom
    let current: Action
    let onPick: (Action) -> Void

    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var dpi: Double = 400
    @State private var shortcuts: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch kind {
            case .keys:
                ShortcutRecorder(combo: { if case .keys(let k) = current { return k }; return nil }()) { onPick(.keys($0)) }
                Text("Keys stay pressed while you hold the button, so ⌘ or ⇧ work for clicks and drags too.")
                    .font(.caption).foregroundStyle(.secondary)
            case .open:
                HStack {
                    Button("Choose App…") { chooseApp() }
                    Button("Choose File or Folder…") { chooseFile() }
                }
                HStack {
                    TextField("https://… or a path", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { useText { .open($0) } }
                    Button("Use") { useText { .open($0) } }.disabled(text.isEmpty)
                }
            case .shortcut:
                if !shortcuts.isEmpty {
                    Picker("Shortcut", selection: Binding(get: { text }, set: { text = $0; onPick(.shortcut($0)) })) {
                        Text("Choose…").tag("")
                        ForEach(shortcuts, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                } else {
                    HStack {
                        TextField("Shortcut name", text: $text).textFieldStyle(.roundedBorder).onSubmit { useText { .shortcut($0) } }
                        Button("Use") { useText { .shortcut($0) } }.disabled(text.isEmpty)
                    }
                }
            case .command:
                HStack {
                    TextField("open -a Calendar", text: $text).textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .onSubmit { useText { .command($0) } }
                    Button("Use") { useText { .command($0) } }.disabled(text.isEmpty)
                }
                Text("Runs in your login shell (zsh).").font(.caption).foregroundStyle(.secondary)
            case .text:
                HStack {
                    TextField("Text to type", text: $text).textFieldStyle(.roundedBorder).onSubmit { useText { .text($0) } }
                    Button("Use") { useText { .text($0) } }.disabled(text.isEmpty)
                }
            case .mouse:
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(MouseButton.allCases, id: \.self) { b in
                        ActionRow(title: b.title, symbol: "computermouse", hint: nil, selected: current == .mouse(b)) { onPick(.mouse(b)) }
                    }
                }
            case .precision:
                if let caps = model.device?.capabilities.dpi {
                    HStack {
                        Slider(value: Binding(get: { dpi }, set: { dpi = Double(caps.snap(Int($0))) }),
                               in: Double(caps.min)...Double(min(caps.max, 3200)))
                        Text(verbatim: "\(Int(dpi)) DPI").monospacedDigit().frame(width: 76, alignment: .trailing)
                    }
                    Button {
                        onPick(.shiftDPI(Int(dpi)))
                    } label: {
                        Text(verbatim: "Use \(Int(dpi)) DPI While Held")
                    }
                    Text("The pointer slows down while you hold the button: handy for precise work.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .host:
                HStack {
                    ForEach(model.device?.state.hosts ?? []) { h in
                        Button("\(h.index + 1)") { onPick(.switchHost(h.index)) }
                            .help(h.name.isEmpty ? "Computer \(h.index + 1)" : h.name)
                            .buttonStyle(.bordered)
                            .tint(current == .switchHost(h.index) ? .accentColor : nil)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear {
            switch current {
            case .open(let s), .command(let s), .text(let s), .shortcut(let s): text = s
            case .shiftDPI(let d): dpi = Double(d)
            default: break
            }
            if kind == .shortcut { loadShortcuts() }
        }
    }

    private func useText(_ make: (String) -> Action) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onPick(make(t))
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let id = Bundle(url: url)?.bundleIdentifier
        onPick(.open(id ?? url.path))
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onPick(.open(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")))
    }

    private func loadShortcuts() {
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["list"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }.sorted()
            await MainActor.run { shortcuts = names }
        }
    }
}

/// Shows the current action and opens the picker in a popover.
struct ActionMenuButton: View {
    let current: Action
    let role: String
    var placeholder = "Choose…"
    let onPick: (Action) -> Void
    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: current == .nothing ? "nosign" : current == .default ? "plus.circle" : current.symbol)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                Text(current == .default ? placeholder : current.title(role: role))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .trailing) {
            ActionPicker(current: current, role: role, compact: true) {
                onPick($0)
                if !$0.isCustomValue { open = false }
            }
            .padding(14)
            .frame(width: 360, height: 460)
        }
    }
}

extension Action {
    /// Actions picked from a sub editor keep the popover open while the value is edited.
    var isCustomValue: Bool {
        switch self {
        case .keys, .open, .command, .text, .shortcut, .shiftDPI: return true
        default: return false
        }
    }
}

// MARK: - Gestures

struct GestureEditor: View {
    @Environment(AppModel.self) private var model
    let key: String
    let set: GestureSet
    let onChange: (GestureSet) -> Void

    private func update(_ f: (inout GestureSet) -> Void) {
        var s = set
        f(&s)
        onChange(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: Binding(get: { set.mode }, set: { m in update { $0.mode = m } })) {
                Text("Directions").tag(GestureMode.directional)
                Text("Pan & Scroll").tag(GestureMode.pan)
                Text("Zoom").tag(GestureMode.zoom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch set.mode {
            case .directional:
                DirectionPad(key: key, set: set, onChange: onChange)
                Text("Hold the button and move the mouse. A click without moving does the middle action.")
                    .font(.caption).foregroundStyle(.secondary)
                SectionLabel(text: "Presets")
                FlowChips(items: GesturePresets.all.filter { $0.set.mode == .directional }) { preset in
                    Chip(title: preset.title, symbol: preset.symbol, selected: preset.set.up == set.up && preset.set.down == set.down
                         && preset.set.left == set.left && preset.set.right == set.right) {
                        update {
                            let threshold = $0.thresholdMM
                            $0 = preset.set
                            $0.thresholdMM = threshold
                        }
                    }
                }
                SectionLabel(text: "Feel")
                LabeledSlider(title: "Distance", value: set.thresholdMM, range: 3...20, step: 0.5,
                              format: { String(format: "%.1f mm", $0) }) { v in update { $0.thresholdMM = v } }
                Toggle("Act when the button is released", isOn: Binding(get: { set.trigger == .release },
                                                                         set: { v in update { $0.trigger = v ? .release : .move } }))
                Toggle("Repeat up and down while moving", isOn: Binding(get: { set.repeatVertical },
                                                                        set: { v in update { $0.repeatVertical = v } }))
                Toggle("Repeat left and right while moving", isOn: Binding(get: { set.repeatHorizontal },
                                                                           set: { v in update { $0.repeatHorizontal = v } }))
            case .pan:
                Text("Hold the button and move the mouse to scroll in any direction, like dragging on a trackpad.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledSlider(title: "Speed", value: set.panSpeed, range: 0.25...4, step: 0.05,
                              format: { String(format: "%.2f×", $0) }) { v in update { $0.panSpeed = v } }
                Toggle("Drag the page (instead of the view)", isOn: Binding(get: { set.panInvert }, set: { v in update { $0.panInvert = v } }))
                clickRow
            case .zoom:
                Text("Hold the button and move the mouse up to zoom in, down to zoom out.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledSlider(title: "Speed", value: set.zoomSpeed, range: 0.25...4, step: 0.05,
                              format: { String(format: "%.2f×", $0) }) { v in update { $0.zoomSpeed = v } }
                clickRow
            }
        }
    }

    private var clickRow: some View {
        HStack {
            Text("Click")
            Spacer()
            ActionMenuButton(current: set.click, role: "other", placeholder: "Nothing") { a in update { $0.click = a } }
                .frame(width: 210)
        }
    }
}

struct DirectionPad: View {
    @Environment(AppModel.self) private var model
    let key: String
    let set: GestureSet
    let onChange: (GestureSet) -> Void

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                tile(.up)
                Color.clear.frame(width: 1, height: 1)
            }
            GridRow {
                tile(.left)
                clickTile
                tile(.right)
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                tile(.down)
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func recent(_ name: String) -> Bool {
        guard let g = model.lastGesture, g.control == key, g.gesture == name else { return false }
        return Date().timeIntervalSince(g.at) < 0.9
    }

    private func tile(_ d: Direction) -> some View {
        let arrow: String
        switch d {
        case .up: arrow = "arrow.up"
        case .down: arrow = "arrow.down"
        case .left: arrow = "arrow.left"
        case .right: arrow = "arrow.right"
        }
        return GestureTile(arrow: arrow, action: set.action(d), flash: recent(d.rawValue)) { a in
            var s = set
            s.setAction(a, for: d)
            onChange(s)
        }
    }

    private var clickTile: some View {
        GestureTile(arrow: "cursorarrow.click", action: set.click, flash: recent("click")) { a in
            var s = set
            s.click = a
            onChange(s)
        }
    }
}

struct GestureTile: View {
    let arrow: String
    let action: Action
    let flash: Bool
    let onPick: (Action) -> Void
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button {
            open = true
        } label: {
            VStack(spacing: 5) {
                Image(systemName: arrow).font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                Image(systemName: action == .default || action == .nothing ? "plus" : action.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(action == .default || action == .nothing ? Color.secondary : Color.accentColor)
                Text(action == .default || action == .nothing ? "Nothing" : action.title(role: "other"))
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(width: 104, height: 82)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(flash ? Color.accentColor.opacity(0.28) : hovering ? Color.primary.opacity(0.07) : Color.primary.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(flash ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: flash ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: flash)
        .popover(isPresented: $open) {
            ActionPicker(current: action, role: "other", compact: true) {
                onPick($0)
                if !$0.isCustomValue { open = false }
            }
            .padding(14)
            .frame(width: 360, height: 460)
        }
    }
}

// MARK: - Thumb wheel

struct ThumbwheelEditor: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let binding = model.thumbwheelBinding
        let caps = model.device?.capabilities
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "Turning the wheel")
            VStack(spacing: 2) {
                ForEach(ThumbwheelPresets.all) { p in
                    ActionRow(title: p.title, symbol: p.symbol, hint: nil,
                              selected: ThumbwheelPresets.match(binding)?.id == p.id) {
                        model.setThumbwheel(p.binding)
                    }
                }
                ActionRow(title: "Two Actions of Your Choice", symbol: "slider.horizontal.2.square", hint: nil,
                          selected: ThumbwheelPresets.match(binding) == nil) {
                    if ThumbwheelPresets.match(binding) != nil || !binding.isActions {
                        model.setThumbwheel(.actions(left: .builtin("undo"), right: .builtin("redo"), stepDegrees: 20))
                    }
                }
            }
            switch binding {
            case .scroll(let speed):
                LabeledSlider(title: "Speed", value: speed, range: 0.25...4, step: 0.05,
                              format: { String(format: "%.2f×", $0) }) { model.setThumbwheel(.scroll(speed: $0), throttle: true) }
            case .zoom(let speed):
                LabeledSlider(title: "Speed", value: speed, range: 0.25...4, step: 0.05,
                              format: { String(format: "%.2f×", $0) }) { model.setThumbwheel(.zoom(speed: $0), throttle: true) }
            case .actions(let left, let right, let step):
                HStack {
                    Label("Turn left", systemImage: "arrow.left").frame(width: 100, alignment: .leading)
                    ActionMenuButton(current: left, role: "other") { model.setThumbwheel(.actions(left: $0, right: right, stepDegrees: step)) }
                }
                HStack {
                    Label("Turn right", systemImage: "arrow.right").frame(width: 100, alignment: .leading)
                    ActionMenuButton(current: right, role: "other") { model.setThumbwheel(.actions(left: left, right: $0, stepDegrees: step)) }
                }
                LabeledSlider(title: "Step", value: step, range: 5...90, step: 1,
                              format: { "\(Int($0))°" }) { model.setThumbwheel(.actions(left: left, right: right, stepDegrees: $0), throttle: true) }
            case .native:
                Text("macOS scrolls sideways itself, in coarse steps. Smooth Horizontal Scroll glides instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Reverse direction", isOn: Binding(
                get: { model.deviceConfig?.settings.thumbwheelInvert ?? false },
                set: { v in model.editDevice { $0.settings.thumbwheelInvert = v } }))
            if caps?.thumbwheelTap == true {
                Divider()
                SectionLabel(text: "Tapping the wheel")
                ActionMenuButton(current: model.thumbwheelTap, role: "other", placeholder: "Nothing") { model.setThumbwheelTap($0) }
            }
        }
    }
}

extension ThumbwheelBinding {
    var isActions: Bool {
        if case .actions = self { return true }
        return false
    }
}

// MARK: - Small building blocks

struct LabeledSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    let format: (Double) -> String
    let onChange: (Double) -> Void
    @State private var local: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(local ?? value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { local ?? value }, set: { raw in
                let v = step > 0 ? (raw / step).rounded() * step : raw
                local = v
                onChange(v)
            }), in: range) { editing in
                if !editing { local = nil }
            }
        }
    }
}

/// Lays chips out in rows.
struct FlowChips<Item: Identifiable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items) { content($0) }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
