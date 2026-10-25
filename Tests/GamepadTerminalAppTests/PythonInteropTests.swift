import XCTest
import Foundation
import Darwin
import GamepadTerminalCore
@testable import GamepadTerminalApp

private final class PythonBridgeFixture {
    let process = Process()
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("gamepad-interop-\(UUID().uuidString).json")
    let client: Int32
    init(mode: String = "normal") throws {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        client = pair[0]
        _ = fcntl(pair[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(pair[1], F_SETFD, FD_CLOEXEC)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-m", "bridge.tests.swift_interop_fixture", mode]
        process.currentDirectoryURL = root
        let input = FileHandle(fileDescriptor: pair[1], closeOnDealloc: false)
        process.standardInput = input
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        process.standardOutput = output
        do { try process.run() }
        catch { close(pair[0]); close(pair[1]); throw error }
        try input.close()
        try output.close()
    }
    func report() async throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard !process.isRunning else {
            process.terminate()
            throw BridgeFailure(.timeout, "Python interoperability fixture did not exit.")
        }
        XCTAssertEqual(process.terminationStatus, 0)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: outputURL)) as? [String: Any])
    }
    deinit {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: outputURL)
    }
}

final class PythonInteropTests: XCTestCase, @unchecked Sendable {
    private let target = TerminalTarget(sessionID: "s1", windowID: "w1", tabID: "t1", title: "shell")

    func testSwiftClientPythonServerFramingAndPinnedSanitizedInsertion() async throws {
        let fixture = try PythonBridgeFixture()
        let client = UnixBridgeClient(testingSocket: fixture.client)
        do {
            let ping = try await client.request(.init(operation: .ping))
            XCTAssertTrue(ping.ok)
            let capture = try await client.request(.init(operation: .captureTarget))
            XCTAssertEqual(capture.target, target)
            let safe = try TranscriptSanitizer.validated("  echo\r\n café\t🌍\u{1b}\u{200b} ")
            XCTAssertEqual(safe, "echo café 🌍")
            let insertion = try await client.request(.init(operation: .insertText, target: capture.target, text: safe))
            XCTAssertEqual(insertion.target, target)
            let page = try await client.request(.init(operation: .readScrollback, target: target, lineCount: 40))
            XCTAssertEqual(page.page?.lines, ["old", "prompt"])
            await client.disconnect()
            let report = try await fixture.report()
            let sent = try XCTUnwrap(report["sent"] as? [[Any]])
            XCTAssertEqual(sent.count, 1) // No implicit Enter or retry.
            XCTAssertEqual(sent.first?.first as? String, safe)
            XCTAssertEqual(sent.first?.last as? Bool, true) // suppress_broadcast
            XCTAssertEqual((report["other_sent"] as? [Any])?.count, 0)
            XCTAssertTrue((report["lookups"] as? [[Any]])?.allSatisfy { ($0.first as? String) == "s1" && ($0.last as? Bool) == false } == true)
        } catch { await client.disconnect(); throw error }
    }

    func testPythonTargetErrorsReachSwiftWithoutRetargeting() async throws {
        for (mode, code) in [("changed", BridgeErrorCode.targetChanged), ("gone", .targetGone)] {
            let fixture = try PythonBridgeFixture(mode: mode)
            let client = UnixBridgeClient(testingSocket: fixture.client)
            do {
                _ = try await client.request(.init(operation: .insertText, target: target, text: "reviewed"))
                XCTFail("Expected refusal")
            } catch let failure as BridgeFailure { XCTAssertEqual(failure.code, code) }
            catch { await client.disconnect(); throw error }
            await client.disconnect()
            let report = try await fixture.report()
            XCTAssertEqual((report["sent"] as? [Any])?.count, 0)
            XCTAssertEqual((report["other_sent"] as? [Any])?.count, 0)
        }
    }

    func testPythonClosesOversizedFrameWithoutDispatch() async throws {
        let fixture = try PythonBridgeFixture()
        defer { close(fixture.client) }
        let bytes: [UInt8] = [0, 1, 0, 1] // 65537, above the shared limit.
        XCTAssertEqual(bytes.withUnsafeBytes { send(fixture.client, $0.baseAddress, 4, 0) }, 4)
        var item = pollfd(fd: fixture.client, events: Int16(POLLIN), revents: 0)
        XCTAssertGreaterThan(poll(&item, 1, 3000), 0)
        var byte: UInt8 = 0
        XCTAssertEqual(recv(fixture.client, &byte, 1, MSG_DONTWAIT), 0)
        _ = shutdown(fixture.client, SHUT_RDWR)
        let report = try await fixture.report()
        XCTAssertEqual((report["sent"] as? [Any])?.count, 0)
    }
}
