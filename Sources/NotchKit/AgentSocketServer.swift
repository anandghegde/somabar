import Darwin
import Foundation
import os
import Security

/// N11's local channel: a Unix domain socket that takes one JSON `AgentMessage` per line.
///
/// Local only, never a network listener. The socket's folder is 0700 and the socket 0600, and
/// each connection is checked again: the peer must run as this user and its code signature must
/// be valid. Reads are event-driven (`DispatchSource`), so an idle socket costs nothing.
/// Somabar never writes back: approving a tool call from the notch waits for an outside review
/// of this socket (PRD, P2).
public final class AgentSocketServer: @unchecked Sendable {
    /// What is known of a connecting process.
    public struct Peer: Sendable {
        public var uid: uid_t
        public var pid: pid_t
        /// The signing identifier, when the signature was valid.
        public var signingID: String?
    }

    /// Called on the server's queue for each accepted line.
    public var onMessage: (@Sendable (AgentMessage) -> Void)?
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

    private final class Connection {
        let source: DispatchSourceRead
        var buffer = Data()

        init(source: DispatchSourceRead) {
            self.source = source
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

    /// `~/Library/Application Support/Somabar/agent.sock`.
    public static var defaultPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return support.appending(path: "Somabar/agent.sock").path
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
        for fd in Array(connections.keys) {
            drop(fd)
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
            connections[fd] = Connection(source: source)
            source.resume()
        }
    }

    private func read(_ fd: Int32) {
        guard let connection = connections[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &chunk, chunk.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0 else {
            // End of stream: a last line without a newline still counts.
            deliver(connection.buffer)
            drop(fd)
            return
        }
        connection.buffer.append(contentsOf: chunk[0..<count])
        while let newline = connection.buffer.firstIndex(of: 0x0A) {
            let line = connection.buffer[connection.buffer.startIndex..<newline]
            deliver(Data(line))
            connection.buffer.removeSubrange(connection.buffer.startIndex...newline)
        }
        if connection.buffer.count > AgentMessage.maxLineBytes {
            log.error("Agent socket dropped a connection that sent an overlong line")
            drop(fd)
        }
    }

    private func deliver(_ line: Data) {
        guard !line.isEmpty, let text = String(data: line, encoding: .utf8) else { return }
        guard let message = AgentMessage.parse(line: text) else {
            log.info("Agent socket ignored a line that is not a status message")
            return
        }
        onMessage?(message)
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
