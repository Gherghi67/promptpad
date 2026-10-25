import Foundation
import Darwin
import PromptpadCore

/// A private directory and persistent lock inode shared with the Python protocol.
enum PrivateRuntime {
    static func verifyDirectory(_ path: String, create: Bool) throws {
        if create, mkdir(path, 0o700) != 0, errno != EEXIST { throw failure("Cannot create private runtime directory.") }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o7777 == 0o700 else {
            throw failure("Runtime directory must be an owned, non-symlink directory with mode 0700: \(path)")
        }
    }
    static func failure(_ message: String) -> BridgeFailure { .init(.unavailable, message) }
}

final class InstanceLock {
    private var descriptor: Int32 = -1
    init(directory: String = BridgeProtocol.socketDirectory(userID: getuid())) throws {
        try PrivateRuntime.verifyDirectory(directory, create: true)
        let fd = open(directory + "/app.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PrivateRuntime.failure("Cannot open app instance lock.") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o7777 == 0o600, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw PrivateRuntime.failure("Another companion is running, or app.lock has unsafe ownership or permissions. Quit the other instance and check the runtime directory.")
        }
        descriptor = fd
    }
    func release() { if descriptor >= 0 { close(descriptor); descriptor = -1 } }
    deinit { release() }
}

private struct TransportFailure: Error { let underlying: Error; let sent: Bool }

/// Blocking POSIX work lives exclusively on a serial queue. The lock only protects
/// cancellation/shutdown; the queue owns close(), so descriptor reuse cannot race it.
private final class SocketTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Promptpad.bridge")
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false
    let path: String
    init(path: String, connectedSocket: Int32 = -1) {
        self.path = path; self.fd = connectedSocket
        if connectedSocket >= 0 {
            _ = fcntl(connectedSocket, F_SETFL, O_NONBLOCK)
            var value: Int32 = 1
            _ = setsockopt(connectedSocket, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
        }
    }
    func interrupt() {
        lock.withLock {
            cancelled = true
            if fd >= 0 { _ = shutdown(fd, SHUT_RDWR) }
        }
    }
    func closeStream() async {
        interrupt()
        await withCheckedContinuation { continuation in
            queue.async { self.closeOwned(); continuation.resume() }
        }
    }
    private func closeOwned() {
        lock.withLock { if fd >= 0 { close(fd); fd = -1 } }
    }
    func exchange(_ data: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var sent = false
                do {
                    // A cancelled stream is never reused.
                    if self.lock.withLock({ self.cancelled }) { throw CancellationError() }
                    let deadline = ProcessInfo.processInfo.systemUptime + BridgeProtocol.requestTimeout
                    let socket = try self.connect(deadline: min(deadline, ProcessInfo.processInfo.systemUptime + BridgeProtocol.connectTimeout))
                    let writeDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + BridgeProtocol.frameTimeout)
                    try data.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < bytes.count {
                            try self.ready(socket, events: Int16(POLLOUT), deadline: writeDeadline)
                            let count = Darwin.send(socket, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                            if count > 0 { sent = true; offset += count }
                            else if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                            else { throw BridgeFailure(.disconnected, "Bridge disconnected while writing.") }
                        }
                    }
                    let readDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + BridgeProtocol.frameTimeout)
                    let header = try self.read(socket, count: 4, deadline: readDeadline)
                    let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    guard count > 0, count <= BridgeProtocol.maxFrameBytes else { throw BridgeFailure(.tooLarge, "Bridge returned an invalid frame length.") }
                    let payload = try self.read(socket, count: Int(count), deadline: readDeadline)
                    continuation.resume(returning: payload)
                } catch {
                    self.closeOwned()
                    continuation.resume(throwing: TransportFailure(underlying: error, sent: sent))
                }
            }
        }
    }
    private func connect(deadline: TimeInterval) throws -> Int32 {
        if let existing = lock.withLock({ fd >= 0 ? fd : nil }) { return existing }
        try PrivateRuntime.verifyDirectory((path as NSString).deletingLastPathComponent, create: false)
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK,
              info.st_mode & 0o7777 == 0o600 else {
            throw PrivateRuntime.failure("Start the Python bridge; its socket must be owned by you with mode 0600.")
        }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw PrivateRuntime.failure("Cannot create bridge socket.") }
        lock.withLock { fd = socket }
        guard fcntl(socket, F_SETFL, O_NONBLOCK) >= 0,
              fcntl(socket, F_SETFD, FD_CLOEXEC) >= 0 else {
            throw PrivateRuntime.failure("Cannot configure nonblocking bridge deadlines.")
        }
        var noSigPipe: Int32 = 1
        guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw PrivateRuntime.failure("Cannot configure bridge socket.") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw PrivateRuntime.failure("Bridge socket path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw PrivateRuntime.failure("Cannot reach the bridge. Start it with the iTerm2 Python runtime.") }
            try ready(socket, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw PrivateRuntime.failure("Bridge connection failed. Restart the bridge.") }
        }
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(socket, &uid, &gid) == 0, uid == getuid() else { throw PrivateRuntime.failure("Bridge peer UID does not match yours.") }
        return socket
    }
    private func ready(_ socket: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            if lock.withLock({ cancelled }) { throw CancellationError() }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw BridgeFailure(.timeout, "Bridge request deadline expired.") }
            var item = pollfd(fd: socket, events: events, revents: 0)
            let result = poll(&item, 1, Int32(min(remaining * 1000, 25).rounded(.up)))
            if result > 0 {
                if item.revents & events != 0 { return }
                throw BridgeFailure(.disconnected, "Bridge stream closed.")
            }
            if result < 0, errno != EINTR { throw BridgeFailure(.disconnected, "Bridge socket poll failed.") }
        }
    }
    private func read(_ socket: Int32, count: Int, deadline: TimeInterval) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                try ready(socket, events: Int16(POLLIN), deadline: deadline)
                let received = recv(socket, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
                if received > 0 { offset += received }
                else if received < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                else { throw BridgeFailure(.disconnected, "Bridge returned a truncated frame.") }
            }
        }
        return result
    }
    deinit { if fd >= 0 { close(fd) } }
}

actor UnixBridgeClient: BridgeClient {
    private let path: String
    private var transport: SocketTransport?
    private var inFlight = false
    init(path: String = BridgeProtocol.socketPath(userID: getuid())) { self.path = path }
    /// Adopts a connected socketpair endpoint for transport tests; production always validates the path/peer.
    init(testingSocket: Int32) {
        self.path = ""
        self.transport = SocketTransport(path: "", connectedSocket: testingSocket)
    }
    func request(_ request: BridgeRequest) async throws -> BridgeResponse {
        try request.validate()
        guard !inFlight else { throw BridgeFailure(.busy, "A bridge request is already in flight.") }
        try Task.checkCancellation()
        inFlight = true
        defer { inFlight = false }
        let stream = transport ?? SocketTransport(path: path)
        transport = stream
        let mutation = [.insertText, .control, .selectPane, .selectTab].contains(request.operation)
        let frame = try BridgeProtocol.encode(request)
        do {
            let payload = try await withTaskCancellationHandler { try await stream.exchange(frame) } onCancel: { stream.interrupt() }
            let response: BridgeResponse
            do { response = try JSONDecoder().decode(BridgeResponse.self, from: payload) }
            catch { throw BridgeFailure(mutation ? .outcomeUnknown : .invalidRequest, "Invalid bridge reply. Inspect the captured terminal before acknowledging; do not retry the action.") }
            do { try response.validate(for: request) }
            catch {
                // Only a structurally validated error reply proves a deliberate refusal.
                if response.error == (error as? BridgeFailure), !response.ok,
                   response.id == request.id, response.version == BridgeProtocol.version,
                   response.target == nil, response.page == nil,
                   (response.error?.message.utf8.count ?? 1025) <= 1024 {
                    if mutation, [.timeout, .disconnected, .outcomeUnknown].contains(response.error!.code) {
                        throw BridgeFailure(.outcomeUnknown, "Action outcome is unknown. Inspect session \(request.target?.sessionID ?? "unknown") before acknowledging. No action was retried.")
                    }
                    throw error
                }
                throw BridgeFailure(mutation ? .outcomeUnknown : .invalidRequest, "Untrusted bridge reply. Inspect the captured terminal before acknowledging.")
            }
            return response
        } catch {
            transport = nil
            await stream.closeStream()
            if let failure = error as? TransportFailure {
                if mutation, failure.sent { throw BridgeFailure(.outcomeUnknown, "Action outcome is unknown for session \(request.target?.sessionID ?? "unknown"). Inspect that terminal before acknowledging. No action was retried.") }
                throw failure.underlying
            }
            throw error
        }
    }
    func disconnect() async {
        let old = transport; transport = nil
        await old?.closeStream()
    }
}
