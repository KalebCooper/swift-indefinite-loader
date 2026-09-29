import Foundation

// MARK: - Errors

/// Errors produced by ``IndefiniteLoader`` itself, distinct from any error thrown by the wrapped
/// operation.
public enum IndefiniteLoaderError: Error, Equatable {
  /// The operation did not complete within the configured timeout.
  case timedOut
}

// MARK: - Protocol

/// A one-shot loader for non-observation-based UI state that hides brief delays and prevents
/// flicker on slow loads.
///
/// `IndefiniteLoader` drives `loading → loaded/failed` transitions when the source of truth is a
/// single async call (a fetch, a query, a computation), not a long-lived observable stream. It
/// enforces two timing rules so the UI feels calm:
///
/// 1. **Grace delay.** If the operation finishes within `delay` (default 0.8 s), the loading
///    indicator is never shown. Humans don't notice missing UI under about 800 ms.
/// 2. **Minimum duration.** If the loading indicator *was* shown, it stays visible for at least
///    `minimumDuration` (default 1.2 s) before transitioning to `.loaded` or `.failed`. This
///    prevents the jarring flash that happens when a load completes 50 ms after the delay elapses.
///
/// Cached data flows through the same pipeline: pass it via `updating:` and the consumer sees
/// `.loaded(data:updatingPhase:error:)` immediately, then a refreshed `.loaded` (or stale data
/// plus error) when the operation resolves.
///
/// ## Threading
///
/// The loader is `@MainActor`-bound because it drives UI state. The wrapped `operation` runs on the
/// global concurrent executor (off the main thread), so heavy CPU work inside it will not block
/// the main thread. Task-local values set by the caller are inherited and visible to `operation`.
/// The `loadState` callback is always invoked on the main actor.
///
/// ## Cancellation
///
/// `load(...)` cooperates with structured cancellation: if the caller's task is cancelled (for
/// example a SwiftUI `.task` on view disappear), or ``cancel()`` is called imperatively, the
/// in-flight operation is cancelled and the consumer's state is *rewound*:
///
/// - If `existingData` was supplied to `load(...)`, the consumer receives a final
///   `.loaded(data: existingData, updatingPhase: nil, error: nil)` callback: the cached value
///   stays visible with no updating indicator.
/// - For cold loads (no `existingData`), no callback is delivered. The consumer is responsible
///   for any post-cancel UI of its own.
///
/// ## Re-entry
///
/// Calling `load(...)` while a previous load is in flight cancels the previous load before
/// starting the new one. Stale callbacks are suppressed via an internal load identifier.
@MainActor
public protocol IndefiniteLoaderProtocol<T> {
  /// The value the operation produces.
  associatedtype T: Sendable

  /// Cancels any in-flight operation and rewinds the consumer's state.
  ///
  /// If a load was in progress and was started with `existingData`, the consumer receives a
  /// final `.loaded(data: existingData, updatingPhase: nil, error: nil)` callback before
  /// internal state is cleared. For cold loads (no `existingData`), no callback is delivered.
  /// Safe to call when no load is in progress.
  func cancel()

  /// Performs an async operation and drives a state callback through the delay and
  /// minimum-duration pipeline.
  ///
  /// - Parameters:
  ///   - existingData: Cached data to display immediately while the operation runs. When
  ///     non-nil the consumer first sees `.loaded(data: existingData, updatingPhase: .delayed,
  ///     error: nil)`. When nil the consumer first sees `.loading(phase: .delayed)`.
  ///   - operation: The async work to perform. Runs on the global concurrent executor, so it is
  ///     safe to do CPU-bound work without hopping off the main actor manually. Task-local values
  ///     from the caller are inherited. Must be `@Sendable`.
  ///   - loadState: Invoked on the main actor with each state transition. The loader holds
  ///     this closure for the duration of the load and clears it on completion or cancellation,
  ///     so consumers may capture `self` strongly without leaking.
  func load(
    updating existingData: T?,
    operation: @Sendable @escaping () async throws -> T,
    loadState: @MainActor @escaping (IndefiniteLoadState<T>) -> Void
  ) async
}

extension IndefiniteLoaderProtocol {
  /// Convenience for cold loads with no cached data. See ``load(updating:operation:loadState:)``.
  ///
  /// - Parameters:
  ///   - operation: The async work to perform.
  ///   - loadState: Invoked on the main actor with each state transition.
  public func load(
    operation: @Sendable @escaping () async throws -> T,
    loadState: @MainActor @escaping (IndefiniteLoadState<T>) -> Void
  ) async {
    await load(updating: nil, operation: operation, loadState: loadState)
  }
}

// MARK: - Production Implementation

/// The production ``IndefiniteLoaderProtocol``: one instance per load surface, held by whichever
/// object renders the load state.
///
/// Every sleep and every elapsed-time measurement goes through the injected `Clock`, so the timing
/// rules are driven by a ``MockClock`` in tests and by `ContinuousClock` in production.
@MainActor
public final class IndefiniteLoader<T: Sendable>: IndefiniteLoaderProtocol {
  private let clock: any Clock<Duration>
  private let delay: Duration
  private let minimumDuration: Duration
  private let timeout: Duration?

  private var activeLoadID: UUID?
  private var delayTimerTask: Task<Void, Never>?
  /// Cached data carried into the current load, used to (a) emit a stale-with-error state on
  /// failure and (b) rewind the consumer to a stable `.loaded(...)` state on cancellation.
  private var existingData: T?
  /// Non-nil exactly when the loading indicator is currently shown to the consumer.
  /// Started when the indicator was first emitted so `enforceMinimumDuration` can compute how much
  /// longer to keep it visible.
  private var indicatorStopwatch: Stopwatch?
  private var loadStateCallback: (@MainActor (IndefiniteLoadState<T>) -> Void)?
  private var operationTask: Task<T, any Error>?

  /// Creates a loader.
  ///
  /// - Parameters:
  ///   - clock: The clock the loader sleeps on and measures elapsed time with. Defaults to
  ///     `ContinuousClock`.
  ///   - delay: How long the operation may run before the loading indicator becomes visible.
  ///     The default of 0.8 s is calibrated to the human perception threshold for waiting UI.
  ///   - minimumDuration: How long the loading indicator stays visible *once shown*. Prevents
  ///     flicker when a load completes shortly after `delay` elapses. Default 1.2 s.
  ///   - timeout: Optional upper bound on the operation. When the operation exceeds this
  ///     duration the loader emits `.failed(IndefiniteLoaderError.timedOut)` (or `.loaded`
  ///     with the timeout error if `existingData` was supplied). `nil` disables the timeout.
  public init(
    clock: any Clock<Duration> = ContinuousClock(),
    delay: Duration = .milliseconds(800),
    minimumDuration: Duration = .milliseconds(1200),
    timeout: Duration? = nil
  ) {
    self.clock = clock
    self.delay = delay
    self.minimumDuration = minimumDuration
    self.timeout = timeout
  }

  /// Cancels any in-flight operation and rewinds the consumer's state.
  ///
  /// See ``IndefiniteLoaderProtocol/cancel()`` for the rewind contract.
  public func cancel() {
    let hadActiveLoad: Bool = activeLoadID != nil
    let cached: T? = existingData
    let callback: (@MainActor (IndefiniteLoadState<T>) -> Void)? = loadStateCallback
    clearState()
    if hadActiveLoad, let cached {
      callback?(.loaded(data: cached, updatingPhase: nil, error: nil))
    }
  }

  /// Cancels in-flight tasks and resets all internal state without emitting a callback. Used
  /// at the top of ``load(updating:operation:loadState:)`` for re-entry: the new load's initial
  /// state is emitted immediately after, so a rewind here would be wasted work.
  private func clearState() {
    activeLoadID = nil
    delayTimerTask?.cancel()
    operationTask?.cancel()
    delayTimerTask = nil
    existingData = nil
    indicatorStopwatch = nil
    loadStateCallback = nil
    operationTask = nil
  }

  /// Performs an async operation and drives a state callback through the delay and
  /// minimum-duration pipeline.
  ///
  /// See ``IndefiniteLoaderProtocol/load(updating:operation:loadState:)`` for the full contract.
  ///
  /// - Parameters:
  ///   - existingData: Cached data to display immediately while the operation runs.
  ///   - operation: The async work to perform, run off the main actor.
  ///   - loadState: Invoked on the main actor with each state transition.
  public func load(
    updating existingData: T?,
    operation: @Sendable @escaping () async throws -> T,
    loadState: @MainActor @escaping (IndefiniteLoadState<T>) -> Void
  ) async {
    clearState()

    let loadID: UUID = UUID()
    activeLoadID = loadID
    self.existingData = existingData
    loadStateCallback = loadState

    // Centralizes the rewind-on-caller-cancellation contract. Fires for any early return
    // path where (a) we're still the active load and (b) the caller's task is cancelled.
    // External `cancel()` already emits its own rewind and flips activeLoadID, so this defer
    // naturally skips that case.
    defer {
      if activeLoadID == loadID && Task.isCancelled {
        cancel()
      }
    }

    if let existingData {
      loadState(.loaded(data: existingData, updatingPhase: .delayed, error: nil))
    } else {
      loadState(.loading(phase: .delayed))
    }

    // Bail if the consumer cancelled (or restarted) the loader from inside the initial emit.
    guard activeLoadID == loadID else { return }

    let clock: any Clock<Duration> = self.clock
    let timeout: Duration? = self.timeout
    let operationTask: Task<T, any Error> = Task {
      try await Self.runOperation(operation, timeout: timeout, clock: clock)
    }
    self.operationTask = operationTask

    let delay: Duration = self.delay
    delayTimerTask = Task { [weak self] in
      do { try await clock.sleep(for: delay) } catch { return }
      self?.handleDelayExpired(loadID: loadID, existingData: existingData)
    }

    do {
      let result: T = try await withTaskCancellationHandler {
        try await operationTask.value
      } onCancel: {
        operationTask.cancel()
      }

      guard activeLoadID == loadID, !Task.isCancelled else { return }
      delayTimerTask?.cancel()
      guard await enforceMinimumDuration(loadID: loadID) else { return }

      loadState(.loaded(data: result, updatingPhase: nil, error: nil))
      finalize(loadID: loadID)
    } catch {
      guard activeLoadID == loadID, !Task.isCancelled else { return }
      delayTimerTask?.cancel()
      guard await enforceMinimumDuration(loadID: loadID) else { return }

      if let existingData {
        loadState(.loaded(data: existingData, updatingPhase: nil, error: error))
      } else {
        loadState(.failed(error: error))
      }
      finalize(loadID: loadID)
    }
  }

  private func enforceMinimumDuration(loadID: UUID) async -> Bool {
    if let indicatorStopwatch {
      let remaining: Duration = minimumDuration - indicatorStopwatch.elapsed()
      if remaining > .zero {
        do { try await clock.sleep(for: remaining) } catch { return false }
        guard activeLoadID == loadID else { return false }
      }
    }
    return true
  }

  private func handleDelayExpired(loadID: UUID, existingData: T?) {
    guard activeLoadID == loadID else { return }

    let clock: any Clock<Duration> = self.clock
    indicatorStopwatch = Stopwatch.start(on: clock)

    if let existingData {
      loadStateCallback?(.loaded(data: existingData, updatingPhase: .active, error: nil))
    } else {
      loadStateCallback?(.loading(phase: .active))
    }
  }

  /// Runs the caller's operation on the global concurrent executor, optionally racing it against
  /// a timeout. Marked `@concurrent` so it hops off the main actor regardless of caller
  /// isolation; called from a non-detached `Task` so the caller's task-local values are
  /// inherited.
  @concurrent
  private static func runOperation(
    _ operation: @Sendable @escaping () async throws -> T,
    timeout: Duration?,
    clock: any Clock<Duration>
  ) async throws -> T {
    guard let timeout else {
      return try await operation()
    }
    return try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await operation() }
      group.addTask { () -> T in
        try await clock.sleep(for: timeout)
        throw IndefiniteLoaderError.timedOut
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else {
        throw IndefiniteLoaderError.timedOut
      }
      return result
    }
  }

  private func finalize(loadID: UUID) {
    guard activeLoadID == loadID else { return }
    activeLoadID = nil
    delayTimerTask = nil
    existingData = nil
    indicatorStopwatch = nil
    loadStateCallback = nil
    operationTask = nil
  }
}

// MARK: - Stopwatch

/// Measures the time elapsed since it was started, on a clock whose instant type is erased.
///
/// The loader holds its clock as `any Clock<Duration>`, whose `Instant` cannot be stored and later
/// subtracted without knowing the concrete clock. Starting the stopwatch opens the existential
/// once and keeps the start instant next to the clock it came from.
private struct Stopwatch {
  let elapsed: () -> Duration

  /// Starts a stopwatch at `clock`'s current reading. Passing an `any Clock<Duration>` opens it,
  /// so the start instant keeps its concrete type.
  static func start<C: Clock<Duration>>(on clock: C) -> Stopwatch {
    let start: C.Instant = clock.now
    return Stopwatch { start.duration(to: clock.now) }
  }
}
