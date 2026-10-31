import AppKit
import MouseMasterKit

/// The background agent: owns the devices and performs the actions. It is the app's own
/// executable started with `--agent` (by launchd at login), so macOS sees one application,
/// "Mouse Master", in its permission lists. The settings window is a second instance.
public enum AgentMain {
    public static func run() -> Never {
        let arguments = CommandLine.arguments
        if arguments.contains("--verbose") || arguments.contains("-v") { Log.verbose = true }
        if arguments.contains("--trace") {
            Log.verbose = true
            Log.traceHIDPP = true
        }
        setvbuf(stderr, nil, _IONBF, 0)

        // launchd starts agents with a limit of 256 open files; leave some headroom.
        var fileLimit = rlimit()
        if getrlimit(RLIMIT_NOFILE, &fileLimit) == 0 && fileLimit.rlim_cur < 2048 {
            fileLimit.rlim_cur = min(2048, fileLimit.rlim_max)
            setrlimit(RLIMIT_NOFILE, &fileLimit)
        }

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            // No Dock icon and no menu bar for the agent, only its status item.
            app.setActivationPolicy(.accessory)
            let delegate = AgentDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) {
                app.run()
            }
        }
        exit(0)
    }
}

enum SingleInstance {
    nonisolated(unsafe) private static var fd: Int32 = -1

    /// Holds a lock for the lifetime of the process. Waits a little for an agent that is
    /// still shutting down (updates restart the agent); false if another one keeps running.
    static func acquire(waitSeconds: Double = 4) -> Bool {
        MMPaths.ensureSupportDirectory()
        if fd < 0 { fd = open(MMPaths.lockPath, O_CREAT | O_RDWR, 0o600) }
        guard fd >= 0 else { return true }
        let deadline = Date().addingTimeInterval(waitSeconds)
        repeat {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
            usleep(100_000)
        } while Date() < deadline
        return false
    }

    static func release() {
        if fd >= 0 { close(fd) }
        fd = -1
    }
}

final class AgentDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard SingleInstance.acquire() else {
                Log.info("another Mouse Master agent is already running")
                exit(0)
            }
            Agent.shared.start()
        }
    }

    /// Opening Mouse Master while the agent runs reaches the agent (same application):
    /// show the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { Agent.openSettingsApp() }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { Agent.shared.terminate() }
        return .terminateLater
    }
}
