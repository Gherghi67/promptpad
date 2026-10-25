import AppKit
@preconcurrency import ApplicationServices
import GamepadTerminalCore
import GamepadTerminalVoice

@MainActor private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class TranscriptPanel: NSObject, NSWindowDelegate {
    var onSetup: (() -> Void)?
    var onClose: (() -> Void)?
    private let panel: NSPanel
    private let text: NSTextView
    private let scroll: NSScrollView
    override init() {
        panel = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 344),
                        styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Gamepad Terminal"
        // iTerm's floating hotkey windows can sit at status-window level.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        scroll = NSScrollView(frame: NSRect(x: 0, y: 44, width: 640, height: 300))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        text = NSTextView(frame: scroll.bounds)
        super.init()
        panel.delegate = self
        text.isEditable = false; text.isSelectable = false
        text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        text.textContainerInset = NSSize(width: 18, height: 18)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 344))
        content.addSubview(scroll)
        let setupButton = NSButton(title: "Open Setup…", target: self, action: #selector(openSetup))
        setupButton.frame = NSRect(x: 18, y: 8, width: 140, height: 28)
        content.addSubview(setupButton)
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closePreview))
        closeButton.frame = NSRect(x: 526, y: 8, width: 96, height: 28)
        content.addSubview(closeButton)
        panel.contentView = content
        panel.center()
    }
    func show(_ value: String) {
        if text.string != value {
            text.string = value
            text.sizeToFit()
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        panel.orderFrontRegardless() // nonactivating: never makeKey or activate the companion
    }
    func scrollPreview(_ value: Float) {
        guard abs(value) > InputPolicy.stickDeadZone else { return }
        let clip = scroll.contentView
        let y = min(max(0, text.bounds.height - clip.bounds.height), max(0, clip.bounds.origin.y - CGFloat(value) * 9))
        clip.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(clip)
    }
    @objc private func openSetup() { onSetup?() }
    @objc private func closePreview() { panel.performClose(nil) }
    func windowWillClose(_ notification: Notification) { onClose?() }
    func hide() { panel.orderOut(nil) }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let instance: InstanceLock
    let controller = GameControllerAdapter()
    let coordinator = AppCoordinator(bridge: UnixBridgeClient())
    private var voice: NativeVoiceService!
    private var status: NSStatusItem!
    private let overlay = TranscriptPanel()
    private var controllerName: String?
    private var showingHelp = false
    private var dismissedError: String?
    private var setup: SetupWindow!
    private var triggerLevel = -1
    private var triggerPeak = 0
    private var triggerPresses = 0
    private var lastTriggerGate = "not pressed yet"
    private var lastVoiceStep = "not started"
    private var activationObserver: NSObjectProtocol?
    init(instance: InstanceLock) { self.instance = instance }
    func applicationDidFinishLaunching(_ notification: Notification) {
        voice = NativeVoiceService { [weak coordinator] generation in coordinator?.pinnedTarget(generation: generation) }
        coordinator.voice = voice
        coordinator.keys = NativeKeys(bridge: coordinator.bridge, gateGeneration: { [weak coordinator] in
            guard let coordinator, coordinator.state.acceptsOrdinaryActions else { return nil }
            return coordinator.state.generation
        })
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak coordinator] _ in
            MainActor.assumeIsolated {
                guard let coordinator else { return }
                let frontmost = TerminalFocus.frontmost != nil
                if coordinator.state.iTermFrontmost != frontmost { coordinator.send(.foregroundChanged(frontmost)) }
            }
        }
        voice.onFailure = { [weak coordinator] generation, failure in
            coordinator?.send(.failed(generation: generation, message: failure.message))
        }
        coordinator.onChange = { [weak self] in self?.refresh() }
        coordinator.onHelp = { [weak self] in self?.showHelp() }
        controller.onEvent = { [weak self] event in
            guard let self else { return }
            if case let .rightTrigger(value) = event {
                let level = Int(value * 100)
                if level != self.triggerLevel {
                    if level >= 65 && self.triggerLevel < 65 {
                        self.triggerPresses += 1
                        let front = NSWorkspace.shared.frontmostApplication
                        let label = front?.localizedName ?? "unknown app"
                        let identifier = front?.bundleIdentifier ?? "no identifier"
                        self.lastTriggerGate = "\(self.coordinator.inputStatus) — active app: \(label) (\(identifier))\n\(TerminalFocus.diagnostic)"
                    }
                    self.triggerLevel = level
                    self.triggerPeak = max(self.triggerPeak, level)
                    self.refreshDiagnostics()
                }
            }
            if case let .stickY(value) = event, self.coordinator.state.canUseTerminal {
                if self.showingHelp { self.overlay.scrollPreview(value) }
                else if case .review = self.coordinator.state.dictation { self.overlay.scrollPreview(value) }
            }
            self.coordinator.receive(event)
        }
        controller.onConnection = { [weak self] connected, name in
            self?.controllerName = name
            self?.coordinator.controllerChanged(connected)
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "🎮"
        let menu = NSMenu(); menu.delegate = self; status.menu = menu
        setup = SetupWindow()
        overlay.onSetup = { [weak self] in self?.showSetup() }
        overlay.onClose = { [weak self] in self?.closeOverlay() }
        setup.onToggle = { [weak self] in self?.toggleEnabled() }
        setup.onVoice = { [weak self] in self?.setupVoice() }
        setup.onAccessibility = { [weak self] in self?.setupAccessibility() }
        setup.onAcknowledge = { [weak self] in self?.acknowledge() }
        setup.onInput = { [weak self] input in
            guard let self, self.coordinator.state.dictation == .idle else { return }
            self.coordinator.selectedInput = input
        }
        coordinator.startMonitoring { TerminalFocus.frontmost != nil }
        showSetup()
        refresh()
    }
    private var bridgeLabel: String {
        switch coordinator.state.bridgeStatus {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .disconnected: "Disconnected — start the Python bridge"
        case let .failed(message): message
        }
    }
    private var recordingLabel: String {
        switch coordinator.state.dictation {
        case .idle: "Idle"
        case .capturingTarget: "Verifying terminal target"
        case .startingRecording: "Starting microphone"
        case .recording: "Recording — release R2 to transcribe"
        case .transcribing: "Transcribing — please wait"
        case .review: "Review — X (×) inserts; Circle discards"
        case .inserting: "Inserting — please wait"
        case .inserted: "Inserted — a new X (×) submits"
        case .submitting: "Submitting — please wait"
        }
    }
    func menuWillOpen(_ menu: NSMenu) {
        showingHelp = false; overlay.hide()
        menu.removeAllItems()
        @discardableResult func item(_ title: String, _ action: Selector? = nil) -> NSMenuItem {
            let result = NSMenuItem(title: title, action: action, keyEquivalent: "")
            result.target = self
            menu.addItem(result)
            return result
        }
        item("Setup…", #selector(showSetup))
        item(coordinator.state.enabled ? "Disable controller" : "Enable controller", #selector(toggleEnabled))
        item("Controller: \(controllerName ?? "Disconnected")")
        item("Bridge: \(bridgeLabel)")
        item("Voice: \(recordingLabel)")
        item(TerminalFocus.frontmost == nil ? "Focus an iTerm2 terminal to use controls" : "iTerm2 has keyboard focus; bridge checks the exact terminal")
        menu.addItem(.separator())
        let inputMenu = NSMenu()
        let defaultInput = NSMenuItem(title: "System default input", action: #selector(selectInput(_:)), keyEquivalent: "")
        defaultInput.target = self; defaultInput.state = coordinator.selectedInput == nil ? .on : .off
        defaultInput.isEnabled = coordinator.state.dictation == .idle
        inputMenu.addItem(defaultInput)
        for input in voice.inputs {
            let entry = NSMenuItem(title: input.name, action: #selector(selectInput(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = input.id
            entry.state = coordinator.selectedInput == input.id ? .on : .off
            entry.isEnabled = coordinator.state.dictation == .idle
            inputMenu.addItem(entry)
        }
        inputMenu.autoenablesItems = false
        item("Audio input").submenu = inputMenu
        item("Set up Microphone & Speech permissions…", #selector(setupVoice))
        item("Set up Accessibility for hotkey windows & arrows…", #selector(setupAccessibility))
        item("Apple Speech may process audio on Apple servers")
        item("DualSense microphone is not supported on Mac; select another input")
        if let error = coordinator.state.error {
            menu.addItem(.separator())
            item(error)
            item("I inspected the target — acknowledge error", #selector(acknowledge))
        }
        menu.addItem(.separator())
        item("Mapping & setup help", #selector(showHelp))
        item("Quit", #selector(quit))
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup(); return true
    }
    @objc private func showSetup() { showingHelp = false; overlay.hide(); setup.present(); refresh(); overlay.hide() }
    @objc private func toggleEnabled() {
        showingHelp = false
        let enabled = !coordinator.state.enabled
        coordinator.setEnabled(enabled)
        if enabled { controller.start() } else { controller.stop() }
    }
    @objc private func selectInput(_ sender: NSMenuItem) {
        guard coordinator.state.dictation == .idle else { return }
        coordinator.selectedInput = sender.representedObject as? String
    }
    @objc private func setupVoice() {
        Task {
            do { try await voice.requestAuthorization() }
            catch { coordinator.send(.failed(generation: coordinator.state.generation, message: error.localizedDescription)) }
            refresh()
        }
    }
    @objc private func setupAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    @objc private func acknowledge() {
        coordinator.send(.dismissError)
        showingHelp = false; refresh()
    }
    private func closeOverlay() {
        showingHelp = false
        if let error = coordinator.state.error {
            // Closing the popup does not acknowledge an uncertain send or unlock controls.
            dismissedError = error
        } else if coordinator.state.dictation != .idle || coordinator.state.scrollMode {
            coordinator.send(.intent(.cancel))
        }
        overlay.hide()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showHelp() {
        showingHelp.toggle()
        if showingHelp { overlay.show(Self.help + "\n\n" + voice.recognitionNotice) }
        else { overlay.hide() }
    }
    static let help = """
    Gamepad Terminal — focus an iTerm2 terminal pane first

    L1 / R1: previous / next tab
    D-pad: arrows (Accessibility permission required)
    L2 + D-pad: adjacent split pane
    X (×): Enter • Circle: Escape • Square: Tab
    L2 + Circle: Ctrl+C (never repeats)
    Triangle: read-only scrollback viewer; left stick pages actual buffer text
    X (×) / Circle close scrollback without sending a key
    Options: toggle this help overlay • Left stick: scroll help or transcript

    Hold R2 to dictate, release to transcribe. X (×) inserts reviewed text
    without Enter; release and press X (×) again to submit. Circle discards
    an uninserted draft; it cannot undo text already inserted.
    All unrelated actions are suppressed during dictation.
    Dictation stays pinned to the displayed session. Focus changes discard it.

    Start the bridge separately using the repository's bridge/README.md.
    Use the menu to enable controls, select a macOS microphone, and explicitly
    request Microphone/Speech and Accessibility permissions. Arrows fail closed
    if the accessibility tree cannot establish terminal content. Speech may
    use Apple servers. The controller's built-in microphone is unsupported on Mac.
    Lost action responses require inspecting the target and acknowledging the
    error in the menu. Actions are never retried automatically.
    """
    private func refreshDiagnostics() {
        setup?.showDiagnostics("R2: \(max(0, triggerLevel))% • Peak: \(triggerPeak)% • Presses: \(triggerPresses)\nLast R2 press: \(lastTriggerGate)\nLast voice step: \(lastVoiceStep)")
    }
    private func refresh() {
        guard status != nil else { return }
        status.button?.title = coordinator.state.enabled ? (coordinator.state.error == nil ? "🎮" : "🎮 !") : "🎮 ○"
        status.button?.toolTip = "Controller: \(controllerName ?? "disconnected") • Bridge: \(bridgeLabel) • \(recordingLabel)"
        if coordinator.state.dictation != .idle { lastVoiceStep = recordingLabel }
        refreshDiagnostics()
        setup?.update(enabled: coordinator.state.enabled, controller: controllerName, bridge: bridgeLabel,
                      voice: recordingLabel, audioInputs: voice.inputs, selectedInput: coordinator.selectedInput,
                      idle: coordinator.state.dictation == .idle, error: coordinator.state.error)
        if coordinator.state.error == nil { dismissedError = nil }
        if setup?.window?.isKeyWindow == true { overlay.hide(); return }
        if let error = coordinator.state.error {
            if dismissedError == error { overlay.hide() }
            else { overlay.show("Action stopped\n\n" + error + "\n\nClose hides this popup. Controls stay paused until you inspect the target and acknowledge the error in Setup.") }
            return
        }
        let target = coordinator.state.dictation.target
        if let target {
            let label = "Target: \(target.title)"
            var body = recordingLabel
            if case let .review(_, _, text) = coordinator.state.dictation { body += "\n\n" + text }
            if case .inserted = coordinator.state.dictation { body += "\nCircle ends review; text already inserted remains in the terminal." }
            overlay.show(label + "\n\n" + body)
        } else if let page = coordinator.scrollback {
            overlay.show("Read-only scrollback • \(page.target.title)\nLine \(page.firstLine)\nTriangle, X (×) or Circle closes\n\n" + page.lines.joined(separator: "\n"))
        } else if !showingHelp { overlay.hide() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        controller.stop(); overlay.hide()
        Task {
            await coordinator.shutdown()
            instance.release()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main enum GamepadTerminalMain {
    @MainActor static func main() {
        umask(0o077)
        do {
            let instance = try InstanceLock()
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate(instance: instance)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
