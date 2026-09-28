import Darwin
import Foundation
import os
import Security
import SomabarCore

/// N11's local channel: a Unix domain socket that takes one JSON `AgentLine` per line.
///
/// Local only, never a network listener. The socket's folder is 0700 and the socket 0600, and
/// each connection is checked again: the peer must run as this user and its code signature must
/// be valid. Reads are event-driven (`DispatchSource`), so an idle socket costs nothing.
///
/// Status reports are one-way. A permission request (P2) keeps its connection open; the only
/// thing Somabar ever writes is the one reply line to the connection that asked, then it closes.
/// While `acceptsRequests` is off a request counts as a "needs you" report and is answered "ask"
/// at once. One request per connection; later lines on it are ignored.
public final class AgentSocketServer: @unchecked Sendable {
    /// What is known of a connecting process.
    public struct Peer: Sendable {
        public var uid: uid_t
        public var pid: pid_t
        /// The signing identifier, when the signature was valid.
        public var signingID: String?
    }

    /// Called on the server's queue for each accepted status line.
    public var onMessage: (@Sendable (AgentMessage) -> Void)?
    /// Called on the server's queue for a permission request, with the connection's number. The
    /// connection stays open until `answer` (or the peer closes it).
    public var onRequest: (@Sendable (AgentPermissionRequest, UInt64) -> Void)?
    /// Called on the server's queue when a connection with an unanswered request closes.
    public var onRequestClosed: (@Sendable (UInt64) -> Void)?
    /// Decides whether a peer may talk; by default, this user and a valid signature.
    public var acceptsPeer: @Sendable (Peer) -> Bool = { $0.uid == getuid() && $0.signingID != nil }

    public let path: String
    public static let maxConnections = 16

    private let queue = DispatchQueue(label: "app.somabar.agent-socket")
    private let log = Logger(subsystem: "app.somabar", category: "activities")
    // Everything below is touched only on `queue`.
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private var nextSerial: UInt64 = 1
    private var takesRequests = false

    private final class Connection {
        let source: DispatchSourceRead
        let serial: UInt64
        var buffer = Data()
        /// The request this connection waits on an answer for.
        var request: AgentPermissionRequest?

        init(source: DispatchSourceRead, serial: UInt64) {
            self.source = source
            self.serial = serial
        }
    }

    public enum StartError: Error, Equatable {
        case pathTooLong
        case folder(Int32)
        case notASocket
        case socket(Int32)
        case bind(Int32)
        case listen(Int32)
    }

    public init(path: String) {
        self.path = path
    }

    deinit {
        // No one else holds the server now, so the queue's state can be read directly.
        for connection in connections.values {
            connection.source.cancel()
        }
        if let listenSource {
            listenSource.cancel()
            unlink(path)
        }
    }

    /// `agent.sock` beside the layout file: `~/Library/Application Support/Somabar`, or
    /// `$SOMABAR_DOCUMENT_DIR` so a test copy does not take over the real socket.
    public static var defaultPath: String {
        DocumentStore.defaultDirectory().appending(path: "agent.sock").path
    }

    // MARK: - Lifecycle

    /// Creates the folder (0700) and the socket (0600) and starts accepting. A stale socket file
    /// from an earlier run is replaced; anything else at the path is left alone.
    public func start() throws(StartError) {
        var result: Result<Void, StartError> = .success(())
        queue.sync { result = startOnQueue() }
        try result.get()
    }

    public func stop() {
        queue.sync { stopOnQueue() }
    }

    /// Whether permission requests wait for an answer. Off answers each one "ask" at once.
    public func setAcceptsRequests(_ accepts: Bool) {
        queue.sync { takesRequests = accepts }
    }

    /// Writes the one reply line to the connection that asked, and closes it. Nothing happens when
    /// that connection has gone or asked something else.
    public func answer(connection serial: UInt64, id: String, decision: AgentDecision) {
        queue.async { [weak self] in
            guard let self,
                  let entry = self.connections.first(where: { $0.value.serial == serial }),
                  let request = entry.value.request, request.id == id
            else { return }
            self.reply(entry.key, request, decision)
        }
    }

    private func startOnQueue() -> Result<Void, StartError> {
        guard listenFD < 0 else { return .success(()) }
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return .failure(.pathTooLong) }

        let folder = (path as NSString).deletingLastPathComponent
        if mkdir(folder, 0o700) != 0, errno != EEXIST { return .failure(.folder(errno)) }
        chmod(folder, 0o700)
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK else { return .failure(.notASocket) }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.socket(errno)) }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            return .failure(.bind(code))
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            return .failure(.listen(code))
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        listenSource = source
        log.notice("Agent socket listening at \(self.path, privacy: .public)")
        return .success(())
    }

    private func stopOnQueue() {
        guard listenFD >= 0 else { return }
        for (fd, connection) in connections {
            // A waiting hook hears "ask" rather than waiting out its own timeout.
            if let request = connection.request {
                reply(fd, request, .ask)
            } else {
                drop(fd)
            }
        }
        listenSource?.cancel()
        listenSource = nil
        listenFD = -1
        unlink(path)
        log.notice("Agent socket closed")
    }

    // MARK: - Connections

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            guard connections.count < Self.maxConnections else {
                close(fd)
                continue
            }
            let peer = Self.peer(of: fd)
            guard let peer, acceptsPeer(peer) else {
                log.error("Agent socket refused a connection (uid \(peer?.uid ?? 0), pid \(peer?.pid ?? 0))")
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(fd) }
            source.setCancelHandler { close(fd) }
            connections[fd] = Connection(source: source, serial: nextSerial)
            nextSerial += 1
            source.resume()
        }
    }

    private func read(_ fd: Int32) {
        guard let connection = connections[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &chunk, chunk.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0 else {
            // End of stream: a last line without a newline still counts. A hook that still waits
            // for an answer keeps its end open, so a close means it has gone.
            deliver(connection.buffer, from: fd)
            guard connections[fd] != nil else { return }
            let waited = connection.request != nil
            drop(fd)
            if waited { onRequestClosed?(connection.serial) }
            return
        }
        connection.buffer.append(contentsOf: chunk[0..<count])
        while let newline = connection.buffer.firstIndex(of: 0x0A) {
            let line = connection.buffer[connection.buffer.startIndex..<newline]
            deliver(Data(line), from: fd)
            guard connections[fd] != nil else { return }
            connection.buffer.removeSubrange(connection.buffer.startIndex...newline)
        }
        if connection.buffer.count > AgentMessage.maxLineBytes {
            log.error("Agent socket dropped a connection that sent an overlong line")
            let waited = connection.request != nil
            drop(fd)
            if waited { onRequestClosed?(connection.serial) }
        }
    }

    private func deliver(_ line: Data, from fd: Int32) {
        guard !line.isEmpty, let text = String(data: line, encoding: .utf8),
              let connection = connections[fd], connection.request == nil
        else { return }
        switch AgentLine.parse(line: text) {
        case .status(let message):
            onMessage?(message)
        case .request(let request):
            guard takesRequests, let onRequest else {
                // Replies are off: the agent still shows as waiting, and asks in its terminal.
                onMessage?(request.message)
                reply(fd, request, .ask)
                return
            }
            connection.request = request
            onRequest(request, connection.serial)
        case nil:
            log.info("Agent socket ignored a line that is neither a status report nor a request")
        }
    }

    /// The one write Somabar makes: a short line into an empty socket buffer, so a single
    /// non-blocking write takes it. Then the connection closes.
    private func reply(_ fd: Int32, _ request: AgentPermissionRequest, _ decision: AgentDecision) {
        let data = request.reply(decision)
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        log.notice("Agent request answered: \(decision.rawValue, privacy: .public)")
        drop(fd)
    }

    private func drop(_ fd: Int32) {
        connections[fd]?.source.cancel()
        connections[fd] = nil
    }

    // MARK: - Peer checks

    /// The peer's user id (`getpeereid`), pid, and signing identifier when its signature is
    /// valid. The signature is checked through the audit token, so a reused pid cannot pass.
    static func peer(of fd: Int32) -> Peer? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize)
        var token = audit_token_t()
        var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenSize) == 0 else {
            return Peer(uid: uid, pid: pid, signingID: nil)
        }
        return Peer(uid: uid, pid: pid, signingID: signingID(auditToken: token))
    }

    /// The signing identifier of a process with a valid code signature; nil otherwise.
    static func signingID(auditToken: audit_token_t) -> String? {
        let tokenData = withUnsafeBytes(of: auditToken) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess
        else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return "" }
        var information: CFDictionary?
        SecCodeCopySigningInformation(staticCode, [], &information)
        let info = information as? [String: Any]
        return info?[kSecCodeInfoIdentifier as String] as? String ?? ""
    }
}
