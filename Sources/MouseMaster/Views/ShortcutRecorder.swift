import AppKit
import Carbon.HIToolbox
import MouseMasterKit
import SwiftUI

/// Records a key combination: press it on the keyboard. Modifiers alone (press and
/// release ⌘, for example) record a modifier-only combination.
struct ShortcutRecorder: View {
    let combo: KeyCombo?
    let onRecord: (KeyCombo) -> Void

    @State private var recording = false
    @State private var monitor: Any?
    @State private var liveModifiers: Modifiers = []
    @State private var peakModifiers: Modifiers = []

    var body: some View {
        HStack(spacing: 10) {
            Button {
                recording ? stop() : start()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: recording ? "record.circle.fill" : "keyboard")
                        .foregroundStyle(recording ? Color.red : Color.accentColor)
                        .symbolEffect(.pulse, isActive: recording)
                    if recording {
                        Text(liveModifiers.isEmpty ? "Type the shortcut…" : liveModifiers.symbols)
                            .foregroundStyle(.secondary)
                    } else if let combo {
                        KeyCaps(text: combo.label)
                    } else {
                        Text("Click to record").foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(recording ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: recording ? 2 : 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if recording {
                Button("Cancel") { stop() }.controlSize(.small)
            }
        }
        .onDisappear { stop() }
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> Modifiers {
        var m = Modifiers()
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.function) { m.insert(.function) }
        return m
    }

    private func start() {
        recording = true
        liveModifiers = []
        peakModifiers = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                let m = Self.modifiers(event.modifierFlags).subtracting(.function)
                if m.isEmpty, !peakModifiers.isEmpty {
                    // Released without a key: a modifier-only combination.
                    finish(KeyCombo(keyCode: nil, modifiers: peakModifiers, display: peakModifiers.symbols))
                } else {
                    liveModifiers = m
                    peakModifiers = peakModifiers.union(m)
                }
                return nil
            }
            let code = Int(event.keyCode)
            var mods = Self.modifiers(event.modifierFlags)
            // Arrows, F-keys and the navigation block carry fn by themselves.
            if KeyCode.functionFlagKeys.contains(code) || KeyNames.isSpecial(code) { mods.remove(.function) }
            if code == kVK_Escape && mods.isEmpty {
                stop()
                return nil
            }
            finish(KeyCombo(keyCode: code, modifiers: mods, display: mods.symbols + KeyNames.name(for: code)))
            return nil
        }
    }

    private func finish(_ combo: KeyCombo) {
        stop()
        onRecord(combo)
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        liveModifiers = []
        peakModifiers = []
    }
}
