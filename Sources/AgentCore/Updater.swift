import AppKit
import MouseMasterKit
import Security
@preconcurrency import UserNotifications

/// Keeps Mouse Master up to date from its GitHub releases. It looks for a newer version a
/// few times a day and installs one when asked: it downloads the zipped app attached to
/// the release, checks that the same team signed it, swaps it in and restarts. A tampered
/// download, or anybody else's app, never replaces this one.
@MainActor
final class Updater {
    unowned let agent: Agent
    private(set) var status = UpdateStatus()
    private var release: GitHubRelease?
    private var timer: Timer?
    private var installing = false

    /// "owner/name" of the GitHub repository that publishes the releases.
    nonisolated static let repository = Bundle.main.object(forInfoDictionaryKey: "MMUpdateRepository") as? String
    /// The team that signs the releases (Developer ID).
    nonisolated static let teamID = Bundle.main.object(forInfoDictionaryKey: "MMUpdateTeamIdentifier") as? String
    static let interval: TimeInterval = 6 * 3600
    nonisolated static let notificationPrefix = "update-"

    /// Left behind when an update restarts the agent while the settings window is open: the
    /// new agent opens it again.
    static var reopenMarker: URL { MMPaths.supportDirectory.appendingPathComponent("reopen-settings") }

    init(agent: Agent) {
        self.agent = agent
    }

    /// Only an app bundle that knows where its releases are can update itself.
    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Self.repository != nil && Self.teamID != nil
    }

    var isBusy: Bool { status.phase != .idle }

    func start() {
        guard isAvailable else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            MainActor.assumeIsolated { self?.checkIfEnabled() }
        }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfEnabled() }
        }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func checkIfEnabled() {
        guard agent.store.config.general.checkForUpdates else { return }
        Task { [weak self] in
            // Offline right after login, say: try again sooner than the next round.
            guard let failed = await self?.check(), !failed.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30 * 60) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.status.error != nil else { return }
                    self.checkIfEnabled()
                }
            }
        }
    }

    // MARK: Checking

    /// Looks for a newer release. Returns why that failed, or nil.
    @discardableResult
    func check(userInitiated: Bool = false) async -> String? {
        guard isAvailable, let repository = Self.repository else {
            return "This copy of Mouse Master cannot update itself."
        }
        guard !installing else { return nil }
        change { $0.phase = .checking }
        do {
            let found = try await Self.latestRelease(of: repository, userAgent: userAgent)
            release = found
            let available = found.map { AppVersion.isNewer($0.version, than: agent.version) } ?? false
            change {
                $0.phase = installing ? $0.phase : .idle
                $0.error = nil
                $0.lastChecked = Date()
                $0.latestVersion = found?.version
                $0.available = available
                $0.notes = found?.notes
                $0.pageURL = found?.page.absoluteString
            }
            if available, let found {
                Log.info("Mouse Master \(found.version) is available (running \(agent.version))")
                if !userInitiated { announce(found) }
            }
            return nil
        } catch {
            let message = Self.describe(error)
            Log.error("cannot check for updates: \(message)")
            change {
                $0.phase = installing ? $0.phase : .idle
                $0.error = message
            }
            return message
        }
    }

    nonisolated static func latestRelease(of repository: String, userAgent: String) async throws -> GitHubRelease? {
        // UpdateFeedURL (defaults) stands in for GitHub when trying out updates; what it
        // offers still has to be signed by the team.
        let feed = UserDefaults.standard.string(forKey: "UpdateFeedURL")
            ?? "https://api.github.com/repos/\(repository)/releases/latest"
        guard let url = URL(string: feed) else {
            throw UpdateError.message("Invalid update feed \(feed).")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Nothing published yet.
        if code == 404 { return nil }
        guard code == 200 else { throw UpdateError.http(code) }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        return release.draft || release.prerelease ? nil : release
    }

    // MARK: Installing

    /// Downloads the newest release, checks it, puts it in place of this copy and restarts.
    /// Returns why that failed, or nil.
    @discardableResult
    func install() async -> String? {
        if !status.available || release == nil, let error = await check(userInitiated: true) { return error }
        guard let release, status.available else { return "Mouse Master is up to date." }
        guard let archive = release.archive, let team = Self.teamID else {
            return "Release \(release.version) has no app attached. Download it from GitHub instead."
        }
        guard !installing else { return nil }
        installing = true
        change {
            $0.phase = .downloading
            $0.error = nil
        }
        do {
            let installed = Bundle.main.bundleURL
            let app = try await Self.download(archive, near: installed, userAgent: userAgent)
            change { $0.phase = .installing }
            // Off the main actor: checking the signature of the whole bundle takes a moment, and
            // the main run loop handles the mouse.
            let current = agent.version
            try await Task.detached(priority: .userInitiated) {
                try Self.verify(app, team: team, newerThan: current)
                try Self.replace(installed, with: app)
            }.value
            Log.info("installed Mouse Master \(release.version); restarting")
            restart()
            return nil
        } catch {
            installing = false
            let message = Self.describe(error)
            Log.error("cannot install the update: \(message)")
            change {
                $0.phase = .idle
                $0.error = message
            }
            return message
        }
    }

    nonisolated private static func download(_ asset: GitHubRelease.Asset, near installed: URL,
                                             userAgent: String) async throws -> URL {
        let fm = FileManager.default
        // On the volume of the installed copy, so putting the new one in place is a rename.
        let work = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installed, create: true))
            ?? fm.temporaryDirectory.appendingPathComponent("Mouse Master Update \(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        var request = URLRequest(url: asset.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (file, response) = try await URLSession.shared.download(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UpdateError.http(code) }
        let zip = work.appendingPathComponent("update.zip")
        try fm.moveItem(at: file, to: zip)
        if asset.size > 0, let size = (try? fm.attributesOfItem(atPath: zip.path))?[.size] as? Int, size != asset.size {
            throw UpdateError.message("The download is incomplete (\(size) of \(asset.size) bytes).")
        }
        let unpacked = work.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", "-x", "-k", zip.path, unpacked.path)
        try? fm.removeItem(at: zip)
        guard let name = try fm.contentsOfDirectory(atPath: unpacked.path).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.message("The download does not contain the app.")
        }
        return unpacked.appendingPathComponent(name)
    }

    /// The update must be Mouse Master, signed by `team` and intact, and newer than this copy.
    nonisolated static func verify(_ app: URL, team: String, newerThan current: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.message("The downloaded app is not signed.")
        }
        let text = "anchor apple generic and identifier \"\(MMPaths.appBundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.message("Cannot check the signature of the download.")
        }
        var error: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        error?.release()
        guard status == errSecSuccess else {
            throw UpdateError.message(status == errSecCSReqFailed
                ? "The download is not signed by the Mouse Master developer."
                : "The download is damaged (signature error \(status)).")
        }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let version = info?["CFBundleShortVersionString"] as? String, AppVersion.isNewer(version, than: current) else {
            throw UpdateError.message("The download is not newer than version \(current).")
        }
    }

    /// Moves the new app to where this one is; puts this one back if that fails.
    nonisolated static func replace(_ installed: URL, with app: URL) throws {
        let fm = FileManager.default
        let folder = installed.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: folder.path) else {
            throw UpdateError.message("Mouse Master cannot write to \(folder.path). Download the new version from GitHub instead.")
        }
        let previous = app.deletingLastPathComponent().appendingPathComponent("Previous \(installed.lastPathComponent)")
        try fm.moveItem(at: installed, to: previous)
        do {
            try fm.moveItem(at: app, to: installed)
        } catch {
            try? fm.moveItem(at: previous, to: installed)
            throw error
        }
        // Running processes keep the old files until they exit.
        try? fm.removeItem(at: previous)
    }

    /// The settings window runs the old version too: close it, and the new agent opens it
    /// again. launchd starts the new agent once this one has given the mouse back.
    private func restart() {
        let me = ProcessInfo.processInfo.processIdentifier
        let windows = NSRunningApplication.runningApplications(withBundleIdentifier: MMPaths.appBundleID)
            .filter { $0.processIdentifier != me && $0.activationPolicy == .regular }
        if !windows.isEmpty {
            FileManager.default.createFile(atPath: Self.reopenMarker.path, contents: nil)
        }
        // A moment for replies to reach the clients that asked.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                for w in windows { kill(w.processIdentifier, SIGTERM) }
                self?.agent.relaunch()
            }
        }
    }

    // MARK: Telling the user

    /// A notification, once per version, for updates found in the background.
    private func announce(_ release: GitHubRelease) {
        let key = "announcedUpdate"
        guard Bundle.main.bundleIdentifier != nil, UserDefaults.standard.string(forKey: key) != release.version else { return }
        UserDefaults.standard.set(release.version, forKey: key)
        let version = release.version
        let identifier = Self.notificationPrefix + version
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Mouse Master \(version) is available"
            content.body = "Click to see what's new and install it."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    /// Asks whether to install the newest version.
    func presentUpdate() {
        guard let release, status.available else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Mouse Master \(release.version) is available"
        var info = "You have version \(agent.version)."
        if let notes = Self.summary(of: release.notes) { info += "\n\n" + notes }
        alert.informativeText = info
        alert.addButton(withTitle: "Install and Restart")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release Notes")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                if let error = await install() { Self.showError("Mouse Master could not be updated", error) }
            }
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(release.page)
        default:
            break
        }
    }

    /// "Check for Updates…" in the menu: always answers, even when there is nothing new.
    func checkAndReport() {
        Task {
            if let error = await check(userInitiated: true) {
                Self.showError("Mouse Master could not check for updates", error)
            } else if status.available {
                presentUpdate()
            } else {
                NSApp.activate()
                let alert = NSAlert()
                alert.messageText = "Mouse Master is up to date"
                alert.informativeText = "Version \(agent.version) is the newest version."
                alert.runModal()
            }
        }
    }

    private static func showError(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// The first lines of the release notes, without Markdown headings.
    nonisolated static func summary(of notes: String?) -> String? {
        guard let notes else { return nil }
        let lines = notes.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { return nil }
        var text = lines.prefix(10).joined(separator: "\n")
        if text.count > 900 { text = String(text.prefix(900)) + "…" }
        return text
    }

    // MARK: Helpers

    private var userAgent: String { "MouseMaster/\(agent.version)" }

    private func change(_ f: (inout UpdateStatus) -> Void) {
        let before = status
        f(&status)
        if status != before { agent.setNeedsPublish() }
    }

    nonisolated private static func run(_ tool: String, _ arguments: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError.message("\(URL(fileURLWithPath: tool).lastPathComponent) failed with status \(p.terminationStatus).")
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case let e as UpdateError: return e.description
        case let e as URLError: return e.localizedDescription
        default: return error.localizedDescription
        }
    }
}

enum UpdateError: Error, CustomStringConvertible {
    case message(String)
    case http(Int)

    var description: String {
        switch self {
        case .message(let m): return m
        case .http(403), .http(429): return "GitHub is limiting requests right now; try again later."
        case .http(let code): return "GitHub answered with status \(code)."
        }
    }
}

/// Clicking an update notification asks whether to install it.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if id.hasPrefix(Updater.notificationPrefix) { Agent.shared.updater.presentUpdate() }
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
