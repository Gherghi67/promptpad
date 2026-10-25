import CoreMedia
import Foundation
import GamepadTerminalCore

public enum VoicePermission: Equatable, Sendable {
    case notDetermined, authorized, denied, restricted
}

public struct VoicePermissions: Equatable, Sendable {
    public let microphone: VoicePermission
    public let speech: VoicePermission
}

public enum VoiceAvailability: Equatable, Sendable {
    case available, permissionRequired, permissionDenied, noAudioInputs, recognitionUnavailable
}

public struct VoiceFailure: Error, Equatable, Sendable, LocalizedError {
    public enum Code: Equatable, Sendable {
        case permissionRequired, permissionDenied, configuration, inputUnavailable
        case recognitionUnavailable, captureFailed, recognitionFailed, noSpeech
        case recordingLimit, transcriptionTimeout, targetInvalidated, staleGeneration, busy, cancelled
    }
    public let code: Code
    public let message: String
    public var errorDescription: String? { message }
    public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
}

public enum NativeVoiceState: Equatable, Sendable {
    case idle
    case starting(generation: UInt64, inputID: String?)
    case recording(generation: UInt64, inputID: String?)
    /// Apple can finalize early; the microphone is already stopped, but release is still required.
    case awaitingRelease(generation: UInt64)
    case transcribing(generation: UInt64)
    case review(generation: UInt64, text: String)
    case failed(VoiceFailure)
}

public enum VoiceRecognitionEvent: Sendable {
    case final(String)
    case failure(VoiceFailure)
}

/// The native implementation serializes append/end/cancel; buffers never cross onto the UI actor.
public protocol VoiceAudioSink: Sendable {
    func append(_ buffer: CMSampleBuffer)
}

@MainActor public protocol VoiceCaptureSession: AnyObject {
    func start() async throws
    func stop()
}

@MainActor public protocol VoiceCaptureBackend: AnyObject {
    var inputs: [AudioInput] { get }
    var permission: VoicePermission { get }
    func requestAuthorization() async throws
    /// A non-nil ID must be honored exactly or rejected, including on device removal.
    func makeSession(inputID: String?, sink: any VoiceAudioSink,
                     onFailure: @escaping @MainActor @Sendable (VoiceFailure) -> Void) throws -> any VoiceCaptureSession
}

@MainActor public protocol VoiceRecognitionSession: AnyObject {
    var audioSink: any VoiceAudioSink { get }
    func finishAudio()
    func cancel()
}

@MainActor public protocol VoiceRecognitionBackend: AnyObject {
    var permission: VoicePermission { get }
    var isAvailable: Bool { get }
    func requestAuthorization() async throws
    func makeSession(onEvent: @escaping @MainActor @Sendable (VoiceRecognitionEvent) -> Void) throws -> any VoiceRecognitionSession
}

@MainActor public protocol VoiceDeadline: AnyObject { func cancel() }

@MainActor public protocol VoiceDeadlineScheduler: AnyObject {
    func schedule(after seconds: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) -> any VoiceDeadline
}

@MainActor final class TaskVoiceDeadline: VoiceDeadline {
    private var task: Task<Void, Never>?
    init(seconds: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
        task = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
    }
    func cancel() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}

@MainActor public final class SystemVoiceDeadlineScheduler: VoiceDeadlineScheduler {
    public init() {}
    public func schedule(after seconds: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) -> any VoiceDeadline {
        TaskVoiceDeadline(seconds: seconds, action: action)
    }
}
