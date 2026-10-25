import Foundation
import GamepadTerminalCore

@MainActor final class AppCoordinator {
    private(set) var state = ApplicationState()
    private var mapper = ControllerMapper()
    let bridge: any BridgeClient
    var voice: (any VoiceService)!
    var keys: (any NativeKeyService)!
    var selectedInput: String?
    var onChange: (() -> Void)?
    var onHelp: (() -> Void)?
    private(set) var scrollback: ScrollbackPage?
    private var effects: [ApplicationEffect] = []
    private var runner: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var maintenanceBusy = false
    private var stopping = false
    private var foreground: @MainActor () -> Bool = { true }

    init(bridge: any BridgeClient) { self.bridge = bridge }
    var inputStatus: String {
        if !state.enabled { return "controls disabled" }
        if !state.controllerConnected { return "controller disconnected" }
        if !state.iTermFrontmost || !foreground() { return "iTerm2 keyboard focus is not verified" }
        if state.bridgeStatus != .connected { return "bridge disconnected" }
        if state.error != nil { return "error needs acknowledgment" }
        if runner != nil || maintenanceBusy { return "waiting for an action or bridge check" }
        return "ready"
    }
    var pinnedTarget: TerminalTarget? { state.canUseTerminal ? state.dictation.target : nil }
    func pinnedTarget(generation: UInt64) -> TerminalTarget? { generation == state.generation ? pinnedTarget : nil }
    func receive(_ event: ControllerEvent, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        for intent in mapper.handle(event, at: now) {
            // Drop physical navigation/confirm edges while an action is awaiting RPC.
            // R2 release and Circle must always cancel/finish active voice promptly.
            if runner != nil || maintenanceBusy {
                switch intent {
                case .dictationReleased: break
                case .cancel, .terminal(.control(.interrupt)):
                    if state.dictation == .idle { syncMapper(); continue }
                default: syncMapper(); continue
                }
            }
            send(.intent(intent))
        }
    }
    func controllerChanged(_ connected: Bool) {
        if !connected { mapper.disconnected() }
        send(.controllerConnected(connected))
    }
    func send(_ event: ApplicationEvent) {
        guard !stopping else { return }
        let produced = state.handle(event)
        syncMapper()
        for effect in produced {
            if case let .cancelVoice(generation) = effect {
                voice?.cancel(generation: generation) // never wait behind transcription or RPC
                effects.removeAll()
            } else if effect == .showHelp { onHelp?() }
            else {
                if case let .stopAndTranscribe(generation) = effect {
                    voice?.stopCapture(generation: generation)
                }
                effects.append(effect)
            }
        }
        onChange?()
        drain()
    }
    private func syncMapper() {
        mapper.setGate(state.canUseTerminal)
        mapper.setOrdinaryActionsEnabled(state.acceptsOrdinaryActions)
        mapper.setScrollMode(state.scrollMode)
        if !state.scrollMode { scrollback = nil }
    }
    private func drain() {
        guard runner == nil, !maintenanceBusy, !effects.isEmpty, !stopping else { return }
        runner = Task { [weak self] in
            guard let self else { return }
            while !self.effects.isEmpty, !self.stopping {
                let effect = self.effects.removeFirst()
                await self.execute(effect)
            }
            self.runner = nil
        }
    }
    private func valid(_ generation: UInt64) -> Bool {
        !stopping && !Task.isCancelled && foreground() && state.generation == generation && state.canUseTerminal
    }
    private func request(_ request: BridgeRequest, generation: UInt64) async throws -> BridgeResponse {
        guard valid(generation) else { throw CancellationError() }
        let result = try await bridge.request(request)
        try result.validate(for: request)
        guard valid(generation) else { throw CancellationError() }
        return result
    }
    private func capture(_ generation: UInt64) async throws -> TerminalTarget {
        let response = try await request(.init(operation: .captureTarget), generation: generation)
        guard let target = response.target, target.isValid else { throw BridgeFailure(.invalidRequest, "No valid focused terminal target was returned.") }
        return target
    }
    private func execute(_ effect: ApplicationEffect) async {
        let generation: UInt64
        switch effect {
        case let .captureTarget(g), let .startRecording(g, _), let .stopAndTranscribe(g),
             let .insertTranscript(g, _, _), let .submit(g, _), let .terminal(g, _), let .cancelVoice(g): generation = g
        case .showHelp: onHelp?(); return
        }
        guard valid(generation) else { return }
        do {
            switch effect {
            case .captureTarget:
                let target = try await capture(generation)
                send(.targetCaptured(generation: generation, target: target))
            case let .startRecording(_, target):
                // Verify the originally captured target again; never adopt the reply as a new target.
                try await verify(target, generation: generation)
                try await voice.startRecording(inputID: selectedInput, generation: generation)
                guard valid(generation) else { voice.cancel(generation: generation); return }
                send(.recordingStarted(generation: generation))
            case .stopAndTranscribe:
                let text = try await voice.stopAndTranscribe(generation: generation)
                guard valid(generation) else { return }
                send(.transcriptReady(generation: generation, text: text))
            case let .insertTranscript(_, target, text):
                _ = try await request(.init(operation: .insertText, target: target, text: TranscriptSanitizer.validated(text)), generation: generation)
                send(.insertionFinished(generation: generation))
            case let .submit(_, target):
                _ = try await request(.init(operation: .control, target: target, control: .enter), generation: generation)
                send(.submissionFinished(generation: generation))
            case let .terminal(_, action):
                let target: TerminalTarget
                if let pinned = scrollback?.target { target = pinned }
                else { target = try await capture(generation) }
                guard valid(generation) else { return }
                switch action {
                case let .control(control): _ = try await request(.init(operation: .control, target: target, control: control), generation: generation)
                case let .selectPane(direction): _ = try await request(.init(operation: .selectPane, target: target, direction: direction), generation: generation)
                case let .selectTab(direction): _ = try await request(.init(operation: .selectTab, target: target, tabDirection: direction), generation: generation)
                case let .arrow(direction):
                    try await keys.sendArrow(direction, target: target)
                case let .scrollback(delta):
                    guard state.scrollMode else { return }
                    let previous = scrollback
                    let first = previous.map { page in
                        let step = delta < 0 ? max(delta, -max(1, page.lines.count)) : delta
                        return min(page.newestLine, max(page.oldestLine, page.firstLine - step))
                    }
                    var response = try await request(.init(operation: .readScrollback, target: target, firstLine: first, lineCount: 40), generation: generation)
                    // A byte-limited older page may end before the current page begins.
                    // Fall back to its immediate predecessor so no lines are skipped.
                    if delta > 0, let previous, let page = response.page,
                       page.firstLine + page.lines.count < previous.firstLine {
                        response = try await request(.init(operation: .readScrollback, target: target,
                            firstLine: max(page.oldestLine, previous.firstLine - 1), lineCount: 40), generation: generation)
                    }
                    guard state.scrollMode else { return }
                    scrollback = response.page; onChange?()
                }
            case .cancelVoice, .showHelp: break
            }
        } catch is CancellationError { }
        catch {
            // Ambiguity survives gate/generation loss: it may have sent text already.
            if let failure = error as? BridgeFailure, failure.code == .outcomeUnknown {
                send(.failed(generation: state.generation, message: failure.message))
            } else if let failure = error as? BridgeFailure, isTargetFailure(failure), valid(generation) {
                targetFailed(failure, generation: generation)
            } else if valid(generation) {
                send(.failed(generation: generation, message: error.localizedDescription))
            }
        }
    }
    private func verify(_ target: TerminalTarget, generation: UInt64) async throws {
        let current = try await capture(generation)
        guard current.sessionID == target.sessionID, current.windowID == target.windowID, current.tabID == target.tabID else {
            throw BridgeFailure(.targetChanged, "The pinned terminal changed. Start again in the intended pane.")
        }
    }
    private func isTargetFailure(_ failure: BridgeFailure) -> Bool {
        [.notFocused, .targetChanged, .targetGone].contains(failure.code)
    }
    private func targetFailed(_ failure: BridgeFailure, generation: UInt64) {
        switch state.dictation {
        case .inserted, .submitting:
            // Text is already in the pinned terminal. End local tracking quietly;
            // never submit or replay it in a different terminal.
            send(.intent(.cancel))
        default:
            send(.failed(generation: generation, message: failure.message))
        }
    }
    /// One monitor owns reconnection; it only sends read-only operations, never replays actions.
    func startMonitoring(foreground: @escaping @MainActor () -> Bool) {
        guard monitor == nil else { return }
        self.foreground = foreground
        monitor = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, !self.stopping else { return }
                let focused = foreground()
                if focused != self.state.iTermFrontmost { self.send(.foregroundChanged(focused)) }
                let voiceIsWaiting: Bool
                switch self.state.dictation {
                case .recording, .transcribing: voiceIsWaiting = true
                default: voiceIsWaiting = false
                }
                if self.state.enabled, !self.maintenanceBusy,
                   self.runner == nil || voiceIsWaiting {
                    // The voice runner can await Apple Speech while read-only target checks run.
                    // Socket client rejects overlap rather than queueing a stale request.
                    self.maintenanceBusy = true
                    let generation = self.state.generation
                    let target = self.pinnedTarget ?? self.scrollback?.target
                    do {
                        if let target, self.state.canUseTerminal {
                            try await self.verify(target, generation: generation)
                        } else if self.runner == nil {
                            _ = try await self.bridge.request(.init(operation: .ping))
                            if self.state.enabled, self.state.bridgeStatus != .connected {
                                self.mapper.disconnected()
                                self.send(.bridgeChanged(.connected))
                            }
                        }
                        failures = 0
                    } catch is CancellationError { }
                    catch let failure as BridgeFailure where failure.code == .busy { }
                    catch let failure as BridgeFailure where self.isTargetFailure(failure) {
                        if self.valid(generation) { self.targetFailed(failure, generation: generation) }
                        failures = 0
                    }
                    catch {
                        if target != nil, self.valid(generation) {
                            self.send(.failed(generation: generation, message: error.localizedDescription))
                        }
                        self.send(.bridgeChanged(.failed("Bridge unavailable. Start or restart the Python bridge.")))
                        await self.bridge.disconnect()
                        failures = min(failures + 1, BridgeProtocol.reconnectDelays.count)
                    }
                    self.maintenanceBusy = false
                    self.drain()
                }
                let delay = failures > 0 ? BridgeProtocol.reconnectDelays[failures - 1] : 0.25
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }
    func setEnabled(_ enabled: Bool) {
        send(.enabledChanged(enabled))
        if !enabled { Task { await bridge.disconnect() }; mapper.disconnected() }
    }
    func shutdown() async {
        guard !stopping else { return }
        send(.enabledChanged(false))
        stopping = true
        monitor?.cancel(); monitor = nil
        runner?.cancel()
        effects.removeAll()
        await bridge.disconnect()
        await runner?.value
        runner = nil
    }
}
