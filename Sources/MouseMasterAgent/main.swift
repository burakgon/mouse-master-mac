import AppKit
import MouseMasterKit

// Mouse Master agent: runs in the background (menu bar only), owns the devices and
// performs the actions. Launched at login by launchd; the settings app talks to it
// over a Unix domain socket.

let arguments = CommandLine.arguments
if arguments.contains("--verbose") || arguments.contains("-v") { Log.verbose = true }
if arguments.contains("--trace") {
    Log.verbose = true
    Log.traceHIDPP = true
}
setvbuf(stderr, nil, _IONBF, 0)

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { Agent.shared.terminate() }
        return .terminateLater
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AgentDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
