import Foundation
import Darwin

public enum MMPaths {
    public static let appBundleID = "com.burakgon.MouseMaster"
    public static let agentBundleID = "com.burakgon.MouseMaster.Agent"
    public static let agentLabel = "com.burakgon.MouseMaster.Agent"
    public static let agentPlistName = "com.burakgon.MouseMaster.Agent.plist"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Mouse Master", isDirectory: true)
    }

    public static var configURL: URL { supportDirectory.appendingPathComponent("config.json") }
    public static var deviceCacheURL: URL { supportDirectory.appendingPathComponent("devices.json") }
    public static var lockPath: String { supportDirectory.appendingPathComponent("agent.lock").path }

    public static var socketPath: String {
        let p = supportDirectory.appendingPathComponent("agent.sock").path
        if p.utf8.count < 100 { return p }
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("mouse-master-agent.sock")
    }

    public static func ensureSupportDirectory() {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }
}

/// A request from a client (the app or mmctl) to the agent.
public struct IPCRequest: Codable, Sendable {
    public var id: Int
    public var cmd: String
    public var device: String?
    public var deviceConfig: DeviceConfig?
    public var general: General?
    public var host: Int?
    public var name: String?
    public var action: Action?
    public var flag: Bool?
    public var hex: String?

    public init(id: Int = 0, cmd: String, device: String? = nil, deviceConfig: DeviceConfig? = nil,
                general: General? = nil, host: Int? = nil, name: String? = nil, action: Action? = nil,
                flag: Bool? = nil, hex: String? = nil) {
        self.id = id
        self.cmd = cmd
        self.device = device
        self.deviceConfig = deviceConfig
        self.general = general
        self.host = host
        self.name = name
        self.action = action
        self.flag = flag
        self.hex = hex
    }
}

/// A reply or an event from the agent.
public struct IPCMessage: Codable, Sendable {
    /// Id of the request this replies to.
    public var re: Int?
    public var ok: Bool?
    public var error: String?
    public var text: String?
    /// "state", "button", "gesture" or "motion".
    public var event: String?
    public var state: AgentState?
    public var device: String?
    public var control: String?
    public var pressed: Bool?
    public var gesture: String?
    public var dx: Int?
    public var dy: Int?

    public init(re: Int? = nil, ok: Bool? = nil, error: String? = nil, text: String? = nil, event: String? = nil,
                state: AgentState? = nil, device: String? = nil, control: String? = nil, pressed: Bool? = nil,
                gesture: String? = nil, dx: Int? = nil, dy: Int? = nil) {
        self.re = re
        self.ok = ok
        self.error = error
        self.text = text
        self.event = event
        self.state = state
        self.device = device
        self.control = control
        self.pressed = pressed
        self.gesture = gesture
        self.dx = dx
        self.dy = dy
    }
}

public enum IPCCoding {
    public static func encode<T: Encodable>(_ value: T) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return try? e.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

/// A newline delimited message stream over a connected socket. All callbacks and calls
/// happen on `queue`.
public final class LineConnection {
    public let fd: Int32
    public let queue: DispatchQueue
    public var onLine: ((Data) -> Void)?
    public var onClose: (() -> Void)?
    public private(set) var isClosed = false

    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var inBuffer: [UInt8] = []
    private var outBuffer: [UInt8] = []
    private var liveSources = 0

    public init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    public func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [weak self] in self?.sourceCancelled() }
        liveSources += 1
        readSource = source
        source.resume()
    }

    private func sourceCancelled() {
        liveSources -= 1
        if liveSources == 0 { Darwin.close(fd) }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                inBuffer.append(contentsOf: buffer[0..<n])
                continue
            }
            if n == 0 {
                close()
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            close()
            return
        }
        var start = 0
        while let nl = inBuffer[start...].firstIndex(of: 0x0A) {
            let line = Data(inBuffer[start..<nl])
            start = nl + 1
            if !line.isEmpty { onLine?(line) }
            if isClosed { return }
        }
        if start > 0 { inBuffer.removeFirst(start) }
        if inBuffer.count > 32 << 20 { close() }
    }

    public func send(_ data: Data) {
        guard !isClosed else { return }
        outBuffer.append(contentsOf: data)
        outBuffer.append(0x0A)
        flush()
    }

    private func flush() {
        while !outBuffer.isEmpty {
            let n = outBuffer.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                outBuffer.removeFirst(n)
                continue
            }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
            close()
            return
        }
        if outBuffer.isEmpty {
            if let w = writeSource {
                writeSource = nil
                w.cancel()
            }
        } else if writeSource == nil {
            let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            w.setEventHandler { [weak self] in self?.flush() }
            w.setCancelHandler { [weak self] in self?.sourceCancelled() }
            liveSources += 1
            writeSource = w
            w.resume()
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        if let w = writeSource {
            writeSource = nil
            w.cancel()
        }
        if let r = readSource {
            readSource = nil
            r.cancel()
        } else if liveSources == 0 {
            Darwin.close(fd)
        }
        let handler = onClose
        onClose = nil
        onLine = nil
        handler?()
    }
}

private func makeAddress(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        let n = min(bytes.count, raw.count - 1)
        for i in 0..<n { raw[i] = bytes[i] }
        raw[n] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return addr
}

/// Listens on a Unix domain socket that only the current user can reach.
public final class LineServer {
    public let path: String
    public let queue: DispatchQueue
    public var onConnection: ((LineConnection) -> Void)?
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String, queue: DispatchQueue) {
        self.path = path
        self.queue = queue
    }

    public func start() throws {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var addr = makeAddress(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let e = errno
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: e) ?? .EIO)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let e = errno
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: e) ?? .EIO)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in self?.acceptAll() }
        source = s
        s.resume()
    }

    private func acceptAll() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                Darwin.close(client)
                continue
            }
            let c = LineConnection(fd: client, queue: queue)
            onConnection?(c)
            c.start()
        }
    }

    public func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        unlink(path)
    }
}

/// Connects to a Unix domain socket; returns the descriptor or nil.
public func connectUnixSocket(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = makeAddress(path)
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if r != 0 {
        Darwin.close(fd)
        return nil
    }
    return fd
}

/// A client of the agent: sends requests, receives replies and events on the main queue.
public final class AgentConnection {
    public var onMessage: ((IPCMessage) -> Void)?
    public var onDisconnect: (() -> Void)?
    public private(set) var isConnected = false

    private var connection: LineConnection?
    private var nextID = 1
    private var replies: [Int: (IPCMessage) -> Void] = [:]

    public init() {}

    @discardableResult
    public func connect(path: String = MMPaths.socketPath) -> Bool {
        guard !isConnected, let fd = connectUnixSocket(path) else { return isConnected }
        let c = LineConnection(fd: fd, queue: .main)
        c.onLine = { [weak self] data in
            guard let self, let msg = IPCCoding.decode(IPCMessage.self, data) else { return }
            if let re = msg.re, let reply = self.replies.removeValue(forKey: re) {
                reply(msg)
            } else {
                self.onMessage?(msg)
            }
        }
        c.onClose = { [weak self] in
            guard let self else { return }
            self.isConnected = false
            self.connection = nil
            let pending = self.replies
            self.replies.removeAll()
            for (_, r) in pending { r(IPCMessage(ok: false, error: "disconnected")) }
            self.onDisconnect?()
        }
        connection = c
        isConnected = true
        c.start()
        return true
    }

    public func send(_ request: IPCRequest, reply: ((IPCMessage) -> Void)? = nil) {
        guard let connection else {
            reply?(IPCMessage(ok: false, error: "not connected"))
            return
        }
        var r = request
        r.id = nextID
        nextID += 1
        if let reply { replies[r.id] = reply }
        if let data = IPCCoding.encode(r) { connection.send(data) }
    }

    public func disconnect() {
        connection?.close()
    }
}
