import Darwin
import Foundation
import Synchronization
import Testing
@testable import NotchKit

@Suite(.serialized) struct AgentSocketServerTests {
    /// A short folder: socket paths are limited to 104 bytes.
    private func makeFolder() throws -> String {
        let folder = "/tmp/sb-\(UUID().uuidString.prefix(8))"
        #expect(mkdir(folder, 0o700) == 0)
        return folder
    }

    private func connectAndSend(_ path: String, _ text: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return false }
        let bytes = Array(text.utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else { return false }
        // Like `nc -U`: half-close, then wait for Somabar to close, so the peer can be checked.
        shutdown(fd, SHUT_WR)
        var byte: UInt8 = 0
        while read(fd, &byte, 1) > 0 {}
        return true
    }

    /// Connects and sends without closing, the way a hook that waits for an answer does. The
    /// caller reads with `readReply` and closes the descriptor.
    private func connectAndAsk(_ path: String, _ text: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        let bytes = Array(text.utf8)
        guard connected == 0, write(fd, bytes, bytes.count) == bytes.count else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Everything Somabar writes until it closes (or 3 s pass).
    private func readReply(_ fd: Int32) -> String {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 256)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            data.append(contentsOf: chunk[0..<count])
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private static let requestLine = #"{"request":"r1","session":"a","tool":"Bash","detail":"ls"}"# + "\n"

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func receivesLinesFromThisUser() async throws {
        let folder = try makeFolder()
        let path = folder + "/agent.sock"
        let server = AgentSocketServer(path: path)
        let received = Mutex<[AgentMessage]>([])
        server.onMessage = { message in received.withLock { $0.append(message) } }
        try server.start()

        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(info.st_uid == getuid())

        let lines = #"{"session":"a","state":"working","project":"web"}"# + "\n" + "garbage\n"
            + #"{"session":"a","state":"needsYou"}"#
        #expect(connectAndSend(path, lines))
        await waitFor { received.withLock { $0.count } >= 2 }
        let states = received.withLock { $0.map(\.state) }
        #expect(states == [.working, .needsYou])

        server.stop()
        #expect(lstat(path, &info) != 0, "The socket file goes with the server")
        rmdir(folder)
    }

    @Test func answersTheRequestThatAsked() async throws {
        let folder = try makeFolder()
        let path = folder + "/agent.sock"
        let server = AgentSocketServer(path: path)
        let asked = Mutex<[(String, UInt64)]>([])
        server.onRequest = { request, connection in asked.withLock { $0.append((request.id, connection)) } }
        server.setAcceptsRequests(true)
        try server.start()

        let fd = try #require(connectAndAsk(path, Self.requestLine))
        defer { close(fd) }
        await waitFor { !asked.withLock { $0.isEmpty } }
        let connection = try #require(asked.withLock { $0.first?.1 })
        #expect(asked.withLock { $0.first?.0 } == "r1")
        server.answer(connection: connection, id: "other", decision: .allow)
        server.answer(connection: connection + 1, id: "r1", decision: .allow)
        server.answer(connection: connection, id: "r1", decision: .deny)
        #expect(readReply(fd) == #"{"decision":"deny","id":"r1"}"# + "\n", "Only the matching answer, then the close")

        server.stop()
        rmdir(folder)
    }

    @Test func withRepliesOffARequestIsAReportAndAsk() async throws {
        let folder = try makeFolder()
        let path = folder + "/agent.sock"
        let server = AgentSocketServer(path: path)
        let received = Mutex<[AgentMessage]>([])
        let asked = Mutex(0)
        server.onMessage = { message in received.withLock { $0.append(message) } }
        server.onRequest = { _, _ in asked.withLock { $0 += 1 } }
        try server.start()

        let fd = try #require(connectAndAsk(path, Self.requestLine))
        defer { close(fd) }
        #expect(readReply(fd) == #"{"decision":"ask","id":"r1"}"# + "\n")
        await waitFor { !received.withLock { $0.isEmpty } }
        #expect(received.withLock { $0.map(\.state) } == [.needsYou])
        #expect(asked.withLock { $0 } == 0)

        server.stop()
        rmdir(folder)
    }

    @Test func aHookThatLeavesIsReported() async throws {
        let folder = try makeFolder()
        let path = folder + "/agent.sock"
        let server = AgentSocketServer(path: path)
        let asked = Mutex<UInt64?>(nil)
        let closed = Mutex<UInt64?>(nil)
        server.onRequest = { _, connection in asked.withLock { $0 = connection } }
        server.onRequestClosed = { connection in closed.withLock { $0 = connection } }
        server.setAcceptsRequests(true)
        try server.start()

        let fd = try #require(connectAndAsk(path, Self.requestLine))
        await waitFor { asked.withLock { $0 } != nil }
        close(fd)
        await waitFor { closed.withLock { $0 } != nil }
        #expect(closed.withLock { $0 } == asked.withLock { $0 })

        server.stop()
        rmdir(folder)
    }

    @Test func stoppingAnswersAsk() async throws {
        let folder = try makeFolder()
        let path = folder + "/agent.sock"
        let server = AgentSocketServer(path: path)
        let asked = Mutex(false)
        server.onRequest = { _, _ in asked.withLock { $0 = true } }
        server.setAcceptsRequests(true)
        try server.start()

        let fd = try #require(connectAndAsk(path, Self.requestLine))
        defer { close(fd) }
        await waitFor { asked.withLock { $0 } }
        server.stop()
        #expect(readReply(fd) == #"{"decision":"ask","id":"r1"}"# + "\n")
        rmdir(folder)
    }

    @Test func refusedPeersAreDropped() async throws {
        let folder = try makeFolder()
        let path = folder + "/agent.sock"
        let server = AgentSocketServer(path: path)
        let received = Mutex(0)
        server.acceptsPeer = { _ in false }
        server.onMessage = { _ in received.withLock { $0 += 1 } }
        try server.start()
        _ = connectAndSend(path, #"{"session":"a","state":"working"}"# + "\n")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(received.withLock { $0 } == 0)
        server.stop()
        rmdir(folder)
    }

    @Test func thisProcessPassesThePeerCheck() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let peer = AgentSocketServer.peer(of: fds[0])
        #expect(peer?.uid == getuid())
        #expect(peer?.pid == getpid())
        #expect(peer?.signingID != nil, "The test runner is signed, if only ad hoc")
    }

    @Test func leavesAnythingButASocketAlone() throws {
        let folder = try makeFolder()
        let path = folder + "/agent.sock"
        FileManager.default.createFile(atPath: path, contents: Data("keep".utf8))
        let server = AgentSocketServer(path: path)
        #expect(throws: AgentSocketServer.StartError.notASocket) { try server.start() }
        #expect(FileManager.default.contents(atPath: path) == Data("keep".utf8))
        unlink(path)
        rmdir(folder)
    }

    @Test func refusesTooLongAPath() {
        let server = AgentSocketServer(path: "/tmp/" + String(repeating: "a", count: 120))
        #expect(throws: AgentSocketServer.StartError.pathTooLong) { try server.start() }
    }
}
