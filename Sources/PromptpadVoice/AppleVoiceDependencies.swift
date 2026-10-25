@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import PromptpadCore
@preconcurrency import Speech

private func audioDevices() -> [AVCaptureDevice] {
    let types: [AVCaptureDevice.DeviceType]
    if #available(macOS 14, *) { types = [.microphone, .external] }
    else { types = [.builtInMicrophone, .externalUnknown] }
    return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices
}

@MainActor public final class AppleVoiceCaptureBackend: VoiceCaptureBackend {
    public init() {}
    // The ID is opaque: never infer microphone support from the controller's connection/name.
    public var inputs: [AudioInput] {
        audioDevices().filter(\.isConnected).map { AudioInput(id: $0.uniqueID, name: $0.localizedName) }
    }
    public var permission: VoicePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }
    public func requestAuthorization() async throws {
        guard permission == .notDetermined else { return }
        guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String, !usage.isEmpty else {
            throw VoiceFailure(.configuration, "Run the packaged app with NSMicrophoneUsageDescription configured before requesting microphone access.")
        }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }
    public func makeSession(inputID: String?, sink: any VoiceAudioSink,
                            onFailure: @escaping @MainActor @Sendable (VoiceFailure) -> Void) throws -> any VoiceCaptureSession {
        guard permission == .authorized else {
            throw VoiceFailure(.permissionRequired, "Allow microphone access in voice setup before recording.")
        }
        return AppleCaptureSession(worker: CaptureWorker(inputID: inputID, sink: sink, onFailure: onFailure))
    }
}

@MainActor private final class AppleCaptureSession: VoiceCaptureSession {
    private let worker: CaptureWorker
    init(worker: CaptureWorker) { self.worker = worker }
    func start() async throws { try await worker.start() }
    func stop() { worker.stop() }
    deinit { worker.stop() }
}

/// AVCaptureSession's configuration/start/stop and delegate delivery share one serial queue.
/// Only `stopped` crosses that queue, under `lock`. Stop closes the audio gate synchronously;
/// stopRunning runs off the UI actor, including when startRunning has not returned yet.
private final class CaptureWorker: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "PromptpadVoice.capture")
    private let lock = NSLock()
    private var stopped = false
    private let inputID: String?
    private let sink: any VoiceAudioSink
    private let onFailure: @MainActor @Sendable (VoiceFailure) -> Void
    // Queue-confined below.
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var observers: [NSObjectProtocol] = []

    init(inputID: String?, sink: any VoiceAudioSink, onFailure: @escaping @MainActor @Sendable (VoiceFailure) -> Void) {
        self.inputID = inputID; self.sink = sink; self.onFailure = onFailure
    }
    private var isStopped: Bool { lock.withLock { stopped } }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do { try configureAndStart(); continuation.resume() }
                catch { cleanup(); continuation.resume(throwing: error) }
            }
        }
    }
    func stop() {
        lock.withLock { stopped = true }
        queue.async { [self] in cleanup() }
    }
    private func configureAndStart() throws {
        guard !isStopped else { throw VoiceFailure(.cancelled, "Audio capture was cancelled before it started.") }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw VoiceFailure(.permissionDenied, "Microphone access is unavailable. Check System Settings > Privacy & Security > Microphone.")
        }
        let device: AVCaptureDevice?
        if let inputID {
            device = audioDevices().first { $0.uniqueID == inputID && $0.isConnected }
        } else {
            // Resolve the system default once. A later default-device change never retargets this run.
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device, device.isConnected else {
            throw VoiceFailure(.inputUnavailable, "The chosen macOS audio input was removed or is unavailable. Choose another input and start again.")
        }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) }
        catch { throw VoiceFailure(.captureFailed, "Could not open the selected microphone. Check that it is connected and available to this app.") }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw VoiceFailure(.captureFailed, "This audio input cannot supply speech audio. Choose another macOS microphone.")
        }
        self.session = session; self.output = output
        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: device, queue: nil) { [weak self] _ in
                self?.fail(.init(.inputUnavailable, "The selected microphone disconnected. Reconnect it or choose another input and start again."))
            },
            center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] _ in
                self?.fail(.init(.captureFailed, "Audio capture failed. Check microphone permissions and device availability, then start again."))
            },
            center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
                self?.fail(.init(.captureFailed, "Audio capture was interrupted. Release the trigger and start again when the microphone is available."))
            }
        ]
        guard !isStopped else { throw VoiceFailure(.cancelled, "Audio capture was cancelled.") }
        session.startRunning()
        guard !isStopped else { throw VoiceFailure(.cancelled, "Audio capture was cancelled during startup.") }
        guard session.isRunning, device.isConnected else {
            throw VoiceFailure(.captureFailed, "The microphone did not start. Check the selected input and try again.")
        }
    }
    private func fail(_ failure: VoiceFailure) {
        let first = lock.withLock {
            if stopped { return false }
            stopped = true
            return true
        }
        guard first else { return }
        queue.async { [self] in cleanup() }
        Task { @MainActor [onFailure] in onFailure(failure) }
    }
    private func cleanup() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        output?.setSampleBufferDelegate(nil, queue: nil)
        if let session, session.isRunning { session.stopRunning() }
        session = nil; output = nil
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // The lock makes stop's audio gate atomic with append. Recognition has its own end gate.
        lock.withLock { if !stopped { sink.append(sampleBuffer) } }
    }
}

@MainActor public final class AppleVoiceRecognitionBackend: VoiceRecognitionBackend {
    private let recognizer: SFSpeechRecognizer?
    public init(locale: Locale = .current) { recognizer = SFSpeechRecognizer(locale: locale) }
    public var permission: VoicePermission {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }
    public var isAvailable: Bool { recognizer?.isAvailable == true }
    public func requestAuthorization() async throws {
        guard permission == .notDetermined else { return }
        guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String, !usage.isEmpty else {
            throw VoiceFailure(.configuration, "Run the packaged app with NSSpeechRecognitionUsageDescription configured before requesting Apple Speech access.")
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
    }
    public func makeSession(onEvent: @escaping @MainActor @Sendable (VoiceRecognitionEvent) -> Void) throws -> any VoiceRecognitionSession {
        guard permission == .authorized, let recognizer, recognizer.isAvailable else {
            throw VoiceFailure(.recognitionUnavailable, "Apple Speech is unavailable. Check Speech Recognition permission, language support, and your connection.")
        }
        return AppleRecognitionSession(recognizer: recognizer, onEvent: onEvent)
    }
}

/// AVFoundation delivers buffers off-actor. Serialize every request mutation and close the gate
/// before endAudio/cancel so late capture buffers cannot enter a completed or cancelled request.
private final class SpeechAudioSink: VoiceAudioSink, @unchecked Sendable {
    let request = SFSpeechAudioBufferRecognitionRequest()
    private let lock = NSLock()
    private var accepting = true
    init() {
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        // Do not force on-device mode: Apple availability varies by locale, device, and OS.
    }
    func append(_ buffer: CMSampleBuffer) {
        lock.withLock { if accepting { request.appendAudioSampleBuffer(buffer) } }
    }
    func end() {
        lock.withLock {
            guard accepting else { return }
            accepting = false
            request.endAudio()
        }
    }
}

private final class SpeechTaskLifetime: @unchecked Sendable {
    // Initialized once, then only cancelled on the UI actor or on destruction.
    let task: SFSpeechRecognitionTask
    let sink: SpeechAudioSink
    init(task: SFSpeechRecognitionTask, sink: SpeechAudioSink) { self.task = task; self.sink = sink }
    func cancel() { sink.end(); task.cancel() }
    deinit { cancel() }
}

@MainActor private final class AppleRecognitionSession: VoiceRecognitionSession {
    private let lifetime: SpeechTaskLifetime
    var audioSink: any VoiceAudioSink { lifetime.sink }
    init(recognizer: SFSpeechRecognizer, onEvent: @escaping @MainActor @Sendable (VoiceRecognitionEvent) -> Void) {
        let sink = SpeechAudioSink()
        let task = recognizer.recognitionTask(with: sink.request) { result, error in
            let event: VoiceRecognitionEvent?
            if let result, result.isFinal {
                event = .final(result.bestTranscription.formattedString)
            } else if error != nil {
                // Avoid logging audio, dictated text, or arbitrary framework error payloads.
                event = .failure(.init(.recognitionFailed, "Apple Speech could not transcribe this audio. Check permissions, language support, and your connection, then try again."))
            } else { event = nil }
            if let event { Task { @MainActor in onEvent(event) } }
        }
        lifetime = SpeechTaskLifetime(task: task, sink: sink)
    }
    func finishAudio() { lifetime.sink.end() }
    func cancel() { lifetime.cancel() }
}
