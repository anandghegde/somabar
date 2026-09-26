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
