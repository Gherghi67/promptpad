import AppKit
import PromptpadCore

/// A discoverable launch surface even when macOS hides crowded menu-bar items.
@MainActor final class SetupWindow: NSWindowController, NSWindowDelegate {
    var onToggle: (() -> Void)?
    var onVoice: (() -> Void)?
    var onAccessibility: (() -> Void)?
    var onAcknowledge: (() -> Void)?
    var onInput: ((String?) -> Void)?
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let diagnostics = NSTextField(wrappingLabelWithString: "R2: no input received yet")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let toggle = NSButton(title: "Enable controller", target: nil, action: nil)
    private let acknowledge = NSButton(title: "I inspected the target — acknowledge error", target: nil, action: nil)
    private let inputs = NSPopUpButton(frame: .zero, pullsDown: false)
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Promptpad — Setup"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        let title = NSTextField(labelWithString: "Your controller, your terminal")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(diagnostics)
        toggle.target = self; toggle.action = #selector(togglePressed)
        stack.addArrangedSubview(toggle)
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString:
            "Enable controls, then focus an iTerm2 pane. L1/R1 switch tabs; L2 + D-pad switches panes. Hold R2 to dictate. X (×) inserts your reviewed words; a separate press submits."))
        stack.addArrangedSubview(NSTextField(labelWithString: "Microphone"))
        inputs.target = self; inputs.action = #selector(inputChanged)
        stack.addArrangedSubview(inputs)
        let voice = NSButton(title: "Set up Microphone & Speech permissions…", target: self, action: #selector(voicePressed))
        stack.addArrangedSubview(voice)
        stack.addArrangedSubview(NSButton(title: "Set up Accessibility for hotkey windows & arrows…", target: self, action: #selector(accessibilityPressed)))
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString:
            "Use the Mac microphone or another macOS input; the DualSense microphone is unsupported on Mac. Apple Speech may process audio on Apple servers. The Python bridge must be running separately."))
        errorLabel.textColor = .systemRed
        stack.addArrangedSubview(errorLabel)
        acknowledge.target = self; acknowledge.action = #selector(acknowledgePressed)
        stack.addArrangedSubview(acknowledge)
        stack.addArrangedSubview(NSButton(title: "Quit Promptpad", target: NSApp, action: #selector(NSApplication.terminate(_:))))
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func present() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func update(enabled: Bool, controller: String?, bridge: String, voice: String,
                audioInputs: [AudioInput], selectedInput: String?, idle: Bool, error: String?) {
        toggle.title = enabled ? "Disable controller" : "Enable controller"
        statusLabel.stringValue = "Controller: \(controller ?? (enabled ? "Waiting for connection" : "Controls disabled"))\nBridge: \(bridge)\nVoice: \(voice)"
        inputs.removeAllItems()
        inputs.addItem(withTitle: "System default input")
        for input in audioInputs {
            inputs.addItem(withTitle: input.name)
            inputs.lastItem?.representedObject = input.id
        }
        if let selectedInput,
           let item = inputs.itemArray.first(where: { $0.representedObject as? String == selectedInput }) {
            inputs.select(item)
        } else if let selectedInput {
            inputs.addItem(withTitle: "Selected microphone unavailable")
            inputs.lastItem?.representedObject = selectedInput
            inputs.select(inputs.lastItem)
        }
        inputs.isEnabled = idle
        errorLabel.stringValue = error ?? ""
        errorLabel.isHidden = error == nil; acknowledge.isHidden = error == nil
    }
    func showDiagnostics(_ message: String) { diagnostics.stringValue = message }
    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
    @objc private func togglePressed() { onToggle?() }
    @objc private func voicePressed() { onVoice?() }
    @objc private func accessibilityPressed() { onAccessibility?() }
    @objc private func acknowledgePressed() { onAcknowledge?() }
    @objc private func inputChanged() { onInput?(inputs.selectedItem?.representedObject as? String) }
}
