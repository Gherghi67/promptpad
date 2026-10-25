import CoreMedia
import XCTest
import GamepadTerminalCore
@testable import GamepadTerminalVoice

@MainActor private final class FakeSink: VoiceAudioSink, @unchecked Sendable {
    nonisolated func append(_ buffer: CMSampleBuffer) {}
}

@MainActor private final class FakeCaptureSession: VoiceCaptureSession {
    var starts = 0
    var stops = 0
    var suspendStart = false
    var startWaiter: CheckedContinuation<Void, Error>?
    let fail: @MainActor @Sendable (VoiceFailure) -> Void
    init(fail: @escaping @MainActor @Sendable (VoiceFailure) -> Void) { self.fail = fail }
    func start() async throws {
        starts += 1
        if suspendStart { try await withCheckedThrowingContinuation { startWaiter = $0 } }
    }
    func stop() { stops += 1 }
    func resumeStart() { let waiter = startWaiter; startWaiter = nil; waiter?.resume() }
}

@MainActor private final class FakeCapture: VoiceCaptureBackend {
    var inputs = [AudioInput(id: "built-in", name: "Mac Microphone"), AudioInput(id: "usb", name: "USB Microphone")]
    var permission = VoicePermission.authorized
    var authorizationRequests = 0
    var sessions: [FakeCaptureSession] = []
    var requestedIDs: [String?] = []
    var suspendStart = false
    var makeError: VoiceFailure?
    func requestAuthorization() async throws { authorizationRequests += 1; permission = .authorized }
    func makeSession(inputID: String?, sink: any VoiceAudioSink,
                     onFailure: @escaping @MainActor @Sendable (VoiceFailure) -> Void) throws -> any VoiceCaptureSession {
        if let makeError { throw makeError }
        requestedIDs.append(inputID)
        let session = FakeCaptureSession(fail: onFailure)
        session.suspendStart = suspendStart
        sessions.append(session)
        return session
    }
}

@MainActor private final class FakeRecognitionSession: VoiceRecognitionSession {
    let audioSink: any VoiceAudioSink = FakeSink()
    let emit: @MainActor @Sendable (VoiceRecognitionEvent) -> Void
    var finishes = 0
    var cancellations = 0
    init(emit: @escaping @MainActor @Sendable (VoiceRecognitionEvent) -> Void) { self.emit = emit }
    func finishAudio() { finishes += 1 }
    func cancel() { cancellations += 1 }
}

@MainActor private final class FakeRecognition: VoiceRecognitionBackend {
    var permission = VoicePermission.authorized
    var isAvailable = true
    var authorizationRequests = 0
    var sessions: [FakeRecognitionSession] = []
    func requestAuthorization() async throws { authorizationRequests += 1; permission = .authorized }
    func makeSession(onEvent: @escaping @MainActor @Sendable (VoiceRecognitionEvent) -> Void) throws -> any VoiceRecognitionSession {
        let session = FakeRecognitionSession(emit: onEvent)
        sessions.append(session)
        return session
    }
}

@MainActor private final class FakeDeadline: VoiceDeadline {
    let seconds: TimeInterval
    let action: @MainActor @Sendable () -> Void
    var cancelled = false
    init(seconds: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) { self.seconds = seconds; self.action = action }
    func cancel() { cancelled = true }
    func fire() { if !cancelled { action() } }
}

@MainActor private final class FakeDeadlines: VoiceDeadlineScheduler {
    var timers: [FakeDeadline] = []
    func schedule(after seconds: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) -> any VoiceDeadline {
        let timer = FakeDeadline(seconds: seconds, action: action)
        timers.append(timer)
        return timer
    }
}

@MainActor private final class Fixture {
    let capture = FakeCapture()
    let recognition = FakeRecognition()
    let deadlines = FakeDeadlines()
    var target: TerminalTarget? = .init(sessionID: "session", windowID: "window", tabID: "tab", title: "shell")
    lazy var service = NativeVoiceService(capture: capture, recognition: recognition, deadlines: deadlines) { [weak self] _ in self?.target }
}

@MainActor final class NativeVoiceServiceTests: XCTestCase {
    private func assertFailure(_ code: VoiceFailure.Code, operation: () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(code)", file: file, line: line) }
        catch let failure as VoiceFailure { XCTAssertEqual(failure.code, code, file: file, line: line) }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Expected asynchronous lifecycle transition", file: file, line: line)
    }

    func testNoPinnedOrInvalidTargetNeverAcquiresAudio() async {
        for target: TerminalTarget? in [nil, .init(sessionID: "", windowID: "w", tabID: "t", title: "bad")] {
            let f = Fixture(); f.target = target
            await assertFailure(.targetInvalidated) { try await f.service.startRecording(inputID: nil, generation: 1) }
            XCTAssertTrue(f.capture.sessions.isEmpty)
            XCTAssertTrue(f.recognition.sessions.isEmpty)
        }
    }

    func testPermissionsAreExplicitAndStartNeverPrompts() async throws {
        let f = Fixture()
        f.capture.permission = .notDetermined; f.recognition.permission = .notDetermined
        XCTAssertEqual(f.service.availability, .permissionRequired)
        await assertFailure(.permissionRequired) { try await f.service.startRecording(inputID: nil, generation: 1) }
        XCTAssertEqual(f.capture.authorizationRequests, 0)
        XCTAssertEqual(f.recognition.authorizationRequests, 0)
        XCTAssertTrue(f.capture.sessions.isEmpty)
        try await f.service.requestAuthorization()
        XCTAssertEqual(f.service.permissions, VoicePermissions(microphone: .authorized, speech: .authorized))
        XCTAssertEqual(f.capture.authorizationRequests, 1)
        XCTAssertEqual(f.recognition.authorizationRequests, 1)
        XCTAssertEqual(f.service.availability, .available)
    }

    func testDeniedPermissionAndUnavailableRecognitionAreActionable() async {
        let f = Fixture(); f.capture.permission = .denied
        XCTAssertEqual(f.service.availability, .permissionDenied)
        await assertFailure(.permissionDenied) { try await f.service.startRecording(inputID: nil, generation: 1) }
        f.capture.permission = .authorized; f.recognition.isAvailable = false
        XCTAssertEqual(f.service.availability, .recognitionUnavailable)
        await assertFailure(.recognitionUnavailable) { try await f.service.startRecording(inputID: nil, generation: 2) }
        XCTAssertTrue(f.capture.sessions.isEmpty)
        XCTAssertTrue(f.service.recognitionNotice.contains("Apple servers"))
        XCTAssertTrue(f.service.recognitionNotice.contains("not guaranteed"))
    }

    func testSelectionUsesExactAvailableIDAndNeverSubstitutesDualSense() async throws {
        let f = Fixture()
        XCTAssertEqual(f.service.inputs, f.capture.inputs)
        await assertFailure(.inputUnavailable) { try await f.service.startRecording(inputID: "DualSense", generation: 1) }
        XCTAssertTrue(f.capture.sessions.isEmpty)
        try await f.service.startRecording(inputID: "usb", generation: 2)
        XCTAssertEqual(f.capture.requestedIDs.count, 1)
        XCTAssertEqual(f.capture.requestedIDs.first!, "usb")
        f.service.cancel(generation: 2)
        f.capture.inputs = []
        XCTAssertEqual(f.service.availability, .noAudioInputs)
        await assertFailure(.inputUnavailable) { try await f.service.startRecording(inputID: nil, generation: 3) }
    }

    func testReleaseStopsCaptureAndReturnsFinalSanitizedReviewOnly() async throws {
        let f = Fixture()
        try await f.service.startRecording(inputID: "usb", generation: 1)
        XCTAssertEqual(f.service.state, .recording(generation: 1, inputID: "usb"))
        XCTAssertEqual(f.deadlines.timers.first?.seconds, 60)
        let result = Task { try await f.service.stopAndTranscribe(generation: 1) }
        await eventually { f.recognition.sessions[0].finishes == 1 }
        XCTAssertGreaterThan(f.capture.sessions[0].stops, 0)
        XCTAssertEqual(f.service.state, .transcribing(generation: 1))
        XCTAssertEqual(f.deadlines.timers.last?.seconds, 15)
        f.recognition.sessions[0].emit(.final("  echo\r\nhello\t\u{1b}🙂  "))
        let text = try await result.value
        XCTAssertEqual(text, "echo hello 🙂")
        XCTAssertEqual(f.service.state, .review(generation: 1, text: text))
        XCTAssertTrue(f.deadlines.timers.allSatisfy(\.cancelled))
    }

    func testEarlyFinalStopsMicrophoneButStillRequiresRelease() async throws {
        let f = Fixture()
        try await f.service.startRecording(inputID: nil, generation: 1)
        f.recognition.sessions[0].emit(.final("draft"))
        XCTAssertEqual(f.service.state, .awaitingRelease(generation: 1))
        XCTAssertGreaterThan(f.capture.sessions[0].stops, 0)
        let text = try await f.service.stopAndTranscribe(generation: 1)
        XCTAssertEqual(text, "draft")
        XCTAssertEqual(f.recognition.sessions[0].finishes, 0)
    }

    func testCancelBeforeStartRejectsDelayedEffect() async {
        let f = Fixture()
        f.service.cancel(generation: 5)
        await assertFailure(.staleGeneration) { try await f.service.startRecording(inputID: nil, generation: 5) }
        XCTAssertTrue(f.capture.sessions.isEmpty)
    }

    func testCancelDiscardsReviewedTranscriptAndRejectsLateCallbacks() async throws {
        let f = Fixture()
        try await f.service.startRecording(inputID: nil, generation: 1)
        f.recognition.sessions[0].emit(.final("draft"))
        _ = try await f.service.stopAndTranscribe(generation: 1)
        f.service.cancel(generation: 1)
        f.recognition.sessions[0].emit(.final("late"))
        XCTAssertEqual(f.service.state, .idle)
    }

    func testTaskCancellationDuringStartClosesCaptureBeforeStartCompletes() async throws {
        let f = Fixture(); f.capture.suspendStart = true
        let start = Task { try await f.service.startRecording(inputID: nil, generation: 1) }
        await eventually { f.capture.sessions.first?.startWaiter != nil }
        XCTAssertEqual(f.service.state, .starting(generation: 1, inputID: nil))
        start.cancel()
        await eventually { f.capture.sessions[0].stops > 0 }
        XCTAssertEqual(f.service.state, .idle)
        f.capture.sessions[0].resumeStart()
        await assertFailure(.staleGeneration) { try await start.value }
        XCTAssertEqual(f.service.state, .idle)
    }

    func testReleaseDuringStartCancelsAndRejectsLateCompletion() async throws {
        let f = Fixture(); f.capture.suspendStart = true
        var app = ApplicationState()
        _ = app.handle(.enabledChanged(true)); _ = app.handle(.controllerConnected(true))
        _ = app.handle(.foregroundChanged(true)); _ = app.handle(.bridgeChanged(.connected))
        _ = app.handle(.intent(.dictationPressed))
        let generation = app.generation
        _ = app.handle(.targetCaptured(generation: generation, target: f.target!))
        let start = Task { try await f.service.startRecording(inputID: nil, generation: generation) }
        await eventually { f.capture.sessions.first?.startWaiter != nil }
        XCTAssertEqual(app.handle(.intent(.dictationReleased)), [.cancelVoice(generation: generation)])
        f.service.cancel(generation: generation)
        XCTAssertGreaterThan(f.capture.sessions[0].stops, 0)
        f.capture.sessions[0].resumeStart()
        await assertFailure(.staleGeneration) { try await start.value }
        XCTAssertEqual(app.handle(.recordingStarted(generation: generation)), [])
        f.recognition.sessions[0].emit(.final("late words"))
        XCTAssertEqual(app.dictation, .idle)
        XCTAssertEqual(f.service.state, .idle)
    }

    func testCancelDuringDelayedStartCannotReviveCaptureOrStopNewGeneration() async throws {
        let f = Fixture(); f.capture.suspendStart = true
        let old = Task { try await f.service.startRecording(inputID: nil, generation: 1) }
        await eventually { f.capture.sessions.first?.startWaiter != nil }
        f.service.cancel(generation: 1)
        XCTAssertGreaterThan(f.capture.sessions[0].stops, 0)
        f.capture.suspendStart = false
        try await f.service.startRecording(inputID: "usb", generation: 2)
        f.capture.sessions[0].resumeStart()
        await assertFailure(.staleGeneration) { try await old.value }
        f.recognition.sessions[0].emit(.final("stale"))
        f.capture.sessions[0].fail(.init(.captureFailed, "late"))
        f.service.cancel(generation: 1)
        XCTAssertEqual(f.service.state, .recording(generation: 2, inputID: "usb"))
        XCTAssertEqual(f.capture.sessions[1].stops, 0)
        f.service.cancel(generation: 2)
    }

    func testChangedTargetDuringStartStopsCapture() async {
        let f = Fixture(); f.capture.suspendStart = true
        let start = Task { try await f.service.startRecording(inputID: nil, generation: 1) }
        await eventually { f.capture.sessions.first?.startWaiter != nil }
        f.target = .init(sessionID: "different", windowID: "window", tabID: "tab", title: "other")
        f.capture.sessions[0].resumeStart()
        await assertFailure(.targetInvalidated) { try await start.value }
        XCTAssertGreaterThan(f.capture.sessions[0].stops, 0)
        XCTAssertGreaterThan(f.recognition.sessions[0].cancellations, 0)
    }

    func testTaskCancellationWhileTranscribingStopsAndInvalidatesCallbacks() async throws {
        let f = Fixture()
        try await f.service.startRecording(inputID: nil, generation: 1)
        let result = Task { try await f.service.stopAndTranscribe(generation: 1) }
        await eventually { f.recognition.sessions[0].finishes == 1 }
        result.cancel()
        await assertFailure(.cancelled) { _ = try await result.value }
        f.recognition.sessions[0].emit(.final("late transcript"))
        XCTAssertEqual(f.service.state, .idle)
        XCTAssertGreaterThan(f.recognition.sessions[0].cancellations, 0)
    }

    func testRecordingDeadlineStopsAndReportsOriginalGeneration() async throws {
        let f = Fixture()
        var failures: [(UInt64, VoiceFailure.Code)] = []
        f.service.onFailure = { failures.append(($0, $1.code)) }
        try await f.service.startRecording(inputID: nil, generation: 7)
        f.deadlines.timers[0].fire()
        XCTAssertEqual(failures.first?.0, 7)
        XCTAssertEqual(failures.first?.1, .recordingLimit)
        XCTAssertGreaterThan(f.capture.sessions[0].stops, 0)
        await assertFailure(.recordingLimit) { _ = try await f.service.stopAndTranscribe(generation: 7) }
        f.recognition.sessions[0].emit(.final("late"))
        guard case .failed = f.service.state else { return XCTFail("Late final overwrote failure") }
    }

    func testFinalDeadlineResumesWaiterAndIgnoresLateFinal() async throws {
        let f = Fixture()
        try await f.service.startRecording(inputID: nil, generation: 1)
        let result = Task { try await f.service.stopAndTranscribe(generation: 1) }
        await eventually { f.deadlines.timers.count == 2 }
        f.deadlines.timers[1].fire()
        await assertFailure(.transcriptionTimeout) { _ = try await result.value }
        f.recognition.sessions[0].emit(.final("late"))
        guard case let .failed(failure) = f.service.state else { return XCTFail("Missing timeout state") }
        XCTAssertEqual(failure.code, .transcriptionTimeout)
    }

    func testDeviceRemovalAndRecognitionFailureReleaseResources() async throws {
        for failure in [VoiceFailure(.inputUnavailable, "Microphone disconnected; select another input."), .init(.recognitionFailed, "Try again.")] {
            let f = Fixture()
            try await f.service.startRecording(inputID: "usb", generation: 1)
            if failure.code == .inputUnavailable { f.capture.sessions[0].fail(failure) }
            else { f.recognition.sessions[0].emit(.failure(failure)) }
            XCTAssertEqual(f.service.state, .failed(failure))
            XCTAssertGreaterThan(f.capture.sessions[0].stops, 0)
            XCTAssertGreaterThan(f.recognition.sessions[0].cancellations, 0)
            await assertFailure(failure.code) { _ = try await f.service.stopAndTranscribe(generation: 1) }
        }
    }

    func testFinalWithInvalidatedTargetIsDiscarded() async throws {
        let f = Fixture()
        try await f.service.startRecording(inputID: nil, generation: 1)
        let result = Task { try await f.service.stopAndTranscribe(generation: 1) }
        await eventually { f.recognition.sessions[0].finishes == 1 }
        f.target = nil
        f.recognition.sessions[0].emit(.final("must not review"))
        await assertFailure(.targetInvalidated) { _ = try await result.value }
    }

    func testAllReducerGateLossesStopCaptureAndRejectStaleWork() async throws {
        for gate in [ApplicationEvent.enabledChanged(false), .controllerConnected(false), .foregroundChanged(false), .bridgeChanged(.disconnected)] {
            var app = ApplicationState()
            _ = app.handle(.enabledChanged(true)); _ = app.handle(.controllerConnected(true))
            _ = app.handle(.foregroundChanged(true)); _ = app.handle(.bridgeChanged(.connected))
            _ = app.handle(.intent(.dictationPressed))
            let generation = app.generation
            let f = Fixture()
            _ = app.handle(.targetCaptured(generation: generation, target: f.target!))
            try await f.service.startRecording(inputID: nil, generation: generation)
            _ = app.handle(.recordingStarted(generation: generation))
            for effect in app.handle(gate) {
                if case let .cancelVoice(generation) = effect { f.service.cancel(generation: generation) }
                else { XCTFail("Unexpected gate-loss effect") }
            }
            XCTAssertGreaterThan(f.capture.sessions[0].stops, 0)
            f.recognition.sessions[0].emit(.final("late"))
            XCTAssertEqual(f.service.state, .idle)
            XCTAssertEqual(app.dictation, .idle)
            await assertFailure(.staleGeneration) { _ = try await f.service.stopAndTranscribe(generation: generation) }
            f.deadlines.timers[0].action() // even a timer delivered after cancellation is inert
            XCTAssertEqual(f.service.state, .idle)
        }
    }

    func testEmptyAndOversizedFinalAreRejected() async throws {
        for text in ["\r\n\u{1b}", String(repeating: "🙂", count: 2049)] {
            let f = Fixture()
            try await f.service.startRecording(inputID: nil, generation: 1)
            f.recognition.sessions[0].emit(.final(text))
            await assertFailure(.noSpeech) { _ = try await f.service.stopAndTranscribe(generation: 1) }
        }
    }

    func testCaptureSetupFailureCancelsRecognition() async {
        let f = Fixture(); f.capture.makeError = .init(.inputUnavailable, "Input removed during setup.")
        await assertFailure(.inputUnavailable) { try await f.service.startRecording(inputID: "usb", generation: 1) }
        XCTAssertEqual(f.recognition.sessions[0].cancellations, 1)
        XCTAssertTrue(f.capture.sessions.isEmpty)
    }
    func testPhysicalReleaseClosesCaptureBeforeTranscriptionIsScheduled() async throws {
        let f = Fixture()
        try await f.service.startRecording(inputID: nil, generation: 1)
        let session = try XCTUnwrap(f.capture.sessions.first)
        f.service.stopCapture(generation: 0)
        XCTAssertEqual(session.stops, 0)
        f.service.stopCapture(generation: 1)
        XCTAssertEqual(session.stops, 1)
        XCTAssertEqual(f.recognition.sessions.first?.finishes, 0)
        let transcription = Task { try await f.service.stopAndTranscribe(generation: 1) }
        await eventually { f.recognition.sessions.first?.finishes == 1 }
        f.recognition.sessions.first?.emit(.final("test words"))
        let result = try await transcription.value
        XCTAssertEqual(result, "test words")
    }

}
