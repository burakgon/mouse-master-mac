import AppKit
import Carbon
import MouseMasterKit
import SwiftUI

struct MouseMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Mouse Master", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1080, minHeight: 680)
                .task { model.start() }
        }
        .defaultSize(width: 1320, height: 840)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Mouse") {
                Button(model.general.paused ? "Resume Mouse Master" : "Pause Mouse Master") {
                    model.editGeneral { $0.paused.toggle() }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                ForEach(Array(Page.allCases.enumerated()), id: \.element) { i, page in
                    Button(page.title) { model.page = page }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--register-agent") {
            // Used by the installer: (re)register the background agent and leave.
            AgentLauncher.reregister()
            exit(0)
        }
        KeyNames.layoutName = KeyboardLayout.name(for:)
        // The bundle is a UI element so the agent instance stays out of the Dock; the
        // settings window is a regular app with a Dock icon and a menu bar.
        NSApp.setActivationPolicy(.regular)
        // --pretend-active: draw windows as if they were in front (screenshots taken while
        // another app is in use).
        if args.contains("--pretend-active") { ScreenshotMode.drawWindowsAsActive() }
        // --appearance light|dark (screenshots, or to override the system setting).
        if let i = args.firstIndex(of: "--appearance"), i + 1 < args.count {
            NSApp.appearance = NSAppearance(named: args[i + 1] == "light" ? .aqua : .darkAqua)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        // --window-size 1320x840 (screenshots).
        if let i = args.firstIndex(of: "--window-size"), i + 1 < args.count {
            let size = args[i + 1].split(separator: "x").compactMap { Double($0) }
            if size.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    for w in NSApp.windows where w.isVisible && w.frame.width > 400 {
                        w.setContentSize(NSSize(width: size[0], height: size[1]))
                    }
                }
            }
        }
        if !args.contains("--background") { NSApp.activate() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The agent does the work; the app only needs to run while its window is open.
        true
    }
}

/// Names of keys on the current keyboard layout (so a Turkish Q keyboard shows "Ş", not ";").
enum KeyboardLayout {
    static func name(for code: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let err = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                     OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            guard err == noErr, length > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .controlCharacters)
            return s.isEmpty ? nil : s
        }
    }
}

enum ScreenshotMode {
    static func drawWindowsAsActive() {
        for (original, replacement) in [(#selector(getter: NSWindow.isKeyWindow), #selector(getter: NSWindow.mm_alwaysKey)),
                                        (#selector(getter: NSWindow.isMainWindow), #selector(getter: NSWindow.mm_alwaysMain))] {
            if let a = class_getInstanceMethod(NSWindow.self, original),
               let b = class_getInstanceMethod(NSWindow.self, replacement) {
                method_exchangeImplementations(a, b)
            }
        }
        if let a = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive)),
           let b = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.mm_alwaysActive)) {
            method_exchangeImplementations(a, b)
        }
    }
}

extension NSApplication {
    @objc var mm_alwaysActive: Bool { true }
}

extension NSWindow {
    @objc var mm_alwaysKey: Bool { true }
    @objc var mm_alwaysMain: Bool { true }
}
