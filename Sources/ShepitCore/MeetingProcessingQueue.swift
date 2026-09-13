import Foundation

/// Decides when stopped meetings are processed: one at a time, in the order they stopped,
/// and never while a new meeting is being recorded.
///
/// Processing can't be slowed down from outside, so a recording that starts mid-job pauses it:
/// the running job is interrupted, goes back to the front of the queue, and runs again after Stop.
public struct MeetingProcessingQueue<Job: Equatable> {
    public enum Event: Equatable {
        /// A meeting stopped and waits to be processed.
        case enqueued(Job)
        case recordingStarted
        case recordingStopped
        /// The job ran to the end, successfully or not.
        case finished(Job)
        /// The job stopped after `interrupt`, leaving its remaining work undone.
        case interrupted(Job)
    }

    public enum Command: Equatable {
        case run(Job)
        /// Stop the running job as soon as possible and report `interrupted`.
        case interrupt(Job)
    }

    private var pending: [Job] = []
    private var running: Job?
    /// Set once `interrupt` was sent for `running`, so it isn't sent twice.
    private var interrupting = false
    private var recording = false

    public init() {}

    /// True while any meeting is waiting or being processed.
    public var hasWork: Bool { running != nil || !pending.isEmpty }

    /// Meetings waiting or being processed, including a paused one.
    public var count: Int { pending.count + (running == nil ? 0 : 1) }

    public var isPaused: Bool { recording && hasWork }

    public mutating func handle(_ event: Event) -> [Command] {
        switch event {
        case .enqueued(let job):
            pending.append(job)
        case .recordingStarted:
            recording = true
            if let running, !interrupting {
                interrupting = true
                return [.interrupt(running)]
            }
            return []
        case .recordingStopped:
            recording = false
        case .finished(let job):
            guard job == running else { return [] }
            running = nil
            interrupting = false
        case .interrupted(let job):
            guard job == running else { return [] }
            running = nil
            interrupting = false
            pending.insert(job, at: 0)
        }
        return runNext()
    }

    private mutating func runNext() -> [Command] {
        guard !recording, running == nil, !pending.isEmpty else { return [] }
        let job = pending.removeFirst()
        running = job
        return [.run(job)]
    }
}
