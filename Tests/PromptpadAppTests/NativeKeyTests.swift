import XCTest
import ApplicationServices
import PromptpadCore
@testable import PromptpadApp

private actor KeyBridge: BridgeClient {
    var onRequest: (@Sendable () async -> Void)?
    var refused = false
    func setCallback(_ callback: @escaping @Sendable () async -> Void) { onRequest = callback }
    func refuseBroadcast() { refused = true }
    func request(_ request: BridgeRequest) async throws -> BridgeResponse {
        await onRequest?()
        if refused { throw BridgeFailure(.broadcastActive, "Disable iTerm broadcast before using arrows.") }
        return .init(id: request.id, target: request.target)
    }
    func disconnect() async {}
}
@MainActor final class NativeKeyTests: XCTestCase {
    let target = TerminalTarget(sessionID: "s", windowID: "w", tabID: "t", title: "test")
    func testInstalledITermShellLabelAllowsHotkeyWithAnotherActiveApp() {
        // iTerm2 v3.7.6: iTermTextViewAccessibilityHelper.role = TextArea,
        // label = "shell"; PTYTextView forwards the label through AppKit.
        let terminal = TerminalFocusPolicy.FocusedElement(pid: 123,
            bundleIdentifier: NativeKeyPolicy.iTermBundleIdentifier, role: kAXTextAreaRole, description: "shell")
        XCTAssertEqual(TerminalFocusPolicy.contentPID(terminal), 123)
        XCTAssertEqual(TerminalFocusPolicy.apiPID(focused: terminal, frontmostPID: 456,
            frontmostBundle: "com.hnc.Discord"), 123)
        for bundle in ["com.hnc.Discord", NativeKeyPolicy.iTermBundleIdentifier] {
            let field = TerminalFocusPolicy.FocusedElement(pid: 456,
                bundleIdentifier: bundle, role: kAXTextFieldRole, description: "shell")
            XCTAssertNil(TerminalFocusPolicy.contentPID(field))
        }
        let otherApp = TerminalFocusPolicy.FocusedElement(pid: 456,
            bundleIdentifier: "other", role: kAXTextAreaRole, description: "shell")
        XCTAssertNil(TerminalFocusPolicy.contentPID(otherApp))
    }
    func testFocusPolicyAllowsNormalAndNonactivatingHotkeyTerminals() {
        let terminal = TerminalFocusPolicy.FocusedElement(pid: 123,
            bundleIdentifier: NativeKeyPolicy.iTermBundleIdentifier, role: kAXTextAreaRole, description: "Terminal")
        XCTAssertEqual(TerminalFocusPolicy.contentPID(terminal), 123)
        for bundle in [NativeKeyPolicy.iTermBundleIdentifier, "com.apple.finder"] {
            XCTAssertEqual(TerminalFocusPolicy.apiPID(focused: terminal, frontmostPID: 456, frontmostBundle: bundle), 123)
        }
    }
    func testFocusPolicyRejectsOtherAppsPanelsAndUnknownContentForArrows() {
        let candidates: [TerminalFocusPolicy.FocusedElement?] = [nil,
            .init(pid: 123, bundleIdentifier: "other", role: kAXTextAreaRole, description: "Terminal"),
            .init(pid: 123, bundleIdentifier: NativeKeyPolicy.iTermBundleIdentifier, role: kAXTextFieldRole, description: "Terminal"),
            .init(pid: 123, bundleIdentifier: NativeKeyPolicy.iTermBundleIdentifier, role: kAXTextAreaRole, description: "Search"),
            .init(pid: 123, bundleIdentifier: NativeKeyPolicy.iTermBundleIdentifier, role: nil, description: nil)]
        for candidate in candidates {
            XCTAssertNil(TerminalFocusPolicy.contentPID(candidate))
            XCTAssertNil(TerminalFocusPolicy.apiPID(focused: candidate, frontmostPID: 456, frontmostBundle: "other"))
            if candidate != nil {
                XCTAssertNil(TerminalFocusPolicy.apiPID(focused: candidate, frontmostPID: 456,
                    frontmostBundle: NativeKeyPolicy.iTermBundleIdentifier))
            }
        }
    }
    func testFocusPolicyKeepsNormalAPIWithoutAccessibilityButNeverArrows() {
        // A missing snapshot also represents denied AX permission or unknown system focus.
        XCTAssertEqual(TerminalFocusPolicy.apiPID(focused: nil, frontmostPID: 123,
            frontmostBundle: NativeKeyPolicy.iTermBundleIdentifier), 123)
        XCTAssertNil(TerminalFocusPolicy.contentPID(nil))
        XCTAssertNil(TerminalFocusPolicy.apiPID(focused: nil, frontmostPID: nil, frontmostBundle: nil))
    }
    func testDisabledDuringAuthorizationNeverPostsKey() async throws {
        let bridge = KeyBridge()
        var generation: UInt64? = 1
        var posts = 0
        await bridge.setCallback { @MainActor in generation = nil }
        let keys = NativeKeys(bridge: bridge, gateGeneration: { generation }, focusPID: { 123 }, post: { _, _ in posts += 1 })
        do { try await keys.sendArrow(.up, target: target); XCTFail("Expected gate rejection") } catch { }
        XCTAssertEqual(posts, 0)
    }
    func testExpiredAuthorizationNeverPostsKey() async throws {
        let bridge = KeyBridge()
        var time: TimeInterval = 0
        var posts = 0
        await bridge.setCallback { @MainActor in time = 0.101 }
        let keys = NativeKeys(bridge: bridge, gateGeneration: { 1 }, focusPID: { 123 }, clock: { time }, post: { _, _ in posts += 1 })
        do { try await keys.sendArrow(.up, target: target); XCTFail("Expected expired authorization") } catch { }
        XCTAssertEqual(posts, 0)
    }
    func testFreshAuthorizationPostsOnlyOnePairAndRejectsBroadcast() async throws {
        let bridge = KeyBridge()
        var posted: [Direction] = []
        let keys = NativeKeys(bridge: bridge, gateGeneration: { 1 }, focusPID: { 123 }, post: { direction, _ in posted.append(direction) })
        try await keys.sendArrow(.left, target: target)
        XCTAssertEqual(posted, [.left])
        await bridge.refuseBroadcast()
        do { try await keys.sendArrow(.right, target: target); XCTFail("Expected broadcast refusal") } catch { }
        XCTAssertEqual(posted, [.left])
    }
    func testUnknownNativeFocusFailsClosed() async throws {
        let keys = NativeKeys(bridge: KeyBridge(), gateGeneration: { 1 }, focusPID: { nil }, post: { _, _ in XCTFail("Must not post") })
        do { try await keys.sendArrow(.up, target: target); XCTFail("Expected focus rejection") } catch { }
    }
    func testSystemFocusChangesDuringAuthorizationNeverPostKey() async throws {
        for changedPID: pid_t? in [456, nil] {
            let bridge = KeyBridge()
            var pid: pid_t? = 123
            var posts = 0
            await bridge.setCallback { @MainActor in pid = changedPID }
            let keys = NativeKeys(bridge: bridge, gateGeneration: { 1 }, focusPID: { pid }, post: { _, _ in posts += 1 })
            do { try await keys.sendArrow(.up, target: target); XCTFail("Expected changed focus rejection") } catch { }
            XCTAssertEqual(posts, 0)
        }
    }
    func testSlowFinalFocusCheckExpiresAuthorization() async throws {
        var time: TimeInterval = 0
        var checks = 0
        var posts = 0
        let keys = NativeKeys(bridge: KeyBridge(), gateGeneration: { 1 }, focusPID: {
            checks += 1
            if checks == 2 { time = 0.101 }
            return 123
        }, clock: { time }, post: { _, _ in posts += 1 })
        do { try await keys.sendArrow(.up, target: target); XCTFail("Expected expiry after focus lookup") } catch { }
        XCTAssertEqual(posts, 0)
    }
}
