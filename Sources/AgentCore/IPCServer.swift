import AppKit
import HIDPP
import MouseMasterKit

/// Serves the settings app and mmctl over a Unix domain socket (newline delimited JSON).
@MainActor
final class IPCServer {
    unowned let agent: Agent

    private final class Client {
        let connection: LineConnection
        var subscribed = false
        var monitor = false

        init(connection: LineConnection) {
            self.connection = connection
        }
    }

    private var server: LineServer?
    private var clients: [ObjectIdentifier: Client] = [:]

    init(agent: Agent) {
        self.agent = agent
    }

    var hasSubscribers: Bool { clients.values.contains { $0.subscribed } }
    var monitoring: Bool { clients.values.contains { $0.monitor } }

    func start() {
        let s = LineServer(path: MMPaths.socketPath, queue: .main)
        s.onConnection = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        do {
            try s.start()
            server = s
        } catch {
            Log.error("cannot listen on \(MMPaths.socketPath): \(error)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    private func accept(_ connection: LineConnection) {
        let client = Client(connection: connection)
        let key = ObjectIdentifier(connection)
        clients[key] = client
        connection.onLine = { [weak self, weak client] data in
            MainActor.assumeIsolated {
                guard let self, let client else { return }
                guard let request = IPCCoding.decode(IPCRequest.self, data) else {
                    self.send(IPCMessage(ok: false, error: "malformed request"), to: client)
                    return
                }
                self.handle(request, from: client)
            }
        }
        connection.onClose = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasMonitoring = self.clients[key]?.monitor ?? false
                self.clients.removeValue(forKey: key)
                if wasMonitoring && !self.monitoring { self.agent.monitoringChanged() }
            }
        }
    }

    private func send(_ message: IPCMessage, to client: Client) {
        if let data = IPCCoding.encode(message) { client.connection.send(data) }
    }

    func broadcastState(_ state: AgentState) {
        guard let data = IPCCoding.encode(IPCMessage(event: "state", state: state)) else { return }
        for c in clients.values where c.subscribed { c.connection.send(data) }
    }

    func broadcastEvent(_ message: IPCMessage) {
        guard monitoring, let data = IPCCoding.encode(message) else { return }
        for c in clients.values where c.monitor { c.connection.send(data) }
    }

    private func reply(_ request: IPCRequest, to client: Client, ok: Bool = true, error: String? = nil,
                       text: String? = nil, state: AgentState? = nil) {
        send(IPCMessage(re: request.id, ok: ok, error: error, text: text, state: state), to: client)
    }

    private func controller(_ request: IPCRequest) -> DeviceController? {
        if let id = request.device, !id.isEmpty { return agent.devices.controller(for: id) }
        return agent.onlineControllers.first
    }

    private func handle(_ r: IPCRequest, from client: Client) {
        switch r.cmd {
        case "hello", "subscribe":
            client.subscribed = true
            let wasMonitoring = monitoring
            if let m = r.flag { client.monitor = m }
            if monitoring != wasMonitoring { agent.monitoringChanged() }
            reply(r, to: client, state: agent.makeState())

        case "state":
            reply(r, to: client, state: agent.makeState())

        case "monitor":
            let wasMonitoring = monitoring
            client.monitor = r.flag ?? true
            if monitoring != wasMonitoring { agent.monitoringChanged() }
            reply(r, to: client)

        case "set-device-config":
            guard let id = r.device, let cfg = r.deviceConfig else { return reply(r, to: client, ok: false, error: "device and deviceConfig required") }
            agent.setDeviceConfig(id, cfg)
            reply(r, to: client)

        case "set-general":
            guard let g = r.general else { return reply(r, to: client, ok: false, error: "general required") }
            agent.setGeneral(g)
            reply(r, to: client)

        case "set-config":
            // Import a whole configuration (JSON in `name`).
            guard let text = r.name, let data = text.data(using: .utf8),
                  let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
                return reply(r, to: client, ok: false, error: "invalid configuration")
            }
            agent.store.replace(cfg)
            agent.environmentChanged()
            reply(r, to: client)

        case "switch-host":
            guard let c = controller(r), let h = r.host else { return reply(r, to: client, ok: false, error: "no such device") }
            c.switchHost(h)
            reply(r, to: client)

        case "set-host-name":
            guard let c = controller(r), let h = r.host, let name = r.name else { return reply(r, to: client, ok: false, error: "no such device") }
            Task {
                do {
                    try await c.setHostName(h, name)
                    self.reply(r, to: client)
                } catch {
                    self.reply(r, to: client, ok: false, error: "\(error)")
                }
            }

        case "run-action":
            guard let action = r.action else { return reply(r, to: client, ok: false, error: "action required") }
            guard agent.permissions.accessibility else {
                return reply(r, to: client, ok: false, error: "Mouse Master needs the Accessibility permission to perform actions")
            }
            let request = agent.executor.run(action)
            controller(r)?.perform(request)
            reply(r, to: client)

        case "reset-device":
            guard let id = r.device else { return reply(r, to: client, ok: false, error: "device required") }
            agent.resetDevice(id)
            reply(r, to: client)

        case "forget-device":
            guard let id = r.device else { return reply(r, to: client, ok: false, error: "device required") }
            agent.forgetDevice(id)
            reply(r, to: client)

        case "request-accessibility":
            agent.permissions.promptAccessibility()
            reply(r, to: client)

        case "request-input-monitoring":
            agent.permissions.requestInputMonitoring()
            reply(r, to: client)

        case "quit-conflict":
            guard let id = r.name else { return reply(r, to: client, ok: false, error: "bundle id required") }
            agent.conflicts.quit(id)
            reply(r, to: client)

        case "reapply":
            for c in agent.devices.controllers { c.scheduleReconcile(force: true) }
            reply(r, to: client)

        case "raw":
            guard let c = controller(r), let hex = r.hex, let bytes = [UInt8](hexString: hex) else {
                return reply(r, to: client, ok: false, error: "device and hex (feature index, function, params) required")
            }
            Task {
                do {
                    let out = try await c.raw(bytes)
                    self.reply(r, to: client, text: out)
                } catch {
                    self.reply(r, to: client, ok: false, error: "\(error)")
                }
            }

        case "inject":
            guard let c = controller(r), let hex = r.hex, let bytes = [UInt8](hexString: hex) else {
                return reply(r, to: client, ok: false, error: "device and hex report required")
            }
            c.inject(bytes)
            reply(r, to: client)

        case "check-updates":
            Task {
                let error = await self.agent.updater.check(userInitiated: true)
                let s = self.agent.updater.status
                let text = s.available ? "Mouse Master \(s.latestVersion ?? "?") is available (this is \(self.agent.version))"
                                       : "Mouse Master \(self.agent.version) is up to date"
                self.reply(r, to: client, ok: error == nil, error: error, text: error == nil ? text : nil)
            }

        case "install-update":
            Task {
                let error = await self.agent.updater.install()
                self.reply(r, to: client, ok: error == nil, error: error,
                           text: error == nil ? "Installed Mouse Master \(self.agent.updater.status.latestVersion ?? ""); restarting" : nil)
            }

        case "osd":
            agent.hud.show(symbol: r.name ?? "computermouse", title: r.hex ?? "Mouse Master", level: nil)
            reply(r, to: client)

        case "quit":
            reply(r, to: client)
            agent.terminate()

        default:
            reply(r, to: client, ok: false, error: "unknown command \(r.cmd)")
        }
    }
}
