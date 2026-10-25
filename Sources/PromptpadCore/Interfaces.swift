import Foundation

public struct TerminalTarget: Codable, Equatable, Sendable {
    public let sessionID: String
    public let windowID: String
    public let tabID: String
    public let title: String
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", windowID = "window_id", tabID = "tab_id", title
    }

    public init(sessionID: String, windowID: String, tabID: String, title: String) {
        self.sessionID = sessionID; self.windowID = windowID; self.tabID = tabID; self.title = title
    }

    public var isValid: Bool {
        [sessionID, windowID, tabID].allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        } && title.utf8.count <= 1024
    }
}

public enum Direction: String, Codable, Sendable { case left, right, up, down }
public enum TabDirection: String, Codable, Sendable { case previous, next }
public enum TerminalControl: String, Codable, Sendable { case enter, escape, tab, interrupt }

/// Text and control actions intentionally have separate types and wire operations.
public enum TerminalAction: Equatable, Sendable {
    case control(TerminalControl)
    case arrow(Direction)
    case selectPane(Direction)
    case selectTab(TabDirection)
    /// Positive means older history, negative means newer. Opens a read-only overlay.
    case scrollback(deltaLines: Int)
}

public struct ScrollbackPage: Codable, Equatable, Sendable {
    public let target: TerminalTarget
    public let firstLine: Int
    public let oldestLine: Int
    public let newestLine: Int // exclusive
    public let lines: [String]
    enum CodingKeys: String, CodingKey {
        case target, firstLine = "first_line", oldestLine = "oldest_line", newestLine = "newest_line", lines
    }

    public init(target: TerminalTarget, firstLine: Int, oldestLine: Int, newestLine: Int, lines: [String]) {
        self.target = target; self.firstLine = firstLine; self.oldestLine = oldestLine
        self.newestLine = newestLine; self.lines = lines
    }
}

public enum BridgeStatus: Equatable, Sendable { case disconnected, connecting, connected, failed(String) }

public enum VoicePolicy {
    public static let maximumRecordingSeconds: TimeInterval = 60
    public static let finalTranscriptionTimeout: TimeInterval = 15
}

public enum NativeKeyPolicy {
    /// Measured from the start of the bridge authorization request, not its reply.
    public static let authorizationLifetime: TimeInterval = 0.1
    public static let iTermBundleIdentifier = "com.googlecode.iterm2"
}

/// Implementations serialize requests; never retry a mutation after an ambiguous disconnect.
public protocol BridgeClient: Sendable {
    func request(_ request: BridgeRequest) async throws -> BridgeResponse
    func disconnect() async
}

public struct AudioInput: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// MainActor services must reject stale generations, including callbacks after cancellation.
/// Start returns only after capture starts. Stop finishes capture and returns final text.
@MainActor public protocol VoiceService: AnyObject {
    var inputs: [AudioInput] { get }
    var recognitionNotice: String { get } // accurately describe possible Apple server processing
    func requestAuthorization() async throws
    func startRecording(inputID: String?, generation: UInt64) async throws
    /// Close the audio gate synchronously on physical release, before queued IO.
    func stopCapture(generation: UInt64)
    func stopAndTranscribe(generation: UInt64) async throws -> String
    func cancel(generation: UInt64)
}

@MainActor public protocol ControllerEventSource: AnyObject {
    var onEvent: ((ControllerEvent) -> Void)? { get set }
    func start()
    func stop()
}

/// Only arrows use native injection. Implement with CGEvent keyboard down/up posted to
/// iTerm's PID, Accessibility authorization, immediate foreground + terminal-focus checks,
/// and a fresh bridge authorizeKey response. No raw string/escape-sequence endpoint.
@MainActor public protocol NativeKeyService: AnyObject {
    func sendArrow(_ direction: Direction, target: TerminalTarget) async throws
}

public enum TranscriptSanitizer {
    public static let maxUTF8Bytes = 8192

    /// Preserve printable Unicode, replace every whitespace run with a single space,
    /// and drop C0/C1 controls and Unicode format characters. Never emits CR/LF/TAB/ESC.
    public static func sanitize(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .format { continue }
            if isWhitespace(scalar.value) {
                pendingSpace = !output.isEmpty
                continue
            }
            if scalar.properties.generalCategory == .control { continue }
            if pendingSpace { output.append(" "); pendingSpace = false }
            output.append(scalar)
        }
        return String(output)
    }

    // Unicode White_Space, spelled out so Python and Foundation versions cannot differ.
    private static func isWhitespace(_ value: UInt32) -> Bool {
        switch value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
        default: false
        }
    }

    public static func validated(_ text: String) throws -> String {
        guard text.utf8.count <= maxUTF8Bytes else { throw BridgeFailure(.tooLarge, "Transcript exceeds 8192 UTF-8 bytes.") }
        let safe = sanitize(text)
        guard !safe.isEmpty else { throw BridgeFailure(.invalidRequest, "Transcript contains no printable text.") }
        return safe
    }
}
