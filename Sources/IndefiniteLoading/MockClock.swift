import Synchronization

/// A `Clock` whose reading moves only when a test moves it, and whose sleeps end when the reading
/// reaches their deadline.
///
/// Two properties shape every test written against it:
///
/// 1. A sleep parks until ``advance(by:)`` moves the reading to or past its deadline, and not a
///    moment before. A sleep whose deadline the reading has already reached returns at once, so a
///    loader built with `delay: .zero` shows its indicator without the test advancing anything.
/// 2. The reading never moves on its own. ``IndefiniteLoader`` measures how long its indicator has
///    been visible in this clock's instants, so the time a test advances is the time the loader
///    sees.
///
/// ## Awaiting a Sleeper, Then Advancing
///
/// A sleeper registers on its own task, so advancing right after that task is spawned races the
/// registration: the reading moves before the sleeper computes its deadline.
/// ``waitForPendingSleep()`` returns once at least one sleeper is parked, which makes the sequence
/// deterministic:
///
/// ```swift
/// let clock = MockClock()
/// let loader = IndefiniteLoader<String>(clock: clock)
/// let (released, release) = AsyncStream<Void>.makeStream()
/// var states: [IndefiniteLoadState<String>] = []
///
/// let load = Task {
///   await loader.load {
///     for await _ in released {}
///     return "fresh"
///   } loadState: { states.append($0) }
/// }
///
/// await clock.waitForPendingSleep()
/// clock.advance(by: .milliseconds(800))
/// while states.count < 2 { await Task.yield() }
/// release.finish()
/// await clock.waitForPendingSleep()
/// clock.advance(by: .milliseconds(1200))
/// await load.value
/// ```
///
/// ## Isolation
///
/// One `Mutex` guards the reading and both registries, so the clock is safe to drive from one task
/// while others sleep on it. It is not an `actor`, so ``now`` and ``pendingSleepCount`` read
/// synchronously.
public final class MockClock: Clock, Sendable {
  /// A reading of a ``MockClock``: a distance from the reading the clock was created with.
  public struct Instant: InstantProtocol {
    fileprivate var offset: Duration

    /// The instant `duration` after this one.
    ///
    /// - Parameter duration: How far past this instant to move.
    /// - Returns: The later instant, or an earlier one for a negative `duration`.
    public func advanced(by duration: Duration) -> Instant {
      Instant(offset: offset + duration)
    }

    /// The duration from this instant to `other`.
    ///
    /// - Parameter other: The instant to measure to.
    /// - Returns: A positive duration when `other` is later, a negative one when it is earlier.
    public func duration(to other: Instant) -> Duration {
      other.offset - offset
    }

    /// Whether `lhs` comes before `rhs`.
    ///
    /// - Parameters:
    ///   - lhs: An instant.
    ///   - rhs: Another instant on the same clock.
    /// - Returns: `true` when `lhs` is the earlier of the two.
    public static func < (lhs: Instant, rhs: Instant) -> Bool {
      lhs.offset < rhs.offset
    }
  }

  private enum Registration {
    case cancelled
    case deadlineReached
    case parked(waiters: [CheckedContinuation<Void, Never>])
  }

  private struct Sleeper {
    let continuation: CheckedContinuation<Void, any Error>
    let deadline: Instant
  }

  private struct State {
    var nextID = 0
    var now = Instant(offset: .zero)
    var sleepers: [Int: Sleeper] = [:]
    var waiters: [CheckedContinuation<Void, Never>] = []

    mutating func claimID() -> Int {
      nextID += 1
      return nextID
    }
  }

  private let state = Mutex(State())

  /// Creates a clock with nobody sleeping, at the reading every later reading is measured from.
  public init() {}

  /// The smallest step the clock distinguishes: none, because deadlines are compared exactly.
  public var minimumResolution: Duration {
    .zero
  }

  /// The current reading, which changes only through ``advance(by:)``.
  public var now: Instant {
    state.withLock { $0.now }
  }

  /// How many tasks are parked in ``sleep(until:tolerance:)`` right now.
  public var pendingSleepCount: Int {
    state.withLock { $0.sleepers.count }
  }

  /// Moves the reading forward by `duration` and resumes every sleeper whose deadline the new
  /// reading reaches.
  ///
  /// Sleepers are resumed in deadline order; which resumed task runs first is the executor's
  /// decision. A sleeper whose deadline is still ahead stays parked.
  ///
  /// - Parameter duration: How far forward to move the reading.
  public func advance(by duration: Duration) {
    let released: [CheckedContinuation<Void, any Error>] = state.withLock { state in
      state.now = state.now.advanced(by: duration)
      let now = state.now
      let due = state.sleepers
        .filter { $0.value.deadline <= now }
        .sorted { ($0.value.deadline, $0.key) < ($1.value.deadline, $1.key) }
      for (id, _) in due {
        state.sleepers.removeValue(forKey: id)
      }
      return due.map(\.value.continuation)
    }
    for continuation in released {
      continuation.resume()
    }
  }

  /// Parks the calling task until ``advance(by:)`` moves the reading to or past `deadline`.
  ///
  /// Returns at once when the reading has already reached `deadline`.
  ///
  /// - Parameters:
  ///   - deadline: The reading at which the sleep ends.
  ///   - tolerance: Accepted and ignored; the sleep ends at `deadline` exactly.
  /// - Throws: `CancellationError` when the calling task is cancelled before or while parked.
  public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
    let id = state.withLock { $0.claimID() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        // The cancellation flag is read under the same lock the handler removes entries under, so a
        // cancellation that landed before this point is seen here, and one that lands after it
        // finds the entry to remove.
        let registration: Registration = state.withLock { state in
          guard !Task.isCancelled else { return .cancelled }
          guard deadline > state.now else { return .deadlineReached }
          state.sleepers[id] = Sleeper(continuation: continuation, deadline: deadline)
          let waiters = state.waiters
          state.waiters.removeAll()
          return .parked(waiters: waiters)
        }
        switch registration {
        case .cancelled:
          continuation.resume(throwing: CancellationError())
        case .deadlineReached:
          continuation.resume()
        case .parked(let waiters):
          for waiter in waiters {
            waiter.resume()
          }
        }
      }
    } onCancel: {
      let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
      sleeper?.continuation.resume(throwing: CancellationError())
    }
  }

  /// Suspends until at least one task is parked in ``sleep(until:tolerance:)``, returning at once
  /// when one already is.
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
