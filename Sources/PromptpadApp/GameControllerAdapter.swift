import Foundation
@preconcurrency import GameController
import PromptpadCore

/// Hardware-independent snapshots also let tests simulate disconnects and held inputs.
struct ControllerSnapshot: Sendable {
    var buttons: Set<ControllerButton> = []
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0
    var stickY: Float = 0
    var events: [ControllerEvent] {
        [.leftTrigger(leftTrigger), .rightTrigger(rightTrigger)]
        + ControllerButton.allCases.map { .button($0, pressed: buttons.contains($0)) }
        + [.stickY(stickY), .tick]
    }
}

@MainActor final class GameControllerAdapter: ControllerEventSource {
    var onEvent: ((ControllerEvent) -> Void)?
    var onConnection: ((Bool, String?) -> Void)?
    private var sampling: Task<Void, Never>?
    private var controller: GCController?
    func start() {
        guard sampling == nil else { return }
        GCController.shouldMonitorBackgroundEvents = true
        sampling = Task { [weak self] in
            while !Task.isCancelled {
                self?.sampleHardware()
                do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
            }
        }
    }
    func stop() {
        sampling?.cancel(); sampling = nil
        controller = nil
        GCController.shouldMonitorBackgroundEvents = false
        onConnection?(false, nil)
    }
    private func sampleHardware() {
        let next = GCController.controllers().first { $0.extendedGamepad != nil }
        if next !== controller {
            // Even replacement by a second controller has a full disconnect boundary.
            onConnection?(false, nil)
            controller = next
            if let next { onConnection?(true, next.vendorName ?? "Game controller") }
        }
        guard let pad = controller?.extendedGamepad else { return }
        var snapshot = ControllerSnapshot()
        let buttons: [(ControllerButton, GCControllerButtonInput)] = [
            (.cross, pad.buttonA), (.circle, pad.buttonB), (.square, pad.buttonX), (.triangle, pad.buttonY),
            (.l1, pad.leftShoulder), (.r1, pad.rightShoulder), (.options, pad.buttonMenu),
            (.up, pad.dpad.up), (.down, pad.dpad.down), (.left, pad.dpad.left), (.right, pad.dpad.right)
        ]
        for (button, input) in buttons where input.isPressed { snapshot.buttons.insert(button) }
        snapshot.leftTrigger = pad.leftTrigger.value
        snapshot.rightTrigger = pad.rightTrigger.value
        snapshot.stickY = pad.leftThumbstick.yAxis.value
        deliver(snapshot)
    }
    func deliver(_ snapshot: ControllerSnapshot) { snapshot.events.forEach { onEvent?($0) } }
}
