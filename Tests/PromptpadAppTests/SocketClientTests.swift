import XCTest
import Darwin
import PromptpadCore
@testable import PromptpadApp

private final class SocketPeer: @unchecked Sendable {
    let client: Int32
    let server: Int32
    init() throws {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw XCTSkip("Socketpair unavailable") }
        client = pair[0]; server = pair[1]
        var value: Int32 = 1
        _ = setsockopt(server, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    }
    func receive() -> BridgeRequest? {
        func bytes(_ count: Int) -> Data? {
            var data = Data(count: count)
            let okay = data.withUnsafeMutableBytes { raw -> Bool in
                var offset = 0
                while offset < count {
                    let n = recv(server, raw.baseAddress!.advanced(by: offset), count - offset, 0)
                    if n <= 0 { return false }; offset += n
                }
                return true
            }
            return okay ? data : nil
        }
        guard let header = bytes(4) else { return nil }
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count <= 65536, let payload = bytes(count) else { return nil }
        return try? JSONDecoder().decode(BridgeRequest.self, from: payload)
    }
    func sendBytes(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = send(server, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if n <= 0 { return }; offset += n
            }
        }
    }
    func respondJSON(_ json: String, fragmented: Bool = false) {
        let payload = Data(json.utf8); let n = UInt32(payload.count)
        let frame = Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]) + payload
        if fragmented { for byte in frame { sendBytes(Data([byte])) } } else { sendBytes(frame) }
    }
    func finish() { _ = shutdown(server, SHUT_RDWR) }
    deinit { close(server) } // the client owns its adopted endpoint
}

final class SocketClientTests: XCTestCase, @unchecked Sendable {
    func testRealSocketFragmentationAndPersistentSequentialRequests() async throws {
        let peer = try SocketPeer(); let client = UnixBridgeClient(testingSocket: peer.client)
        let server = Task.detached {
            for _ in 0..<2 {
                guard let request = peer.receive() else { return }
                peer.respondJSON("{\"version\":1,\"id\":\"\(request.id)\",\"ok\":true}", fragmented: true)
            }
        }
        for _ in 0..<2 { let response = try await client.request(.init(operation: .ping)); XCTAssertTrue(response.ok) }
        await client.disconnect(); await server.value
    }
    func testLostMutationReplyIsUnknownAndNotRetried() async throws {
        let peer = try SocketPeer(); let client = UnixBridgeClient(testingSocket: peer.client)
        let server = Task.detached { _ = peer.receive(); peer.finish() }
        let target = TerminalTarget(sessionID: "s", windowID: "w", tabID: "t", title: "test")
        do { _ = try await client.request(.init(operation: .insertText, target: target, text: "hello")); XCTFail("Expected ambiguity") }
        catch let failure as BridgeFailure { XCTAssertEqual(failure.code, .outcomeUnknown) }
        await client.disconnect(); await server.value
    }
    func testOversizedHeaderRejectedWithoutAllocatingPayload() async throws {
        let peer = try SocketPeer(); let client = UnixBridgeClient(testingSocket: peer.client)
        let server = Task.detached { _ = peer.receive(); peer.sendBytes(Data([0, 1, 0, 1])) }
        do { _ = try await client.request(.init(operation: .ping)); XCTFail("Expected oversized error") }
        catch let failure as BridgeFailure { XCTAssertEqual(failure.code, .tooLarge) }
        await client.disconnect(); await server.value
    }
    func testCancellationClosesPendingRead() async throws {
        let peer = try SocketPeer(); let client = UnixBridgeClient(testingSocket: peer.client)
        let received = expectation(description: "Request received")
        let server = Task.detached { _ = peer.receive(); received.fulfill() }
        let pending = Task { try await client.request(.init(operation: .ping)) }
        await fulfillment(of: [received], timeout: 1)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation") } catch { }
        await client.disconnect(); await server.value
    }
    func testConcurrentRequestRejectedRatherThanQueued() async throws {
        let peer = try SocketPeer(); let client = UnixBridgeClient(testingSocket: peer.client)
        let received = expectation(description: "Request received")
        let server = Task.detached { _ = peer.receive(); received.fulfill() }
        let pending = Task { try await client.request(.init(operation: .ping)) }
        await fulfillment(of: [received], timeout: 1)
        do { _ = try await client.request(.init(operation: .ping)); XCTFail("Expected busy") }
        catch let failure as BridgeFailure { XCTAssertEqual(failure.code, .busy) }
        pending.cancel(); _ = try? await pending.value
        await client.disconnect(); await server.value
    }
    func testAbsoluteReadDeadlineAndMutationAmbiguity() async throws {
        let peer = try SocketPeer(); let client = UnixBridgeClient(testingSocket: peer.client)
        let server = Task.detached { _ = peer.receive(); peer.sendBytes(Data([0])) }
        let target = TerminalTarget(sessionID: "s", windowID: "w", tabID: "t", title: "test")
        let start = ProcessInfo.processInfo.systemUptime
        do { _ = try await client.request(.init(operation: .insertText, target: target, text: "hello")); XCTFail("Expected timeout") }
        catch let failure as BridgeFailure { XCTAssertEqual(failure.code, .outcomeUnknown) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3.5)
        await client.disconnect(); await server.value
    }
    func testMismatchedResponseIDRejected() async throws {
        let peer = try SocketPeer(); let client = UnixBridgeClient(testingSocket: peer.client)
        let server = Task.detached {
            _ = peer.receive(); peer.respondJSON("{\"version\":1,\"id\":\"\(UUID().uuidString)\",\"ok\":true}")
        }
        do { _ = try await client.request(.init(operation: .ping)); XCTFail("Expected invalid response") }
        catch let failure as BridgeFailure { XCTAssertEqual(failure.code, .invalidRequest) }
        await client.disconnect(); await server.value
    }
    func testInstanceLockRejectsSecondInstanceAndUnsafeDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-lock-test-" + UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let first = try InstanceLock(directory: root)
        XCTAssertThrowsError(try InstanceLock(directory: root))
        first.release()
        let second = try InstanceLock(directory: root); second.release()
        XCTAssertEqual(chmod(root, 0o755), 0)
        XCTAssertThrowsError(try InstanceLock(directory: root))
    }
    func testInstanceLockRejectsSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-link-test-" + UUID().uuidString).path
        try FileManager.default.createSymbolicLink(atPath: root, withDestinationPath: "/tmp")
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertThrowsError(try InstanceLock(directory: root))
    }
}
