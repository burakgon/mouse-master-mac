import AppKit
import MouseMasterKit
import SwiftUI

struct ButtonsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Buttons",
                       subtitle: "Click a button to choose what it does. Press it on your mouse to find it.")
            ProfileBar()
                .padding(.horizontal, 28)
                .padding(.bottom, 6)
            HStack(alignment: .top, spacing: 0) {
                MouseStage()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let key = model.selectedControl {
                    ControlInspector(key: key)
                        .frame(width: 360)
                        .padding(.trailing, 20)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .id("\(key)-\(model.selectedProfileID ?? "all")")
                }
            }
            .animation(.snappy(duration: 0.28), value: model.selectedControl)
        }
    }
}

// MARK: - Application profiles

struct ProfileBar: View {
    @Environment(AppModel.self) private var model
    @State private var picking = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "All Apps", symbol: "square.stack.3d.up", selected: model.selectedProfileID == nil) {
                    model.selectedProfileID = nil
                }
                ForEach(model.deviceConfig?.profiles ?? []) { p in
                    ProfileChip(profile: p, selected: model.selectedProfileID == p.id,
                                active: model.device?.activeProfile == p.id)
                }
                Button {
                    picking = true
                } label: {
                    Label("Add App", systemImage: "plus")
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().strokeBorder(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Give an application its own button setup")
            }
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $picking) {
            AppPicker { name, bundleID in
                model.addProfile(name: name, bundleID: bundleID)
                picking = false
            } cancel: {
                picking = false
            }
        }
    }
}

struct ProfileChip: View {
    @Environment(AppModel.self) private var model
    let profile: AppProfile
    let selected: Bool
    let active: Bool

    var body: some View {
        Button {
            model.selectedProfileID = profile.id
        } label: {
            HStack(spacing: 6) {
                if let id = profile.apps.first { AppIconView(bundleID: id, size: 17) }
                Text(profile.name)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .strikethrough(!profile.enabled)
                if active {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                        .help("\(profile.name) is in front: these settings are in use")
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(selected ? 0 : 0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(profile.enabled ? "Turn Off" : "Turn On") {
                model.setProfileEnabled(profile.id, !profile.enabled)
            }
            Divider()
            Button("Remove \(profile.name)", role: .destructive) {
                model.removeProfile(profile.id)
            }
        }
    }
}

// MARK: - The mouse

/// Where each control sits on the artwork (in the artwork's 400 × 560 coordinates).
struct DeviceLayout {
    enum Side { case left, right }

    struct Spot {
        let point: CGPoint
        let side: Side
    }

    let art: String
    let spots: [String: Spot]

    static func forDevice(_ name: String) -> DeviceLayout {
        let n = name.lowercased()
        func s(_ x: CGFloat, _ y: CGFloat, _ side: Side) -> Spot { Spot(point: CGPoint(x: x, y: y), side: side) }
        if n.contains("mx master") {
            return DeviceLayout(art: "mx-master", spots: [
                "right": s(284, 108, .right), "middle": s(213, 132, .right), "mode-shift": s(213, 201, .right),
                "left": s(158, 118, .left), "thumbwheel": s(96, 280, .left), "forward": s(78, 323, .left),
                "back": s(80, 355, .left), "haptic-panel": s(92, 395, .left), "gesture": s(66, 426, .left),
            ])
        }
        if n.contains("mx anywhere") {
            return DeviceLayout(art: "mx-anywhere", spots: [
                "right": s(256, 150, .right), "middle": s(200, 142, .right), "mode-shift": s(200, 213, .right),
                "left": s(146, 160, .left), "forward": s(113, 283, .left), "back": s(113, 335, .left),
                "gesture": s(200, 400, .right),
            ])
        }
        return DeviceLayout(art: "generic-mouse", spots: [
            "left": s(146, 150, .left), "right": s(256, 150, .right), "middle": s(200, 128, .right),
            "forward": s(100, 305, .left), "back": s(100, 353, .left), "gesture": s(200, 400, .right),
            "mode-shift": s(200, 205, .right), "thumbwheel": s(100, 250, .left), "dpi": s(200, 215, .right),
        ])
    }
}

struct StageItem: Identifiable {
    let id: String
    let name: String
    let role: String
    let spot: DeviceLayout.Spot?
}

struct MouseStage: View {
    @Environment(AppModel.self) private var model

    private var items: [StageItem] {
        guard let d = model.device else { return [] }
        let layout = DeviceLayout.forDevice(d.name)
        var list = d.controls.map { StageItem(id: $0.key, name: $0.name, role: $0.role, spot: layout.spots[$0.key]) }
        if d.capabilities.thumbwheel {
            list.insert(StageItem(id: "thumbwheel", name: "Thumb wheel", role: "thumbwheel", spot: layout.spots["thumbwheel"]), at: 0)
        }
        return list
    }

    var body: some View {
        let d = model.device
        let layout = DeviceLayout.forDevice(d?.name ?? "")
        let placed = items.filter { $0.spot != nil }
        let others = items.filter { $0.spot == nil }
        VStack(spacing: 0) {
            GeometryReader { geo in
                let g = StageGeometry(size: geo.size, items: placed)
                ZStack(alignment: .topLeading) {
                    // Artwork
                    if let art = Artwork.image(layout.art) {
                        Image(nsImage: art)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: g.art.width, height: g.art.height)
                            .shadow(color: .black.opacity(0.28), radius: 26, y: 18)
                            .position(x: g.art.midX, y: g.art.midY)
                            .opacity(d?.online == false ? 0.55 : 1)
                    }
                    // Leader lines
                    Canvas { ctx, _ in
                        for item in placed {
                            guard let spot = g.spotPoint(item), let anchor = g.anchor(item) else { continue }
                            let selected = model.selectedControl == item.id
                            var path = Path()
                            path.move(to: anchor)
                            let dx = (spot.x - anchor.x) * 0.5
                            path.addCurve(to: spot, control1: CGPoint(x: anchor.x + dx, y: anchor.y),
                                          control2: CGPoint(x: spot.x - dx * 0.4, y: spot.y))
                            ctx.stroke(path, with: .color(selected ? Color.accentColor : Color.primary.opacity(0.22)),
                                       style: StrokeStyle(lineWidth: selected ? 2 : 1.2, lineCap: .round))
                        }
                    }
                    .allowsHitTesting(false)
                    // Hot spots
                    ForEach(placed) { item in
                        if let p = g.spotPoint(item) {
                            Hotspot(selected: model.selectedControl == item.id, pressed: model.pressed.contains(item.id)) {
                                select(item.id)
                            }
                            .position(p)
                        }
                    }
                    // Callouts
                    ForEach(placed) { item in
                        if let frame = g.callout(item) {
                            Callout(item: item, width: frame.width,
                                    selected: model.selectedControl == item.id,
                                    pressed: model.pressed.contains(item.id) || (item.id == "thumbwheel" && model.pressed.contains("thumbwheel-tap"))) {
                                select(item.id)
                            }
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            if !others.isEmpty {
                HStack(spacing: 10) {
                    ForEach(others) { item in
                        Callout(item: item, width: 210, selected: model.selectedControl == item.id,
                                pressed: model.pressed.contains(item.id)) { select(item.id) }
                            .frame(width: 210, height: 52)
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedControl = nil }
    }

    private func select(_ id: String) {
        model.selectedControl = model.selectedControl == id ? nil : id
    }
}

/// Positions of the artwork, hot spots and callouts for a stage size.
struct StageGeometry {
    let art: CGRect
    let calloutWidth: CGFloat
    private var frames: [String: CGRect] = [:]
    private var spots: [String: CGPoint] = [:]
    private var anchors: [String: CGPoint] = [:]

    init(size: CGSize, items: [StageItem]) {
        let margin: CGFloat = 14
        var calloutWidth: CGFloat = size.width >= 1000 ? 224 : size.width >= 840 ? 200 : size.width >= 700 ? 178 : 158
        let gap: CGFloat = size.width >= 900 ? 60 : size.width >= 720 ? 36 : 22
        var maxArtW = size.width - 2 * (margin + calloutWidth + gap)
        if maxArtW < 180 {
            // Narrow window: slimmer callouts leave room for the mouse.
            calloutWidth = max(132, (size.width - 2 * (margin + gap) - 180) / 2)
            maxArtW = max(120, size.width - 2 * (margin + calloutWidth + gap))
        }
        self.calloutWidth = calloutWidth
        var artH = min(size.height * 0.9, 600)
        var artW = artH * 400 / 560
        if artW > maxArtW {
            artW = maxArtW
            artH = artW * 560 / 400
        }
        art = CGRect(x: (size.width - artW) / 2, y: (size.height - artH) / 2, width: artW, height: artH)
        let scale = artW / 400
        for item in items {
            guard let s = item.spot else { continue }
            spots[item.id] = CGPoint(x: art.minX + s.point.x * scale, y: art.minY + s.point.y * scale)
        }
        // Callouts per side, in order, kept apart.
        let height: CGFloat = 52
        let spacing: CGFloat = 62
        for side in [DeviceLayout.Side.left, .right] {
            let sideItems = items.filter { $0.spot?.side == side }.sorted { (spots[$0.id]?.y ?? 0) < (spots[$1.id]?.y ?? 0) }
            var ys = sideItems.map { spots[$0.id]?.y ?? 0 }
            for i in ys.indices.dropFirst() where ys[i] - ys[i - 1] < spacing { ys[i] = ys[i - 1] + spacing }
            // Pull the column back up if it ran off the bottom.
            if let last = ys.last, last > size.height - height / 2 - 8 {
                let shift = last - (size.height - height / 2 - 8)
                ys = ys.map { $0 - shift }
            }
            for (i, item) in sideItems.enumerated() {
                let y = max(ys[i], height / 2 + 4)
                let x = side == .left ? max(margin, art.minX - gap - calloutWidth)
                    : min(size.width - margin - calloutWidth, art.maxX + gap)
                let frame = CGRect(x: x, y: y - height / 2, width: calloutWidth, height: height)
                frames[item.id] = frame
                anchors[item.id] = CGPoint(x: side == .left ? frame.maxX : frame.minX, y: frame.midY)
            }
        }
    }

    func spotPoint(_ item: StageItem) -> CGPoint? { spots[item.id] }
    func callout(_ item: StageItem) -> CGRect? { frames[item.id] }
    func anchor(_ item: StageItem) -> CGPoint? { anchors[item.id] }
}

struct Hotspot: View {
    let selected: Bool
    let pressed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(pressed ? 0.35 : selected || hovering ? 0.22 : 0))
                    .frame(width: pressed ? 40 : 30, height: pressed ? 40 : 30)
                Circle()
                    .fill(selected || pressed ? Color.accentColor : Color.white)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(selected || pressed ? Color.white : Color.accentColor, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.25), value: pressed)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct Callout: View {
    @Environment(AppModel.self) private var model
    let item: StageItem
    let width: CGFloat
    let selected: Bool
    let pressed: Bool
    let action: () -> Void
    @State private var hovering = false

    private var value: (title: String, symbol: String) {
        if item.id == "thumbwheel" {
            let b = model.thumbwheelBinding
            if let p = ThumbwheelPresets.match(b) { return (p.title, p.symbol) }
            return ("Custom Actions", "slider.horizontal.2.square")
        }
        let a = model.action(for: item.id)
        return (a.title(role: item.role), a == .default ? NativeBehavior.symbol(role: item.role) : a.symbol)
    }

    private var overridden: Bool {
        item.id == "thumbwheel" ? model.thumbwheelOverridden : model.isOverridden(item.id)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: value.symbol, tint: selected || pressed ? .accentColor : .secondary, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(item.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if overridden {
                            Image(systemName: "app.badge.fill").font(.system(size: 9)).foregroundStyle(Color.accentColor)
                                .help("Set for this application")
                        }
                    }
                    Text(value.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: pressed ? Color.accentColor.opacity(0.55) : .black.opacity(hovering ? 0.14 : 0.07),
                            radius: pressed ? 14 : 8, y: pressed ? 0 : 3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected || pressed ? Color.accentColor : Color.primary.opacity(hovering ? 0.18 : 0.08),
                                  lineWidth: selected || pressed ? 2 : 1)
            }
            .scaleEffect(pressed ? 1.04 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.25), value: pressed)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
