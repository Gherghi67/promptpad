import Foundation

public enum BridgeOperation: String, Codable, Sendable {
    case ping
    case captureTarget = "capture_target"
    case insertText = "insert_text"
    case control
    case selectTab = "select_tab"
    case selectPane = "select_pane"
    case authorizeKey = "authorize_key"
    case readScrollback = "read_scrollback"
}

public enum BridgeErrorCode: String, Codable, Sendable {
    case invalidRequest = "invalid_request", unsupportedVersion = "unsupported_version"
    case tooLarge = "too_large", timeout, disconnected, unavailable, busy
    case notFocused = "not_focused", targetGone = "target_gone", targetChanged = "target_changed"
    case broadcastActive = "broadcast_active", permissionDenied = "permission_denied"
    case staleGeneration = "stale_generation", outcomeUnknown = "outcome_unknown", internalError = "internal_error"
}

public struct BridgeFailure: Error, Codable, Equatable, Sendable, LocalizedError {
    public let code: BridgeErrorCode
    public let message: String
    public var errorDescription: String? { message }
    public init(_ code: BridgeErrorCode, _ message: String) { self.code = code; self.message = message }
}

public struct BridgeRequest: Codable, Equatable, Sendable {
    public var version: Int
    public var id: String
    public var operation: BridgeOperation
    public var target: TerminalTarget?
    public var text: String?
    public var control: TerminalControl?
    public var direction: Direction?
    public var tabDirection: TabDirection?
    public var firstLine: Int?
    public var lineCount: Int?

    enum CodingKeys: String, CodingKey {
        case version, id, operation, target, text, control, direction
        case tabDirection = "tab_direction", firstLine = "first_line", lineCount = "line_count"
    }

    public init(operation: BridgeOperation, target: TerminalTarget? = nil, text: String? = nil,
                control: TerminalControl? = nil, direction: Direction? = nil,
                tabDirection: TabDirection? = nil, firstLine: Int? = nil, lineCount: Int? = nil,
                id: String = UUID().uuidString) {
        self.version = BridgeProtocol.version; self.id = id; self.operation = operation; self.target = target
        self.text = text; self.control = control; self.direction = direction; self.tabDirection = tabDirection
        self.firstLine = firstLine; self.lineCount = lineCount
    }

    public func validate() throws {
        guard version == BridgeProtocol.version else { throw BridgeFailure(.unsupportedVersion, "Expected protocol version 1.") }
        guard UUID(uuidString: id) != nil, id.utf8.count == 36 else { throw BridgeFailure(.invalidRequest, "Request id must be a UUID.") }
        let requiresTarget = operation != .ping && operation != .captureTarget
        guard requiresTarget ? target?.isValid == true : target == nil else {
            throw BridgeFailure(.invalidRequest, "Operation has an absent or unexpected target.")
        }
        guard (operation == .insertText) == (text != nil),
              (operation == .control) == (control != nil),
              (operation == .selectPane || operation == .authorizeKey) == (direction != nil),
              (operation == .selectTab) == (tabDirection != nil),
              (operation == .readScrollback) == (lineCount != nil),
              operation == .readScrollback || firstLine == nil else {
            throw BridgeFailure(.invalidRequest, "Operation fields do not match its schema.")
        }
        if let text {
            let safe = try TranscriptSanitizer.validated(text)
            guard safe == text else { throw BridgeFailure(.invalidRequest, "insert_text requires already sanitized text.") }
        }
        if let lineCount, !(1...BridgeProtocol.maxScrollbackLines).contains(lineCount) {
            throw BridgeFailure(.invalidRequest, "line_count must be 1...128.")
        }
        if let firstLine, !(0...BridgeProtocol.maxLineNumber).contains(firstLine) {
            throw BridgeFailure(.invalidRequest, "first_line is out of bounds.")
        }
    }
}

public struct BridgeResponse: Codable, Equatable, Sendable {
    public var version: Int
    public var id: String
    public var ok: Bool
    public var target: TerminalTarget?
    public var page: ScrollbackPage?
    public var error: BridgeFailure?

    public init(id: String, ok: Bool = true, target: TerminalTarget? = nil,
                page: ScrollbackPage? = nil, error: BridgeFailure? = nil) {
        self.version = BridgeProtocol.version; self.id = id; self.ok = ok
        self.target = target; self.page = page; self.error = error
    }

    /// Validate before consuming any response, including a native-key authorization.
    public func validate(for request: BridgeRequest) throws {
        guard version == BridgeProtocol.version, id == request.id,
              ok ? error == nil : error != nil else {
            throw BridgeFailure(.invalidRequest, "Mismatched or malformed bridge response.")
        }
        if let error {
            guard error.message.utf8.count <= 1024, target == nil, page == nil else {
                throw BridgeFailure(.invalidRequest, "Malformed error response.")
            }
            throw error
        }
        if request.operation == .ping {
            guard target == nil, page == nil else { throw BridgeFailure(.invalidRequest, "Unexpected ping payload.") }
            return
        }
        guard let target, target.isValid else { throw BridgeFailure(.invalidRequest, "Missing response target.") }
        if let expected = request.target,
           target.sessionID != expected.sessionID || target.tabID != expected.tabID || target.windowID != expected.windowID {
            throw BridgeFailure(.targetChanged, "Bridge returned a different target.")
        }
        if request.operation == .readScrollback {
            guard let page, page.target == target, page.oldestLine >= 0,
                  page.newestLine <= BridgeProtocol.maxLineNumber, page.newestLine >= page.oldestLine,
                  page.firstLine >= page.oldestLine, page.firstLine <= page.newestLine,
                  page.lines.count <= (request.lineCount ?? 0),
                  page.lines.count <= page.newestLine - page.firstLine,
                  page.lines.allSatisfy({ $0.utf8.count <= BridgeProtocol.maxScrollbackLineBytes }) else {
                throw BridgeFailure(.invalidRequest, "Invalid scrollback page.")
            }
        } else if page != nil { throw BridgeFailure(.invalidRequest, "Unexpected scrollback payload.") }
    }
}

public enum BridgeProtocol {
    public static let version = 1
    public static let maxFrameBytes = 65_536
    public static let maxScrollbackLines = 128
    public static let maxScrollbackLineBytes = 2048
    public static let scrollbackByteBudget = 48_000
    public static let maxLineNumber = 9_007_199_254_740_991 // JSON's exact integer limit
    public static let connectTimeout: TimeInterval = 1
    public static let frameTimeout: TimeInterval = 2
    public static let operationTimeout: TimeInterval = 2
    public static let requestTimeout: TimeInterval = 3
    public static let reconnectDelays: [TimeInterval] = [0.25, 0.5, 1, 2, 4, 5]

    /// Both processes use getuid(), not a username or a per-process temporary directory.
    public static func socketDirectory(userID: UInt32) -> String { "/tmp/gamepad-terminal-\(userID)" }
    public static func socketPath(userID: UInt32) -> String { socketDirectory(userID: userID) + "/bridge.sock" }

    public static func encode<T: Encodable>(_ message: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(message)
        guard !payload.isEmpty, payload.count <= maxFrameBytes else { throw BridgeFailure(.tooLarge, "Frame exceeds 65536 bytes.") }
        let size = UInt32(payload.count)
        var frame = Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        frame.append(payload)
        return frame
    }
}

/// Incremental 4-byte unsigned big-endian length + UTF-8 JSON framing. Decode returned
/// payloads separately with JSONDecoder and validate(). A decoder error closes the socket.
public struct BridgeFrameDecoder: Sendable {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ bytes: Data) throws -> [Data] {
        guard bytes.count <= BridgeProtocol.maxFrameBytes + 4 else { throw BridgeFailure(.tooLarge, "Read chunk too large.") }
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let count = buffer[start..<start + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard count > 0, count <= BridgeProtocol.maxFrameBytes else {
                buffer.removeAll()
                throw BridgeFailure(.tooLarge, "Frame length must be 1...65536.")
            }
            let end = start + 4 + Int(count)
            guard buffer.endIndex >= end else { break }
            frames.append(Data(buffer[start + 4..<end]))
            buffer.removeSubrange(start..<end)
        }
        return frames
    }

    public mutating func finish() throws {
        defer { buffer.removeAll() }
        guard buffer.isEmpty else { throw BridgeFailure(.disconnected, "Truncated bridge frame.") }
    }
}
