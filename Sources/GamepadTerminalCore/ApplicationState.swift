import Foundation

public enum DictationState: Equatable, Sendable {
    case idle
    case capturingTarget(generation: UInt64)
    case startingRecording(generation: UInt64, target: TerminalTarget)
    case recording(generation: UInt64, target: TerminalTarget)
    case transcribing(generation: UInt64, target: TerminalTarget)
    case review(generation: UInt64, target: TerminalTarget, text: String)
    case inserting(generation: UInt64, target: TerminalTarget, text: String)
    case inserted(generation: UInt64, target: TerminalTarget)
    case submitting(generation: UInt64, target: TerminalTarget)

    public var target: TerminalTarget? {
        switch self {
        case .idle, .capturingTarget: nil
        case let .startingRecording(_, target), let .recording(_, target), let .transcribing(_, target),
             let .review(_, target, _), let .inserting(_, target, _), let .inserted(_, target), let .submitting(_, target): target
        }
    }
}

public enum ApplicationEvent: Equatable, Sendable {
    case enabledChanged(Bool), controllerConnected(Bool), foregroundChanged(Bool), bridgeChanged(BridgeStatus)
    case intent(ControllerIntent)
    case targetCaptured(generation: UInt64, target: TerminalTarget)
    case recordingStarted(generation: UInt64)
    case transcriptReady(generation: UInt64, text: String)
    case insertionFinished(generation: UInt64)
    case submissionFinished(generation: UInt64)
    case failed(generation: UInt64, message: String)
    case dismissError
}

/// The app executes effects one at a time. Check generation + canUseTerminal immediately
/// before every side effect, and again after each await; feed completion events back here.
public enum ApplicationEffect: Equatable, Sendable {
    case captureTarget(generation: UInt64)
    case startRecording(generation: UInt64, target: TerminalTarget)
    case stopAndTranscribe(generation: UInt64)
    case cancelVoice(generation: UInt64)
    case insertTranscript(generation: UInt64, target: TerminalTarget, text: String)
    case submit(generation: UInt64, target: TerminalTarget)
    case terminal(generation: UInt64, action: TerminalAction)
    case showHelp
}

public struct ApplicationState: Equatable, Sendable {
    public private(set) var enabled = false
    public private(set) var controllerConnected = false
    public private(set) var iTermFrontmost = false
    public private(set) var bridgeStatus: BridgeStatus = .disconnected
    public private(set) var dictation: DictationState = .idle
    public private(set) var generation: UInt64 = 0
    public private(set) var scrollMode = false
    public private(set) var error: String?

    public init() {}
    /// An error requires explicit UI acknowledgment; a Cross intended to retry insertion
    /// must never become Enter after a response was lost and the outcome is unknown.
    public var canUseTerminal: Bool {
        enabled && controllerConnected && iTermFrontmost && bridgeStatus == .connected && error == nil
    }
    /// Keep the mapper live during voice work to receive R2 release and review buttons.
    /// The reducer blocks every irrelevant intent. Clear held repeats when this becomes false.
    public var acceptsOrdinaryActions: Bool { canUseTerminal && dictation == .idle }

    public mutating func handle(_ event: ApplicationEvent) -> [ApplicationEffect] {
        switch event {
        case let .enabledChanged(value):
            enabled = value
            return value ? [] : invalidate()
        case let .controllerConnected(value):
            controllerConnected = value
            return value ? [] : invalidate()
        case let .foregroundChanged(value):
            iTermFrontmost = value
            return value ? [] : invalidate()
        case let .bridgeChanged(value):
            bridgeStatus = value
            return value == .connected ? [] : invalidate()
        case .dismissError:
            error = nil; return []
        case let .failed(eventGeneration, message):
            guard eventGeneration == generation else { return [] }
            error = message
            return invalidate()
        case let .targetCaptured(eventGeneration, target):
            guard eventGeneration == generation, canUseTerminal,
                  case .capturingTarget(eventGeneration) = dictation else { return [] }
            guard target.isValid else {
                error = "The captured terminal target is invalid."
                return invalidate()
            }
            dictation = .startingRecording(generation: generation, target: target)
            return [.startRecording(generation: generation, target: target)]
        case let .recordingStarted(eventGeneration):
            guard eventGeneration == generation, canUseTerminal,
                  case let .startingRecording(_, target) = dictation else { return [] }
            dictation = .recording(generation: generation, target: target)
            return []
        case let .transcriptReady(eventGeneration, text):
            guard eventGeneration == generation, canUseTerminal,
                  case let .transcribing(_, target) = dictation else { return [] }
            do {
                let safe = try TranscriptSanitizer.validated(text)
                dictation = .review(generation: generation, target: target, text: safe)
                return []
            } catch {
                self.error = error.localizedDescription
                return invalidate()
            }
        case let .insertionFinished(eventGeneration):
            guard eventGeneration == generation, canUseTerminal,
                  case let .inserting(_, target, _) = dictation else { return [] }
            dictation = .inserted(generation: generation, target: target)
            return []
        case let .submissionFinished(eventGeneration):
            guard eventGeneration == generation, case .submitting = dictation else { return [] }
            dictation = .idle; advanceGeneration()
            return []
        case let .intent(intent):
            guard canUseTerminal else { return [] }
            return handleIntent(intent)
        }
    }

    private mutating func handleIntent(_ intent: ControllerIntent) -> [ApplicationEffect] {
        if scrollMode && (intent == .confirm || intent == .cancel || intent == .terminal(.control(.interrupt))) {
            scrollMode = false
            return [] // close viewer; never let its confirm/cancel reach the terminal
        }
        // Circle is always a local cancel during voice work, including L2+Circle.
        if dictation != .idle, intent == .cancel || intent == .terminal(.control(.interrupt)) {
            return invalidate()
        }
        switch intent {
        case .dictationPressed:
            guard dictation == .idle else { return [] }
            advanceGeneration(); error = nil; scrollMode = false
            dictation = .capturingTarget(generation: generation)
            return [.captureTarget(generation: generation)]
        case .dictationReleased:
            switch dictation {
            case .capturingTarget:
                // No recording began; abort rather than recording after the user let go.
                return invalidate()
            case .startingRecording: return invalidate()
            case let .recording(_, target):
                dictation = .transcribing(generation: generation, target: target)
                return [.stopAndTranscribe(generation: generation)]
            default: return []
            }
        case .confirm:
            switch dictation {
            case let .review(_, target, text):
                dictation = .inserting(generation: generation, target: target, text: text)
                return [.insertTranscript(generation: generation, target: target, text: text)]
            case let .inserted(_, target):
                dictation = .submitting(generation: generation, target: target)
                return [.submit(generation: generation, target: target)]
            case .idle: return [.terminal(generation: generation, action: .control(.enter))]
            default: return []
            }
        case .cancel:
            return [.terminal(generation: generation, action: .control(.escape))]
        case let .terminal(action):
            guard dictation == .idle else { return [] }
            return [.terminal(generation: generation, action: action)]
        case .showHelp:
            guard dictation == .idle else { return [] }
            return [.showHelp]
        case let .scrollModeChanged(value):
            guard dictation == .idle else { return [] }
            scrollMode = value
            return value ? [.terminal(generation: generation, action: .scrollback(deltaLines: 0))] : []
        }
    }

    private mutating func advanceGeneration() { generation &+= 1 }

    private mutating func invalidate() -> [ApplicationEffect] {
        let old = generation
        advanceGeneration(); dictation = .idle; scrollMode = false
        return [.cancelVoice(generation: old)]
    }
}
