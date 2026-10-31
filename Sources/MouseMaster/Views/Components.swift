import AppKit
import MouseMasterKit
import SwiftUI

// MARK: - Surfaces

struct CardBackground: ViewModifier {
    var radius: CGFloat = 16
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
    }
}

extension View {
    func card(radius: CGFloat = 16, padding: CGFloat = 16) -> some View {
        modifier(CardBackground(radius: radius, padding: padding))
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    init(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }
}

/// A rounded icon tile.
struct IconTile: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

struct Banner: View {
    enum Kind { case warning, info, error }
    let kind: Kind
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    private var tint: Color {
        switch kind {
        case .warning: return .orange
        case .info: return .accentColor
        case .error: return .red
        }
    }

    private var symbol: String {
        switch kind {
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.regular)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}

/// Battery level with the right symbol.
struct BatteryBadge: View {
    let battery: BatteryInfo?

    var symbol: String {
        guard let b = battery else { return "battery.0percent" }
        if b.charging { return "battery.100percent.bolt" }
        switch b.percent ?? 50 {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var color: Color {
        guard let p = battery?.percent, battery?.charging != true else { return .secondary }
        return p <= 15 ? .red : p <= 30 ? .orange : .secondary
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
            if let p = battery?.percent {
                Text("\(p)%").monospacedDigit()
            }
        }
        .foregroundStyle(color)
    }
}

/// A capsule label.
struct Chip: View {
    let title: String
    var symbol: String?
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.caption.weight(.semibold)) }
                Text(title).font(.callout.weight(selected ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background {
                Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.06))
            }
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(selected ? 0 : 0.08))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A keyboard shortcut drawn as key caps.
struct KeyCaps: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .rounded).weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// Section title used inside pages and the inspector.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }
}

/// An icon of an installed application.
struct AppIconView: View {
    let bundleID: String
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: AppIcons.icon(for: bundleID))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let i = cache[bundleID] { return i }
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        cache[bundleID] = image
        return image
    }

    static func name(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}

// MARK: - Resources

@MainActor
enum Artwork {
    private static var cache: [String: NSImage] = [:]

    static func url(_ name: String, _ ext: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: ext) { return u }
        // Running from the build folder during development.
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Artwork/\(name).\(ext)")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    static func image(_ name: String) -> NSImage? {
        if let i = cache[name] { return i }
        guard let u = url(name, "svg"), let i = NSImage(contentsOf: u) else { return nil }
        cache[name] = i
        return i
    }
}
