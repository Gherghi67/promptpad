import Foundation

public enum ControllerButton: String, CaseIterable, Sendable {
    case cross, circle, square, triangle, l1, r1, up, down, left, right, options
}

public enum ControllerEvent: Equatable, Sendable {
    case button(ControllerButton, pressed: Bool)
    case leftTrigger(Float)
    case rightTrigger(Float)
    case stickY(Float)
    /// Monotonic seconds, e.g. ProcessInfo.processInfo.systemUptime.
    case tick
}

public enum ControllerIntent: Equatable, Sendable {
    case terminal(TerminalAction)
    case confirm, cancel, dictationPressed, dictationReleased, showHelp
    case scrollModeChanged(Bool)
}

public enum InputPolicy {
    public static let stickDeadZone: Float = 0.25
    public static let triggerPress: Float = 0.65
    public static let triggerRelease: Float = 0.35
    public static let repeatDelay: TimeInterval = 0.4
    public static let repeatInterval: TimeInterval = 0.125 // at most eight per second
    public static let scrollStep = 8
}

/// Feed every event, even while gated, so reopening the gate cannot synthesize an edge.
/// Call setGate(false) on focus/connection/enable changes and during voice work.
public struct ControllerMapper: Sendable {
    public private(set) var isScrollMode = false
    public private(set) var gateOpen = false
    public private(set) var ordinaryActionsEnabled = true
    private var held: Set<ControllerButton> = []
    private var inhibitedButtons: Set<ControllerButton> = []
    private var leftTriggerHeld = false
    private var rightTriggerHeld = false
    private var stickDirection = 0
    private var repeating: (button: ControllerButton?, intent: ControllerIntent, next: TimeInterval)?

    public init() {}

    public mutating func setGate(_ open: Bool) {
        gateOpen = open
        if !open { repeating = nil; isScrollMode = false }
    }

    /// During voice work keep Cross/Circle and trigger release live, but drop navigation,
    /// mode toggles, and repeats. Reopening never replays a held input.
    public mutating func setOrdinaryActionsEnabled(_ enabled: Bool) {
        ordinaryActionsEnabled = enabled
        if !enabled { repeating = nil; isScrollMode = false }
    }

    /// Synchronize after reducer changes, including Cross/Circle closing the viewer.
    public mutating func setScrollMode(_ active: Bool) {
        if active != isScrollMode { repeating = nil }
        isScrollMode = active && gateOpen && ordinaryActionsEnabled
    }

    /// After reconnect require R2 release before another recording can begin.
    public mutating func disconnected() {
        setGate(false); held.removeAll(); leftTriggerHeld = false
        inhibitedButtons = Set(ControllerButton.allCases)
        rightTriggerHeld = true; stickDirection = 0
    }

    public mutating func handle(_ event: ControllerEvent, at now: TimeInterval) -> [ControllerIntent] {
        guard now.isFinite else { return [] }
        switch event {
        case let .button(button, pressed):
            let wasHeld = held.contains(button)
            if pressed { held.insert(button) } else { held.remove(button) }
            if inhibitedButtons.contains(button) {
                if !pressed { inhibitedButtons.remove(button) }
                return []
            }
            if !pressed {
                if repeating?.button == button { repeating = nil }
                return []
            }
            guard !wasHeld, gateOpen else { return [] }
            guard ordinaryActionsEnabled || button == .cross || button == .circle else { return [] }
            let intent: ControllerIntent
            switch button {
            case .cross: intent = .confirm
            case .circle: intent = leftTriggerHeld ? .terminal(.control(.interrupt)) : .cancel
            case .square: intent = .terminal(.control(.tab))
            case .triangle:
                isScrollMode.toggle(); repeating = nil
                return [.scrollModeChanged(isScrollMode)]
            case .options: intent = .showHelp
            case .l1: intent = .terminal(.selectTab(.previous))
            case .r1: intent = .terminal(.selectTab(.next))
            case .up, .down, .left, .right:
                let direction: Direction = switch button {
                case .up: .up; case .down: .down; case .left: .left; default: .right
                }
                intent = .terminal(leftTriggerHeld ? .selectPane(direction) : .arrow(direction))
            }
            switch button {
            case .up, .down, .left, .right, .l1, .r1:
                repeating = (button, intent, now + InputPolicy.repeatDelay)
            default: break // no repeated confirm, interrupt, Escape, or Tab
            }
            return [intent]
        case let .leftTrigger(value):
            guard value.isFinite else { return [] }
            let next = hysteresis(value, held: leftTriggerHeld)
            if next != leftTriggerHeld { repeating = nil }
            leftTriggerHeld = next
            return []
        case let .rightTrigger(value):
            guard value.isFinite else { return [] }
            let next = hysteresis(value, held: rightTriggerHeld)
            defer { rightTriggerHeld = next }
            guard next != rightTriggerHeld else { return [] }
            // Release must reach the reducer during recording even if action inputs are blocked.
            return next ? (gateOpen ? [.dictationPressed] : []) : [.dictationReleased]
        case let .stickY(value):
            guard value.isFinite else { return [] }
            let direction = abs(value) > InputPolicy.stickDeadZone ? (value > 0 ? 1 : -1) : 0
            defer { stickDirection = direction }
            guard direction != stickDirection else { return [] }
            if repeating?.button == nil { repeating = nil }
            guard gateOpen, ordinaryActionsEnabled, isScrollMode, direction != 0 else { return [] }
            let intent = ControllerIntent.terminal(.scrollback(deltaLines: direction * InputPolicy.scrollStep))
            repeating = (nil, intent, now + InputPolicy.repeatDelay)
            return [intent]
        case .tick:
            guard gateOpen, ordinaryActionsEnabled, var repeatState = repeating, now >= repeatState.next else { return [] }
            repeatState.next = now + InputPolicy.repeatInterval // no catch-up burst after a stall
            repeating = repeatState
            return [repeatState.intent]
        }
    }

    private func hysteresis(_ value: Float, held: Bool) -> Bool {
        held ? value > InputPolicy.triggerRelease : value >= InputPolicy.triggerPress
    }
}
