import Foundation

public struct PushToTalk {
    public enum Event {
        case optionDown, optionUp, escape, tick
    }

    public enum Command: Equatable {
        case start, finish, cancel, discard, enterHandsFree
    }

    /// Presses shorter than this are treated as accidental taps.
    public static let minimumHoldDuration: TimeInterval = 0.3
    /// A second press this soon after releasing a short tap starts hands-free mode.
    public static let doubleTapWindow: TimeInterval = 0.4
    /// Hands-free recordings finish on their own after this long.
    public static let handsFreeLimit: TimeInterval = 5 * 60

    private enum State {
        case idle(lastTapAt: TimeInterval?)
        case holding(since: TimeInterval)
        case handsFree(since: TimeInterval, keyHeld: Bool)
    }

    private var state = State.idle(lastTapAt: nil)

    public var isRecording: Bool {
        if case .idle = state { false } else { true }
    }

    public init() {}

    public mutating func handle(_ event: Event, at time: TimeInterval) -> [Command] {
        switch (state, event) {
        case (.idle(let lastTapAt), .optionDown):
            if let lastTapAt, time - lastTapAt <= Self.doubleTapWindow {
                state = .handsFree(since: time, keyHeld: true)
                return [.start, .enterHandsFree]
            }
            state = .holding(since: time)
            return [.start]
        case (.holding(let since), .optionUp):
            if time - since < Self.minimumHoldDuration {
                state = .idle(lastTapAt: time)
                return [.discard]
            }
            state = .idle(lastTapAt: nil)
            return [.finish]
        case (.handsFree(let since, keyHeld: true), .optionUp):
            state = .handsFree(since: since, keyHeld: false)
            return []
        case (.handsFree(_, keyHeld: false), .optionDown):
            state = .idle(lastTapAt: nil)
            return [.finish]
        case (.holding, .escape), (.handsFree, .escape):
            state = .idle(lastTapAt: nil)
            return [.cancel]
        case (.handsFree(let since, _), .tick) where time - since >= Self.handsFreeLimit:
            state = .idle(lastTapAt: nil)
            return [.finish]
        default:
            return []
        }
    }
}
