import AppKit
import MouseMasterKit
import SwiftUI

extension AppModel {
    var inputMonitoringMissing: Bool {
        guard let p = state?.permissions else { return false }
        return p.inputMonitoringNeeded && !p.inputMonitoring
    }

    var accessibilityMissing: Bool { state.map { !$0.permissions.accessibility } ?? false }

    var needsPermissions: Bool { inputMonitoringMissing || accessibilityMissing }
}

/// First run: the two permissions macOS asks for, one step at a time, ticking off live.
struct PermissionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                VStack(spacing: 12) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon).resizable().frame(width: 92, height: 92)
                            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                    }
                    Text("Two quick permissions")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Mouse Master reads your mouse's buttons and wheels, and does what you assign to them.\nmacOS asks you to allow that once.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 30)

                VStack(spacing: 14) {
                    PermissionStep(number: 1, symbol: "computermouse",
                                   title: "Input Monitoring",
                                   detail: "Lets Mouse Master talk to your mouse: its buttons, wheels and battery.",
                                   granted: !model.inputMonitoringMissing,
                                   active: model.inputMonitoringMissing,
                                   pane: "Privacy_ListenEvent") {
                        model.command(IPCRequest(cmd: "request-input-monitoring"))
                    }
                    PermissionStep(number: 2, symbol: "hand.tap",
                                   title: "Accessibility",
                                   detail: "Lets Mouse Master press keys, click and scroll for you.",
                                   granted: !model.accessibilityMissing,
                                   active: !model.inputMonitoringMissing && model.accessibilityMissing,
                                   pane: "Privacy_Accessibility") {
                        model.command(IPCRequest(cmd: "request-accessibility"))
                    }
                }
                .frame(maxWidth: 620)

                VStack(alignment: .leading, spacing: 6) {
                    Label("In System Settings, turn on **Mouse Master**. If it is already on, turn it off and on again.",
                          systemImage: "lightbulb")
                    Label("Nothing to restart: this page moves on by itself.", systemImage: "arrow.triangle.2.circlepath")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 620, alignment: .leading)

                Text("Until then your mouse simply keeps its normal behaviour.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
    }
}

struct PermissionStep: View {
    let number: Int
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let active: Bool
    let pane: String
    let request: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(granted ? Color.green : active ? Color.accentColor : Color.primary.opacity(0.08))
                    .frame(width: 40, height: 40)
                if granted {
                    Image(systemName: "checkmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(active ? Color.white : Color.secondary)
                }
            }
            .animation(.spring(duration: 0.4), value: granted)
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: symbol).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if granted {
                Text("Allowed").font(.callout.weight(.semibold)).foregroundStyle(.green)
            } else {
                Button(active ? "Allow…" : "Open Settings") {
                    request()
                    // The system prompt appears first; the settings pane follows.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(active ? .accentColor : .gray)
                .controlSize(.large)
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(active ? 0.12 : 0.05), radius: active ? 16 : 8, y: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(active ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.07), lineWidth: active ? 2 : 1)
        }
        .opacity(granted || active ? 1 : 0.75)
    }
}
