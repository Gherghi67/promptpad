import AppKit
import ApplicationServices
import Carbon.HIToolbox
import PromptpadCore

/// Pure policy shared by API gating and the stricter native-key preflight.
enum TerminalFocusPolicy {
    struct FocusedElement {
        let pid: pid_t
        let bundleIdentifier: String?
        let role: String?
        let description: String?
    }
    static func contentPID(_ focused: FocusedElement?) -> pid_t? {
        guard let focused, focused.pid > 0,
              focused.bundleIdentifier == NativeKeyPolicy.iTermBundleIdentifier,
              focused.role == kAXTextAreaRole,
              let label = focused.description,
              label == "shell" || label.localizedCaseInsensitiveContains("terminal") else { return nil }
        return focused.pid
    }
    static func apiPID(focused: FocusedElement?, frontmostPID: pid_t?, frontmostBundle: String?) -> pid_t? {
        // A known keyboard focus overrides the menu-bar/frontmost application.
        if let focused { return contentPID(focused) }
        // Ordinary terminal API actions do not require Accessibility permission.
        return frontmostBundle == NativeKeyPolicy.iTermBundleIdentifier ? frontmostPID : nil
    }
}

@MainActor enum TerminalFocus {
    /// Metadata only, captured at R2 press; never reads AXValue or terminal text.
    static var diagnostic: String {
        guard AXIsProcessTrusted() else { return "Accessibility not authorized" }
        guard let focused = focusedElement() else { return "Accessibility authorized; keyboard focus unavailable" }
        let owner = focused.bundleIdentifier ?? "unknown app"
        let content = TerminalFocusPolicy.contentPID(focused) != nil ? "terminal content recognized" : "not recognized as terminal content"
        return "Accessibility authorized; focused app: \(owner); \(focused.role ?? "unknown role"); \(content)"
    }
    static var frontmost: NSRunningApplication? {
        let app = NSWorkspace.shared.frontmostApplication
        guard let pid = TerminalFocusPolicy.apiPID(focused: focusedElement(),
            frontmostPID: app?.processIdentifier, frontmostBundle: app?.bundleIdentifier) else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    /// No AXValue is read. Reject editable search/settings fields and unknown focus.
    static func contentPID() -> pid_t? {
        TerminalFocusPolicy.contentPID(focusedElement())
    }
    private static func focusedElement() -> TerminalFocusPolicy.FocusedElement? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        // Focus checks also run during capture. An unresponsive AX provider must
        // not block the main actor for the system's multi-second default timeout.
        AXUIElementSetMessagingTimeout(system, 0.03)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        guard app.bundleIdentifier == NativeKeyPolicy.iTermBundleIdentifier else {
            return .init(pid: pid, bundleIdentifier: app.bundleIdentifier, role: nil, description: nil)
        }
        func string(_ name: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value as? String
        }
        let role = string(kAXRoleAttribute)
        // iTerm 3.7.6 PTYTextView exposes accessibilityLabel = "shell", which
        // AppKit maps to AXDescription (iTermTextViewAccessibilityHelper.m).
        return .init(pid: pid, bundleIdentifier: app.bundleIdentifier, role: role,
                     description: role == kAXTextAreaRole ? string(kAXDescriptionAttribute) : nil)
    }
}

@MainActor final class NativeKeys: NativeKeyService {
    private let bridge: any BridgeClient
    private let gateGeneration: @MainActor () -> UInt64?
    private let focusPID: @MainActor () -> pid_t?
    private let clock: @MainActor () -> TimeInterval
    private let post: @MainActor (Direction, pid_t) throws -> Void
    init(bridge: any BridgeClient,
         gateGeneration: @escaping @MainActor () -> UInt64?,
         focusPID: @escaping @MainActor () -> pid_t? = { TerminalFocus.contentPID() },
         clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         post: @escaping @MainActor (Direction, pid_t) throws -> Void = NativeKeys.postEvents) {
        self.bridge = bridge; self.gateGeneration = gateGeneration
        self.focusPID = focusPID; self.clock = clock; self.post = post
    }
    func sendArrow(_ direction: Direction, target: TerminalTarget) async throws {
        guard target.isValid, let generation = gateGeneration(), let pid = focusPID() else {
            throw BridgeFailure(.permissionDenied, "Arrows require Accessibility access and focused iTerm terminal content. Use Accessibility setup, then focus a terminal pane.")
        }
        let started = clock()
        let request = BridgeRequest(operation: .authorizeKey, target: target, direction: direction)
        let response = try await bridge.request(request)
        try response.validate(for: request)
        try Task.checkCancellation()
        guard gateGeneration() == generation, focusPID() == pid,
              clock() - started <= NativeKeyPolicy.authorizationLifetime else {
            throw BridgeFailure(.notFocused, "Arrow authorization expired or terminal focus changed. Press again in the intended pane.")
        }
        try post(direction, pid)
    }
    static func postEvents(_ direction: Direction, _ pid: pid_t) throws {
        let code: CGKeyCode = switch direction {
        case .left: CGKeyCode(kVK_LeftArrow)
        case .right: CGKeyCode(kVK_RightArrow)
        case .up: CGKeyCode(kVK_UpArrow)
        case .down: CGKeyCode(kVK_DownArrow)
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw BridgeFailure(.unavailable, "Could not create arrow key events.")
        }
        down.flags = []; up.flags = []
        down.postToPid(pid); up.postToPid(pid)
    }
}
