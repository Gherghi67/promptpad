import XCTest
@testable import GamepadTerminalCore

final class ProtocolTests: XCTestCase {
    let target = TerminalTarget(sessionID: "s1", windowID: "w1", tabID: "t1", title: "shell")

    func testWireRoundTripAndFragmentation() throws {
        let request = BridgeRequest(operation: .insertText, target: target, text: "café 🙂")
        try request.validate()
        let frame = try BridgeProtocol.encode(request)
        var decoder = BridgeFrameDecoder()
        var payloads: [Data] = []
        for byte in frame { payloads += try decoder.append(Data([byte])) }
        try decoder.finish()
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(BridgeRequest.self, from: payloads[0]), request)
        let json = try XCTUnwrap(String(data: payloads[0], encoding: .utf8))
        XCTAssertTrue(json.contains("\"session_id\":\"s1\""))
        XCTAssertTrue(json.contains("\"operation\":\"insert_text\""))
    }

    func testCoalescedFrames() throws {
        let request = BridgeRequest(operation: .ping)
        var bytes = try BridgeProtocol.encode(request)
        bytes.append(try BridgeProtocol.encode(request))
        var decoder = BridgeFrameDecoder()
        XCTAssertEqual(try decoder.append(bytes).count, 2)
        try decoder.finish()
    }

    func testOversizedZeroAndTruncatedFrames() throws {
        for bytes: Data in [Data([0, 1, 0, 1]), Data([0, 0, 0, 0])] {
            var decoder = BridgeFrameDecoder()
            XCTAssertThrowsError(try decoder.append(bytes))
        }
        var decoder = BridgeFrameDecoder()
        _ = try decoder.append(Data([0, 0, 0, 3, 123]))
        XCTAssertThrowsError(try decoder.finish())
        XCTAssertThrowsError(try BridgeProtocol.encode(String(repeating: "x", count: 65_536)))
        XCTAssertThrowsError(try JSONDecoder().decode(BridgeRequest.self, from: Data("not JSON".utf8)))
    }

    func testSchemaRejectsUnsafeInsertionButAcceptsDeliberateControl() throws {
        XCTAssertThrowsError(try BridgeRequest(operation: .insertText, target: target, text: "ls\n").validate())
        XCTAssertNoThrow(try BridgeRequest(operation: .control, target: target, control: .enter).validate())
        XCTAssertNoThrow(try BridgeRequest(operation: .control, target: target, control: .interrupt).validate())
        XCTAssertThrowsError(try BridgeRequest(operation: .control, target: target, text: "\r", control: .enter).validate())
        XCTAssertThrowsError(try BridgeRequest(operation: .insertText, text: "safe").validate())
        XCTAssertThrowsError(try BridgeRequest(operation: .captureTarget, target: target).validate())
        XCTAssertThrowsError(try BridgeRequest(operation: .readScrollback, target: target, lineCount: 129).validate())
        XCTAssertThrowsError(try BridgeRequest(operation: .authorizeKey, target: target).validate())
        var request = BridgeRequest(operation: .ping); request.version = 2
        XCTAssertThrowsError(try request.validate())
    }

    func testResponseRejectsWrongIDTargetAndMalformedSuccess() throws {
        let request = BridgeRequest(operation: .insertText, target: target, text: "hello")
        XCTAssertNoThrow(try BridgeResponse(id: request.id, target: target).validate(for: request))
        XCTAssertThrowsError(try BridgeResponse(id: UUID().uuidString, target: target).validate(for: request))
        let other = TerminalTarget(sessionID: "other", windowID: "w1", tabID: "t1", title: "shell")
        XCTAssertThrowsError(try BridgeResponse(id: request.id, target: other).validate(for: request))
        XCTAssertThrowsError(try BridgeResponse(id: request.id).validate(for: request))
        XCTAssertThrowsError(try BridgeResponse(id: request.id, ok: false).validate(for: request))
        XCTAssertThrowsError(try BridgeResponse(id: request.id, ok: false, error: BridgeFailure(.targetGone, "Closed.")).validate(for: request)) { error in
            XCTAssertEqual((error as? BridgeFailure)?.code, .targetGone)
        }
    }

    func testScrollbackBoundsAndSocketLocation() throws {
        let request = BridgeRequest(operation: .readScrollback, target: target, lineCount: 20)
        let good = ScrollbackPage(target: target, firstLine: 10, oldestLine: 5, newestLine: 30, lines: ["real output"])
        XCTAssertNoThrow(try BridgeResponse(id: request.id, target: target, page: good).validate(for: request))
        let bad = ScrollbackPage(target: target, firstLine: 1, oldestLine: 5, newestLine: 30, lines: [])
        XCTAssertThrowsError(try BridgeResponse(id: request.id, target: target, page: bad).validate(for: request))
        XCTAssertEqual(BridgeProtocol.socketPath(userID: 501), "/tmp/gamepad-terminal-501/bridge.sock")
    }
}
