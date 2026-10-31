import AppKit
import MouseMasterKit

/// The menu bar item: battery at a glance and quick switches.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    unowned let agent: Agent
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private var lastTitle = ""
    private var lastSymbol = ""

    init(agent: Agent) {
        self.agent = agent
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func update() {
        let general = agent.store.config.general
        guard general.showMenuBarIcon else {
            if let item {
                NSStatusBar.system.removeStatusItem(item)
                self.item = nil
                lastTitle = ""
                lastSymbol = ""
            }
            return
        }
        if item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            i.menu = menu
            i.button?.imagePosition = .imageLeading
            i.autosaveName = "MouseMasterStatusItem"
            item = i
        }
        guard let button = item?.button else { return }
        let device = agent.onlineControllers.first?.snapshot
        let paused = general.paused
        let warning = needsSetup
        let symbol = warning ? "exclamationmark.triangle" : paused ? "computermouse" : "computermouse.fill"
        var title = ""
        if general.showBatteryInMenuBar, let p = device?.battery?.percent {
            title = " \(p)%"
        }
        if symbol != lastSymbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mouse Master")
            image?.isTemplate = true
            button.image = image?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            lastSymbol = symbol
        }
        if title != lastTitle {
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular),
            ])
            lastTitle = title
        }
        button.appearsDisabled = paused
        button.toolTip = device.map { "\($0.name)\($0.battery?.percent.map { " – \($0)%" } ?? "")" } ?? "Mouse Master"
    }

    private var needsSetup: Bool {
        !agent.permissions.accessibility || (agent.permissions.inputMonitoringNeeded && !agent.permissions.inputMonitoring)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let general = agent.store.config.general

        if needsSetup {
            let i = NSMenuItem(title: "Finish Setting Up Mouse Master…", action: #selector(openSettings), keyEquivalent: "")
            i.target = self
            i.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(i)
            let note = NSMenuItem(title: "Two permissions are missing; until then the mouse works as usual.", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            menu.addItem(.separator())
        }

        let controllers = agent.onlineControllers
        if controllers.isEmpty {
            let i = NSMenuItem(title: "No Logitech mouse connected", action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        for c in controllers {
            guard let s = c.snapshot else { continue }
            addDevice(c, s, to: menu)
        }

        menu.addItem(.separator())
        let pause = NSMenuItem(title: general.paused ? "Resume Mouse Master" : "Pause Mouse Master",
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.image = NSImage(systemSymbolName: general.paused ? "play.circle" : "pause.circle", accessibilityDescription: nil)
        menu.addItem(pause)
        let open = NSMenuItem(title: "Mouse Master Settings…", action: #selector(openSettings), keyEquivalent: ",")
        open.target = self
        open.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Mouse Master", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addDevice(_ c: DeviceController, _ s: DeviceSnapshot, to menu: NSMenu) {
        let header = NSMenuItem(title: s.name, action: nil, keyEquivalent: "")
        header.isEnabled = false
        let title = NSMutableAttributedString(string: s.name, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        if let p = s.battery?.percent {
            title.append(NSAttributedString(string: "   \(p)%\(s.battery?.charging == true ? " ⚡︎" : "")",
                                            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                                                         .foregroundColor: NSColor.secondaryLabelColor]))
        }
        header.attributedTitle = title
        header.image = NSImage(systemSymbolName: DeviceController.batterySymbol(s.battery), accessibilityDescription: nil)
        menu.addItem(header)

        let settings = c.config.settings
        if let caps = s.capabilities.dpi {
            let dpiItem = NSMenuItem(title: "Pointer Speed: \(s.state.dpi.map { "\($0) DPI" } ?? "–")", action: nil, keyEquivalent: "")
            dpiItem.image = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)
            let sub = NSMenu()
            var values = settings.dpiPresets.isEmpty ? DeviceSettings.defaultDPIPresets : settings.dpiPresets
            if let cur = s.state.dpi, !values.contains(cur) { values.append(cur) }
            for v in Array(Set(values.map { caps.snap($0) })).sorted() {
                let i = NSMenuItem(title: "\(v) DPI", action: #selector(setDPI(_:)), keyEquivalent: "")
                i.target = self
                i.tag = v
                i.representedObject = s.id
                i.state = s.state.dpi == v ? .on : .off
                sub.addItem(i)
            }
            dpiItem.submenu = sub
            menu.addItem(dpiItem)
        }
        if s.capabilities.hiresWheel {
            let smooth = NSMenuItem(title: "Smooth Scrolling", action: #selector(toggleSmooth(_:)), keyEquivalent: "")
            smooth.target = self
            smooth.representedObject = s.id
            smooth.state = settings.effectiveSmoothScroll ? .on : .off
            smooth.image = NSImage(systemSymbolName: "scroll", accessibilityDescription: nil)
            menu.addItem(smooth)
        }
        if s.capabilities.smartShift {
            let ss = NSMenuItem(title: "SmartShift", action: #selector(toggleSmartShift(_:)), keyEquivalent: "")
            ss.target = self
            ss.representedObject = s.id
            ss.state = s.state.smartShiftEnabled == true ? .on : .off
            ss.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: nil)
            menu.addItem(ss)
        }
        let hosts = s.state.hosts.filter(\.paired)
        if hosts.count > 1 {
            let es = NSMenuItem(title: "Easy-Switch", action: nil, keyEquivalent: "")
            es.image = NSImage(systemSymbolName: "laptopcomputer.and.arrow.down", accessibilityDescription: nil)
            let sub = NSMenu()
            for h in s.state.hosts {
                let name = h.name.isEmpty ? "Computer \(h.index + 1)" : h.name
                let i = NSMenuItem(title: "\(h.index + 1)  \(name)", action: #selector(switchHost(_:)), keyEquivalent: "")
                i.target = self
                i.tag = h.index
                i.representedObject = s.id
                i.state = h.current ? .on : .off
                i.isEnabled = h.paired && !h.current
                sub.addItem(i)
            }
            es.submenu = sub
            menu.addItem(es)
        }
        if let profile = s.activeProfile, let p = c.config.profiles.first(where: { $0.id == profile }) {
            let i = NSMenuItem(title: "Profile: \(p.name)", action: nil, keyEquivalent: "")
            i.isEnabled = false
            i.image = NSImage(systemSymbolName: "app.badge", accessibilityDescription: nil)
            menu.addItem(i)
        }
    }

    private func controller(_ sender: NSMenuItem) -> DeviceController? {
        guard let id = sender.representedObject as? String else { return nil }
        return agent.devices.controller(for: id)
    }

    @objc private func setDPI(_ sender: NSMenuItem) {
        controller(sender)?.setUserDPI(sender.tag)
    }

    @objc private func toggleSmooth(_ sender: NSMenuItem) {
        controller(sender)?.perform(.toggleSmoothScroll)
    }

    @objc private func toggleSmartShift(_ sender: NSMenuItem) {
        controller(sender)?.perform(.toggleSmartShift)
    }

    @objc private func switchHost(_ sender: NSMenuItem) {
        controller(sender)?.switchHost(sender.tag)
    }

    @objc private func togglePause() {
        var g = agent.store.config.general
        g.paused.toggle()
        agent.setGeneral(g)
    }

    @objc private func openSettings() {
        Agent.openSettingsApp()
    }

    @objc private func quit() {
        agent.terminate()
    }
}
