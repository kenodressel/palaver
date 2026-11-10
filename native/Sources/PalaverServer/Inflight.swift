// The changes (POSTs) the server is making now (webapp/process.py:91-135), so a stop lets them
// finish (`waitIdle`, DRAIN_SECONDS). A request that only waits for the language model's job
// (`detached`) is not one: the job is the app's and survives a restart.
//
// A POST is counted from the moment its head is accepted, while its body still arrives (an import
// may take a while), until its answer is out: the count is a `Ticket` the connection takes on the
// event loop and hands to the route's thread (`adopt`), where `detached` finds it, as Python's
// thread-local flag.
import Foundation

public final class Inflight: @unchecked Sendable {
    private let cond = NSCondition()
    private var running = 0
    /// Per thread (every request has its own): the ticket this thread's change is counted by.
    private var key: String { "palaver.inflight.\(ObjectIdentifier(self).hashValue)" }

    /// One counted change. `leave` and `reenter` are idempotent: a ticket counts once at most.
    public final class Ticket: @unchecked Sendable {
        private let owner: Inflight
        fileprivate var counted = false

        fileprivate init(_ owner: Inflight) { self.owner = owner }

        public func leave() {
            owner.cond.lock()
            if counted {
                counted = false
                owner.running -= 1
                owner.cond.broadcast()
            }
            owner.cond.unlock()
        }

        public func reenter() {
            owner.cond.lock()
            if !counted {
                counted = true
                owner.running += 1
            }
            owner.cond.unlock()
        }

        public var isCounted: Bool { owner.cond.lock(); defer { owner.cond.unlock() }; return counted }
    }

    public init() {}

    public var count: Int { cond.lock(); defer { cond.unlock() }; return running }

    private var current: Ticket? {
        get { Thread.current.threadDictionary[key] as? Ticket }
        set { Thread.current.threadDictionary[key] = newValue }
    }

    /// A change starts now (counted until its ticket leaves).
    public func enter() -> Ticket {
        let t = Ticket(self)
        t.reenter()
        return t
    }

    /// `body` on this thread as part of `ticket`'s change: `detached` inside it leaves the count.
    public func adopt<T>(_ ticket: Ticket, _ body: () throws -> T) rethrows -> T {
        let before = current
        current = ticket
        defer { current = before }
        return try body()
    }

    /// `with inflight.change():`
    public func change<T>(_ body: () throws -> T) rethrows -> T {
        let ticket = enter()
        defer { ticket.leave() }
        return try adopt(ticket, body)
    }

    /// `with inflight.detached():` inside a change: not counted while `body` runs.
    public func detached<T>(_ body: () throws -> T) rethrows -> T {
        guard let ticket = current, ticket.isCounted else { return try body() }
        ticket.leave()
        defer { ticket.reenter() }
        return try body()
    }

    /// True once no change runs; false when `timeout` seconds passed first.
    @discardableResult
    public func waitIdle(timeout: Double) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        cond.lock()
        defer { cond.unlock() }
        while running > 0 {
            if !cond.wait(until: deadline) { return running <= 0 }
        }
        return true
    }
}
