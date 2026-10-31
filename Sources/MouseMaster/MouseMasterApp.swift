import AppKit
import Carbon
import MouseMasterKit
import SwiftUI

@main
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
