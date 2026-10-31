import AppKit

/// A small on-screen display, like the system volume HUD: pointer speed, wheel mode,
/// battery level. Shown on the screen with the pointer, never takes focus.
@MainActor
final class HUD {
    private var panel: NSPanel?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let bar = LevelBar()
    private var hideItem: DispatchWorkItem?

    private let height: CGFloat = 52

    func show(symbol: String, title text: String, level: Double?) {
        let panel = self.panel ?? makePanel()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 19, weight: .semibold))
        title.stringValue = text
        bar.isHidden = level == nil
        bar.level = level ?? 0

        let textWidth = ceil(title.attributedStringValue.size().width)
        let barWidth: CGFloat = level == nil ? 0 : 96
        let width = 22 + 26 + 12 + textWidth + (barWidth > 0 ? 16 + barWidth : 0) + 26
        let frame = NSRect(x: 0, y: 0, width: max(width, 150), height: height)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + 96)
        panel.setFrame(NSRect(origin: origin, size: frame.size), display: false)
        layout(width: frame.width, barWidth: barWidth)

        hideItem?.cancel()
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = panel.isVisible ? panel.alphaValue : 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                panel.animator().alphaValue = 1
            }
        }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: item)
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }

    private func layout(width: CGFloat, barWidth: CGFloat) {
        icon.frame = NSRect(x: 22, y: (height - 26) / 2, width: 26, height: 26)
        let textX: CGFloat = 22 + 26 + 12
        let textHeight = ceil(title.attributedStringValue.size().height)
        let textWidth = ceil(title.attributedStringValue.size().width) + 2
        title.frame = NSRect(x: textX, y: (height - textHeight) / 2, width: textWidth, height: textHeight)
        bar.frame = NSRect(x: textX + textWidth + 14, y: (height - 6) / 2, width: barWidth, height: 6)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false

        let content: NSView
        #if compiler(>=6.2)
        // Liquid Glass on macOS 26 and later (needs the macOS 26 SDK to build).
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = height / 2
            let inner = NSView()
            glass.contentView = inner
            content = glass
            setUp(container: inner)
            content.autoresizingMask = [.width, .height]
            p.contentView = content
            panel = p
            return p
        }
        #endif
        do {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = height / 2
            v.layer?.masksToBounds = true
            content = v
            setUp(container: v)
        }
        content.autoresizingMask = [.width, .height]
        p.contentView = content
        panel = p
        return p
    }

    private func setUp(container: NSView) {
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byClipping
        container.addSubview(icon)
        container.addSubview(title)
        container.addSubview(bar)
    }
}

/// A rounded level indicator.
final class LevelBar: NSView {
    var level: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        let w = max(bounds.height, bounds.width * CGFloat(min(max(level, 0), 1)))
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height), xRadius: r, yRadius: r).fill()
    }
}
