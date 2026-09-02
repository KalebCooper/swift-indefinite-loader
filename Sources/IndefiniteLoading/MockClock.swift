import Foundation
import Synchronization

/// A ``ClockProtocol`` whose reading moves only when a test moves it, and whose sleeps park until a
/// test releases them.
///
/// Two properties shape every test written against it:
///
/// 1. ``sleep(for:)`` **ignores the duration** and parks until ``advanceAllSleeps()`` is called,
///    `sleep(for: .zero)` included. A loader built with `delay: .zero` therefore never fires its
///    delay timer unless the test releases it.
/// 2. ``now()`` does **not** move when sleeps are released. ``IndefiniteLoader`` reads `now()` to
///    compute how long its indicator has been visible, so a minimum-duration test calls
///    ``advance(by:)`` *and* ``advanceAllSleeps()``, or the elapsed time computes as zero.
///
/// ## Awaiting a Sleeper, Then Releasing It
///
/// A sleeper registers on its own task, so releasing sleeps right after that task is spawned races
/// the registration. ``waitForPendingSleep()`` returns once at least one sleeper is parked, which
/// makes the sequence deterministic:
///
/// ```swift
/// let clock = MockClock()
/// let loader = IndefiniteLoader<String>(clock: clock)
/// let load = Task {
///   await loader.load { "fresh" } loadState: { recorder.record($0) }
/// }
/// await clock.waitForPendingSleep()
/// clock.advance(by: .seconds(0.8))
/// clock.advanceAllSleeps()
/// await load.value
/// ```
///
/// ## Isolation
///
/// One `Mutex` guards the reading and both registries, so the clock is safe to drive from one task
/// while others sleep on it. It is not an `actor`, so ``now()`` and ``pendingSleepCount`` read
/// synchronously.
public final class MockClock: ClockProtocol, Sendable {
  private struct State {
    var nextID = 0
    var now: Date
    var sleepers: [Int: CheckedContinuation<Void, any Error>] = [:]
    var waiters: [CheckedContinuation<Void, Never>] = []

    mutating func claimID() -> Int {
      nextID += 1
      return nextID
    }
  }

  private let state: Mutex<State>

  /// Creates a clock reading `now`, with nobody sleeping.
  ///
  /// - Parameter now: The initial reading. Defaults to the current date.
  public init(now: Date = Date()) {
    state = Mutex(State(now: now))
  }

  /// How many tasks are parked in ``sleep(for:)`` right now.
  public var pendingSleepCount: Int {
    state.withLock { $0.sleepers.count }
  }

  /// The current reading, which changes only through ``advance(by:)``.
  ///
  /// - Returns: The clock's reading.
  public func now() -> Date {
    state.withLock { $0.now }
  }

  /// Moves the reading forward by `duration`.
  ///
  /// Parked sleepers stay parked; only ``advanceAllSleeps()`` releases them.
  ///
  /// - Parameter duration: How far forward to move the reading.
  public func advance(by duration: Duration) {
    let seconds = Double(duration.components.seconds)
    let attoseconds = Double(duration.components.attoseconds) / 1e18
    state.withLock { $0.now = $0.now.addingTimeInterval(seconds + attoseconds) }
  }

  /// Resumes every task currently parked in ``sleep(for:)``.
  ///
  /// The reading does not move. Which resumed task runs first is the executor's decision.
  public func advanceAllSleeps() {
    let sleepers = state.withLock { state in
      let parked = state.sleepers
      state.sleepers.removeAll()
      return parked
    }
    for (_, continuation) in sleepers {
      continuation.resume()
    }
  }

  /// Parks the calling task until ``advanceAllSleeps()`` releases it, whatever `duration` says.
  ///
  /// - Parameter duration: Accepted and ignored; the sleep ends when the test releases it.
  /// - Throws: `CancellationError` when the calling task is cancelled before or while parked.
  public func sleep(for duration: Duration) async throws {
    let id = state.withLock { $0.claimID() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        // The cancellation flag is read under the same lock the handler removes entries under, so a
        // cancellation that landed before this point is seen here, and one that lands after it
        // finds the entry to remove.
        let (cancelled, waiters): (Bool, [CheckedContinuation<Void, Never>]) = state.withLock {
          state in
          guard !Task.isCancelled else { return (true, []) }
          state.sleepers[id] = continuation
          let waiters = state.waiters
          state.waiters.removeAll()
          return (false, waiters)
        }
        if cancelled {
          continuation.resume(throwing: CancellationError())
        }
        for waiter in waiters {
          waiter.resume()
        }
      }
    } onCancel: {
      let continuation = state.withLock { $0.sleepers.removeValue(forKey: id) }
      continuation?.resume(throwing: CancellationError())
    }
  }

  /// Suspends until at least one task is parked in ``sleep(for:)``, returning at once when one
  /// already is.
  ///
  /// A waiter is released inside the same critical section that registers the sleeper it waited
  /// for, so nothing polls and no real time passes.
  public func waitForPendingSleep() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let resumeNow: Bool = state.withLock { state in
        guard state.sleepers.isEmpty else { return true }
        state.waiters.append(continuation)
        return false
      }
      if resumeNow {
        continuation.resume()
      }
    }
  }
}
