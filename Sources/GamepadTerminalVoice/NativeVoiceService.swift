import Foundation
import GamepadTerminalCore

/// Produces review text only. There is no bridge client, terminal insertion, or key injection here.
/// The application must cancel the current generation immediately on gate loss. `pinnedTarget`
/// must return nil unless enabled, connected, frontmost, and the generation owns a captured target.
/// Check it from ApplicationState's startingRecording/recording/transcribing cases, never recapture
/// the current terminal here. A hold that has not captured its target cannot acquire the microphone.
@MainActor public final class NativeVoiceService: VoiceService {
    public let recognitionNotice = "Apple Speech recognition may send audio to Apple servers, depending on your language and device. Offline processing is not guaranteed. Review the transcript before inserting it."
    public var inputs: [AudioInput] { capture.inputs }
    public var permissions: VoicePermissions { .init(microphone: capture.permission, speech: recognition.permission) }
    public var availability: VoiceAvailability {
        if [capture.permission, recognition.permission].contains(where: { $0 == .denied || $0 == .restricted }) { return .permissionDenied }
        if capture.permission != .authorized || recognition.permission != .authorized { return .permissionRequired }
        if inputs.isEmpty { return .noAudioInputs }
        return recognition.isAvailable ? .available : .recognitionUnavailable
    }
    public private(set) var state: NativeVoiceState = .idle {
        didSet { onStateChange?(state) }
    }
    /// Deliver failure states to ApplicationEvent.failed with the original generation; do not relabel
    /// an asynchronous event with the application's current generation.
    public var onStateChange: (@MainActor (NativeVoiceState) -> Void)?
    public var onFailure: (@MainActor (UInt64, VoiceFailure) -> Void)?

    private let capture: any VoiceCaptureBackend
    private let recognition: any VoiceRecognitionBackend
    private let deadlines: any VoiceDeadlineScheduler
    private let pinnedTarget: @MainActor (UInt64) -> TerminalTarget?
    private var latestGeneration: UInt64?
    private var active: Recording?

    private final class Recording {
        let generation: UInt64
        let target: TerminalTarget
        var capture: (any VoiceCaptureSession)?
        var recognition: (any VoiceRecognitionSession)?
        var deadline: (any VoiceDeadline)?
        var result: Result<String, VoiceFailure>?
        var waiter: CheckedContinuation<String, Error>?
        var released = false
        init(generation: UInt64, target: TerminalTarget) { self.generation = generation; self.target = target }
    }

    public convenience init(locale: Locale = .current,
                            pinnedTarget: @escaping @MainActor (UInt64) -> TerminalTarget?) {
        self.init(capture: AppleVoiceCaptureBackend(), recognition: AppleVoiceRecognitionBackend(locale: locale),
                  deadlines: SystemVoiceDeadlineScheduler(), pinnedTarget: pinnedTarget)
    }

    public init(capture: any VoiceCaptureBackend, recognition: any VoiceRecognitionBackend,
                deadlines: any VoiceDeadlineScheduler = SystemVoiceDeadlineScheduler(),
                pinnedTarget: @escaping @MainActor (UInt64) -> TerminalTarget?) {
        self.capture = capture; self.recognition = recognition
        self.deadlines = deadlines; self.pinnedTarget = pinnedTarget
    }

    /// Only call from explicit setup UI. startRecording never requests interactive permissions.
    public func requestAuthorization() async throws {
        try await capture.requestAuthorization()
        try await recognition.requestAuthorization()
        try checkPermissions()
    }

    public func startRecording(inputID: String?, generation: UInt64) async throws {
        try Task.checkCancellation()
        guard latestGeneration.map({ generation > $0 }) ?? true else { throw stale() }
        guard active == nil else { throw VoiceFailure(.busy, "Finish or cancel the current dictation first.") }
        latestGeneration = generation
        guard let target = pinnedTarget(generation), target.isValid else {
            throw report(.init(.targetInvalidated, "Capture a valid focused terminal target before recording."), generation: generation)
        }
        do {
            try checkPermissions()
            guard recognition.isAvailable else {
                throw VoiceFailure(.recognitionUnavailable, "Apple Speech is unavailable for this language or device. Check your connection and try again.")
            }
            guard !inputs.isEmpty, inputID == nil || inputs.contains(where: { $0.id == inputID }) else {
                throw VoiceFailure(.inputUnavailable, "The selected microphone is unavailable. Connect it or choose another macOS audio input; a DualSense microphone may not be exposed by macOS.")
            }
        } catch let failure as VoiceFailure { throw report(failure, generation: generation) }
        let run = Recording(generation: generation, target: target)
        active = run
        state = .starting(generation: generation, inputID: inputID)
        guard active === run else { throw stale() }
        do {
            run.recognition = try recognition.makeSession { [weak self, weak run] event in
                guard let self, let run else { return }
                self.receive(event, for: run)
            }
            guard let recognitionSession = run.recognition else { throw stale() }
            run.capture = try capture.makeSession(inputID: inputID, sink: recognitionSession.audioSink) { [weak self, weak run] failure in
                guard let self, let run else { return }
                self.complete(run, with: .failure(failure))
            }
            try await withTaskCancellationHandler {
                try await run.capture?.start()
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel(generation: generation) }
            }
            guard active === run else { run.capture?.stop(); run.recognition?.cancel(); throw stale() }
            if Task.isCancelled { cancel(generation: generation); throw CancellationError() }
            guard targetIsValid(run) else {
                throw VoiceFailure(.targetInvalidated, "The pinned terminal lost focus or changed. Start dictation again in the intended terminal.")
            }
            if let result = run.result {
                if case let .failure(failure) = result { throw failure }
                return // an early final result already stopped capture; await physical release
            }
            run.deadline = deadlines.schedule(after: VoicePolicy.maximumRecordingSeconds) { [weak self, weak run] in
                guard let self, let run else { return }
                self.complete(run, with: .failure(.init(.recordingLimit, "Recording stopped at 60 seconds. Release the trigger and start a shorter dictation.")))
            }
            state = .recording(generation: generation, inputID: inputID)
        } catch {
            run.capture?.stop(); run.recognition?.cancel(); run.deadline?.cancel()
            if active === run {
                active = nil
                let failure = (error as? VoiceFailure) ?? .init(.captureFailed, "Could not start audio capture. Check the selected microphone and try again.")
                throw report(failure, generation: generation)
            }
            throw error
        }
    }

    public func stopCapture(generation: UInt64) {
        guard let run = active, run.generation == generation else { return }
        run.capture?.stop()
    }

    public func stopAndTranscribe(generation: UInt64) async throws -> String {
        guard let run = active, run.generation == generation else { throw stale() }
        guard !run.released else { throw VoiceFailure(.busy, "Transcription is already in progress.") }
        if Task.isCancelled { cancel(generation: generation); throw CancellationError() }
        guard targetIsValid(run) else {
            cancel(generation: generation)
            throw report(.init(.targetInvalidated, "The pinned terminal lost focus or changed. This dictation was discarded."), generation: generation)
        }
        run.released = true
        run.deadline?.cancel(); run.deadline = nil
        run.capture?.stop()
        if run.result == nil {
            state = .transcribing(generation: generation)
            run.recognition?.finishAudio()
        }
        let text: String
        do {
            text = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if let result = run.result { continuation.resume(with: result.mapError { $0 as Error }); return }
                    run.waiter = continuation
                    run.deadline = deadlines.schedule(after: VoicePolicy.finalTranscriptionTimeout) { [weak self, weak run] in
                        guard let self, let run else { return }
                        self.complete(run, with: .failure(.init(.transcriptionTimeout, "Apple Speech did not finish within 15 seconds. Check your connection and try again.")))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel(generation: generation) }
            }
        } catch {
            if active === run { active = nil }
            throw error
        }
        guard active === run, !Task.isCancelled, targetIsValid(run) else {
            if active === run { cancel(generation: generation) }
            throw stale()
        }
        active = nil
        state = .review(generation: generation, text: text)
        return text
    }

    public func cancel(generation: UInt64) {
        if latestGeneration.map({ generation > $0 }) ?? true { latestGeneration = generation }
        guard let run = active, run.generation == generation else {
            if case let .review(reviewGeneration, _) = state, reviewGeneration == generation { state = .idle }
            return
        }
        active = nil // invalidate callbacks before shutting down either backend
        run.deadline?.cancel(); run.capture?.stop(); run.recognition?.cancel()
        let waiter = run.waiter; run.waiter = nil
        waiter?.resume(throwing: VoiceFailure(.cancelled, "Dictation was cancelled."))
        state = .idle
    }

    private func receive(_ event: VoiceRecognitionEvent, for run: Recording) {
        guard active === run, run.result == nil else { return }
        guard targetIsValid(run) else {
            complete(run, with: .failure(.init(.targetInvalidated, "The pinned terminal lost focus or changed. This dictation was discarded.")))
            return
        }
        switch event {
        case let .failure(failure): complete(run, with: .failure(failure))
        case let .final(text):
            do { complete(run, with: .success(try TranscriptSanitizer.validated(text))) }
            catch { complete(run, with: .failure(.init(.noSpeech, "No usable transcript was received, or it exceeded 8192 bytes. Try a shorter dictation."))) }
        }
    }

    private func complete(_ run: Recording, with result: Result<String, VoiceFailure>) {
        guard active === run, run.result == nil else { return }
        run.result = result
        run.deadline?.cancel(); run.deadline = nil
        run.capture?.stop(); run.recognition?.cancel()
        switch result {
        case .success: if !run.released { state = .awaitingRelease(generation: run.generation) }
        case let .failure(failure): _ = report(failure, generation: run.generation)
        }
        let waiter = run.waiter; run.waiter = nil
        waiter?.resume(with: result.mapError { $0 as Error })
    }

    private func targetIsValid(_ run: Recording) -> Bool {
        guard let current = pinnedTarget(run.generation), current.isValid else { return false }
        return current.sessionID == run.target.sessionID && current.windowID == run.target.windowID && current.tabID == run.target.tabID
    }

    private func checkPermissions() throws {
        if [capture.permission, recognition.permission].contains(where: { $0 == .denied || $0 == .restricted }) {
            throw VoiceFailure(.permissionDenied, "Allow Microphone and Speech Recognition access for this app in System Settings > Privacy & Security, then try again.")
        }
        guard capture.permission == .authorized, recognition.permission == .authorized else {
            throw VoiceFailure(.permissionRequired, "Use the app's explicit voice setup to allow Microphone and Speech Recognition access before dictating.")
        }
    }

    @discardableResult private func report(_ failure: VoiceFailure, generation: UInt64) -> VoiceFailure {
        state = .failed(failure); onFailure?(generation, failure); return failure
    }
    private func stale() -> VoiceFailure { .init(.staleGeneration, "This dictation is no longer active. Start a new hold in the intended terminal.") }
}
