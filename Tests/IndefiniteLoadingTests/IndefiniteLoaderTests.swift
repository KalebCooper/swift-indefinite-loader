import Foundation
import IndefiniteLoading
import Testing

/// A compact `Equatable` projection of `IndefiniteLoadState`, for sequence assertions on payloads
/// that aren't `Equatable` themselves (`Void`, in the submission configuration).
private enum StateShape: Equatable {
  case failed
  case loaded(updatingPhase: IndefiniteLoadingPhase?, hasError: Bool)
  case loading(phase: IndefiniteLoadingPhase)

  init<Payload>(_ state: IndefiniteLoadState<Payload>) {
    switch state {
    case .failed:
      self = .failed
    case .loaded(_, let updatingPhase, let error):
      self = .loaded(updatingPhase: updatingPhase, hasError: error != nil)
    case .loading(let phase):
      self = .loading(phase: phase)
    }
  }
}

/// Captures every state the loader emits, in order. The emitted *sequence* is the contract; a
/// final-state-only assertion would pass even if a spinner flashed on the way there.
@MainActor
private final class StateRecorder<Payload: Sendable> {
  private(set) var states: [IndefiniteLoadState<Payload>] = []

  /// How many emitted states would put a spinner on screen. The delay gate's whole promise is
  /// that this stays 0 for fast loads.
  var activeCount: Int {
    states.filter { $0.isLoadingOrUpdatingActive }.count
  }

  var shapes: [StateShape] {
    states.map(StateShape.init)
  }

  func record(_ state: IndefiniteLoadState<Payload>) {
    states.append(state)
  }
}

/// A one-shot, cancellation-aware gate used to hold an operation mid-flight and release it on cue.
///
/// Deliberately NOT clock-based: the loader's delay and minimum-duration sleeps live on `MockClock`,
/// so gating the operation there would make `advance(by:)` release the operation too; the test
/// could no longer control which side of the race wins, which is the only thing these tests
/// are here to measure. It must be cancellation-aware or the cancellation tests deadlock: `load`
/// awaits the operation task's value, so an operation that ignores cancellation never returns.
private struct OperationGate: Sendable {
  private let continuation: AsyncStream<Void>.Continuation
  private let stream: AsyncStream<Void>

  init() {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    self.continuation = continuation
    self.stream = stream
  }

  func open() {
    continuation.finish()
  }

  func wait() async throws {
    for await _ in stream {}
    try Task.checkCancellation()
  }
}

/// `IndefiniteLoader` proofs against `MockClock`. All time is driven through the clock
/// (`waitForPendingSleep()` awaits the loader parking in a sleep; `advance(by:)` moves the reading
/// and releases every sleep whose deadline it reaches). No wall-clock sleeps anywhere.
///
/// Two `MockClock` properties shape every test here:
/// 1. A sleep ends when the reading reaches its deadline, not a moment before, and a sleep whose
///    deadline has already been reached returns at once. A `delay: .zero` loader therefore shows
///    its indicator without the test advancing anything.
/// 2. The reading never moves on its own. A sleeper computes its deadline from the reading when
///    it registers, so a test awaits the sleeper before advancing, or the deadline lands later
///    than the test assumes.
@MainActor
@Suite("IndefiniteLoader", .serialized)
struct IndefiniteLoaderTests {
  // MARK: - Grace delay, the contract

  /// The core requirement, encoded. Note the final two assertions: without them this test would
  /// only prove that a timer the test never fired did not fire, a tautology that stays green even
  /// if `delayTimerTask?.cancel()` silently regressed.
  @Test("A cold load resolving inside the delay never emits .active")
  func coldLoadInsideDelayNeverEmitsActive() async {
    let clock = MockClock()
    let gate = OperationGate()
    let recorder = StateRecorder<String>()
    let sut = makeLoader(clock: clock, payload: String.self)

    let loadTask = Task {
      await sut.load {
        try await gate.wait()
        return "fresh"
      } loadState: {
        recorder.record($0)
      }
    }

    // The delay timer is armed and parked, so this test controls a REAL race rather than an
    // absent one. `.delayed` is emitted synchronously; nothing is rendered yet.
    await clock.waitForPendingSleep()
    #expect(recorder.states == [.loading(phase: .delayed)])

    // The operation wins: it resolves while the delay timer is still parked.
    gate.open()
    await loadTask.value

    #expect(
      recorder.states == [
        .loading(phase: .delayed),
        .loaded(data: "fresh", updatingPhase: nil, error: nil),
      ])
    #expect(recorder.activeCount == 0)

    // The delay timer's sleep is GONE, not merely unfired: `load` cancelled it on the success
    // path. This distinguishes "cancelled" from "never released by the test", and it is the
    // assertion that actually detects a missing `delayTimerTask?.cancel()`.
    #expect(clock.pendingSleepCount == 0)

    // Advancing past the delay deadline must still produce no `.active`. This does NOT catch a
    // missing `delayTimerTask?.cancel()` (`finalize()` clears `activeLoadID`, and
    // `handleDelayExpired` guards on it, so a late timer is suppressed anyway). It proves that
    // second, independent guard holds: defence in depth.
    clock.advance(by: .milliseconds(800))
    await drainReleasedWork()
    #expect(recorder.activeCount == 0)
  }

  @Test("A cold load running past the delay emits .delayed then .active, held for minimumDuration")
  func coldLoadPastDelayEmitsActiveAndHoldsIt() async {
    let clock = MockClock()
    let gate = OperationGate()
    let recorder = StateRecorder<String>()
    let sut = makeLoader(clock: clock, payload: String.self)

    let loadTask = Task {
      await sut.load {
        try await gate.wait()
        return "fresh"
      } loadState: {
        recorder.record($0)
      }
    }

    await clock.waitForPendingSleep()

    // Reaching the delay deadline releases the timer; the indicator is shown at this reading, and
    // the minimum-duration arithmetic below is measured from it.
    clock.advance(by: .milliseconds(800))
    await waitForStates(2, on: recorder)

    #expect(recorder.states == [.loading(phase: .delayed), .loading(phase: .active)])

    // The spinner has been up 0.5 s of its 1.2 s minimum when the operation resolves.
    clock.advance(by: .milliseconds(500))
    gate.open()

    // The loader parks in `enforceMinimumDuration`'s sleep instead of emitting the terminal
    // state. That parked sleep IS the hold: measured, not assumed.
    await clock.waitForPendingSleep()
    #expect(recorder.states.count == 2)

    // Reaching the remaining 0.7 s releases the hold.
    clock.advance(by: .milliseconds(700))
    await finish(loadTask) { recorder.states.count == 3 }

    #expect(
      recorder.states == [
        .loading(phase: .delayed),
        .loading(phase: .active),
        .loaded(data: "fresh", updatingPhase: nil, error: nil),
      ])
  }

  @Test("The indicator stays hidden one nanosecond short of the delay and shows at the delay")
  func indicatorShowsExactlyAtDelayDeadline() async {
    let clock = MockClock()
    let gate = OperationGate()
    let recorder = StateRecorder<String>()
    let sut = makeLoader(clock: clock, payload: String.self)

    let loadTask = Task {
      await sut.load {
        try await gate.wait()
        return "fresh"
      } loadState: {
        recorder.record($0)
      }
    }

    await clock.waitForPendingSleep()

    // The timer is still registered, not merely unscheduled: the reading has not reached its
    // deadline, so nothing was released.
    clock.advance(by: .milliseconds(800) - .nanoseconds(1))
    #expect(clock.pendingSleepCount == 1)
    #expect(recorder.states == [.loading(phase: .delayed)])

    clock.advance(by: .nanoseconds(1))
    await waitForStates(2, on: recorder)
    #expect(recorder.states == [.loading(phase: .delayed), .loading(phase: .active)])

    loadTask.cancel()
    await loadTask.value
  }

  /// The indicator is shown 200 ms after the delay deadline, so a hold measured from the deadline
  /// ends 200 ms early and a hold that restarts the full minimum when the operation resolves ends
  /// 500 ms late. Only a hold measured from the instant the indicator appeared ends exactly here.
  @Test("The hold ends minimumDuration after the instant the indicator was shown")
  func holdEndsMinimumDurationAfterIndicatorShown() async {
    let clock = MockClock()
    let gate = OperationGate()
    let recorder = StateRecorder<String>()
    let sut = makeLoader(clock: clock, payload: String.self)

    let loadTask = Task {
      await sut.load {
        try await gate.wait()
        return "fresh"
      } loadState: {
        recorder.record($0)
      }
    }

    await clock.waitForPendingSleep()
    clock.advance(by: .milliseconds(1000))
    await waitForStates(2, on: recorder)

    clock.advance(by: .milliseconds(500))
    gate.open()
    await clock.waitForPendingSleep()

    clock.advance(by: .milliseconds(700) - .nanoseconds(1))
    #expect(clock.pendingSleepCount == 1)
    #expect(recorder.states.count == 2)

    clock.advance(by: .nanoseconds(1))
    await finish(loadTask) { recorder.states.count == 3 }
    #expect(
      recorder.states == [
        .loading(phase: .delayed),
        .loading(phase: .active),
        .loaded(data: "fresh", updatingPhase: nil, error: nil),
      ])
  }

  // MARK: - Refresh over cached data

  @Test("A refresh inside the delay keeps cached data visible and never emits .active")
  func refreshInsideDelayNeverEmitsActive() async {
    let clock = MockClock()
    let gate = OperationGate()
    let recorder = StateRecorder<String>()
    let sut = makeLoader(clock: clock, payload: String.self)

    let loadTask = Task {
      await sut.load(updating: "cached") {
        try await gate.wait()
        return "fresh"
      } loadState: {
        recorder.record($0)
      }
    }

    await clock.waitForPendingSleep()
    #expect(recorder.states == [.loaded(data: "cached", updatingPhase: .delayed, error: nil)])

    gate.open()
    await loadTask.value

    #expect(
      recorder.states == [
        .loaded(data: "cached", updatingPhase: .delayed, error: nil),
        .loaded(data: "fresh", updatingPhase: nil, error: nil),
      ])
    #expect(recorder.activeCount == 0)

    // As in the cold case, the timer is cancelled rather than merely unfired.
    #expect(clock.pendingSleepCount == 0)

    clock.advance(by: .milliseconds(800))
    await drainReleasedWork()
    #expect(recorder.activeCount == 0)
  }

  @Test(
    "A refresh past the delay shows cached data with an .active updating phase, then the fresh value"
  )
  func refreshPastDelayEmitsActiveUpdatingPhase() async {
    let clock = MockClock()
    let gate = OperationGate()
    let recorder = StateRecorder<String>()
    let sut = makeLoader(clock: clock, payload: String.self)

    let loadTask = Task {
      await sut.load(updating: "cached") {
        try await gate.wait()
        return "fresh"
      } loadState: {
        recorder.record($0)
      }
    }

    await clock.waitForPendingSleep()
    clock.advance(by: .milliseconds(800))
    await waitForStates(2, on: recorder)

    #expect(
      recorder.states == [
        .loaded(data: "cached", updatingPhase: .delayed, error: nil),
        .loaded(data: "cached", updatingPhase: .active, error: nil),
      ])

    // Advancing past the full minimum BEFORE the operation resolves means `remaining <= .zero`,
    // so the terminal state emits without parking a second sleep.
    clock.advance(by: .milliseconds(1200))
    gate.open()
    await finish(loadTask) { recorder.states.count == 3 }

    #expect(
      recorder.states == [
        .loaded(data: "cached", updatingPhase: .delayed, error: nil),
        .loaded(data: "cached", updatingPhase: .active, error: nil),
        .loaded(data: "fresh", updatingPhase: nil, error: nil),
      ])
  }

  // MARK: - Failure

  @Test("A failure with cached data emits .loaded(cached, nil, error), not .failed")
  func failureWithCachedDataKeepsCachedData() async {
    let clock = MockClock()
    let gate = OperationGate()
    let recorder = StateRecorder<String>()
    let sut = makeLoader(clock: clock, payload: String.self)

    let loadTask = Task {
      await sut.load(updating: "cached") {
        try await gate.wait()
        throw TestError.boom
      } loadState: {
        recorder.record($0)
      }
    }

    await clock.waitForPendingSleep()
    gate.open()
    await loadTask.value

    #expect(recorder.states.count == 2)
    guard case .loaded(let data, let updatingPhase, let error) = recorder.states.last else {
      Issue.record("Expected `.loaded`, got \(String(describing: recorder.states.last))")
      return
    }
    #expect(data == "cached")
    #expect(updatingPhase == nil)
    #expect(error as? TestError == .boom)
  }

  @Test("A failure without cached data emits .failed(error)")
  func failureWithoutCachedDataEmitsFailed() async {
    let clock = MockClock()
    let gate = OperationGate()
    let recorder = StateRecorder<String>()
    let sut = makeLoader(clock: clock, payload: String.self)

    let loadTask = Task {
      await sut.load {
        try await gate.wait()
        throw TestError.boom
      } loadState: {
        recorder.record($0)
      }
    }

    await clock.waitForPendingSleep()
    gate.open()
    await loadTask.value

    #expect(recorder.states.count == 2)
    guard case .failed(let error) = recorder.states.last else {
      Issue.record("Expected `.failed`, got \(String(describing: recorder.states.last))")
      return
    }
    #expect(error as? TestError == .boom)
  }

  // MARK: - Cancellation

  @Test("Caller cancellation with cached data rewinds to .loaded(cached, nil, nil)")
  func cancellationWithCachedDataRewinds() async {
    let clock = MockClock()
    let gate = OperationGate()
    let recorder = StateRecorder<String>()
    let sut = makeLoader(clock: clock, payload: String.self)

    // The gate is never opened: cancellation, not completion, ends this load.
    let loadTask = Task {
      await sut.load(updating: "cached") {
        try await gate.wait()
        return "fresh"
      } loadState: {
        recorder.record($0)
      }
    }

    await clock.waitForPendingSleep()
    loadTask.cancel()
    await loadTask.value

    #expect(
      recorder.states == [
        .loaded(data: "cached", updatingPhase: .delayed, error: nil),
        .loaded(data: "cached", updatingPhase: nil, error: nil),
      ])
  }

  @Test("Caller cancellation on a cold load delivers no further callback")
  func cancellationColdDeliversNoFurtherCallback() async {
    let clock = MockClock()
    let gate = OperationGate()
    let recorder = StateRecorder<String>()
    let sut = makeLoader(clock: clock, payload: String.self)

    let loadTask = Task {
      await sut.load {
        try await gate.wait()
        return "fresh"
      } loadState: {
        recorder.record($0)
      }
    }

    await clock.waitForPendingSleep()
    loadTask.cancel()
    await loadTask.value

    #expect(recorder.states == [.loading(phase: .delayed)])
  }

  // MARK: - Re-entry

  @Test("Re-entry mid-flight fully suppresses the prior load's callbacks")
  func reEntrySuppressesPriorLoadCallbacks() async {
    let clock = MockClock()
    let firstGate = OperationGate()
    let firstRecorder = StateRecorder<String>()
    let secondRecorder = StateRecorder<String>()
    let sut = makeLoader(clock: clock, payload: String.self)

    let firstLoad = Task {
      await sut.load {
        try await firstGate.wait()
        return "first"
      } loadState: {
        firstRecorder.record($0)
      }
    }

    await clock.waitForPendingSleep()
    #expect(firstRecorder.states == [.loading(phase: .delayed)])

    // The second load re-enters while the first is parked; `clearState()` must orphan the first.
    let secondLoad = Task {
      await sut.load {
        "second"
      } loadState: {
        secondRecorder.record($0)
      }
    }
    await secondLoad.value

    // Releasing the first operation must not resurrect its callbacks.
    firstGate.open()
    await firstLoad.value

    #expect(firstRecorder.states == [.loading(phase: .delayed)])
    #expect(
      secondRecorder.states == [
        .loading(phase: .delayed),
        .loaded(data: "second", updatingPhase: nil, error: nil),
      ])
  }

  // MARK: - Submission configuration

  @Test(
    "The submission configuration (delay: .zero) emits .active at once, then holds minimumDuration"
  )
  func submissionConfigShowsSpinnerThenHoldsMinimumDuration() async {
    let clock = MockClock()
    let gate = OperationGate()
    let recorder = StateRecorder<Void>()
    let sut = makeLoader(
      clock: clock,
      delay: .zero,
      minimumDuration: .milliseconds(400),
      payload: Void.self
    )

    let loadTask = Task {
      await sut.load {
        try await gate.wait()
      } loadState: {
        recorder.record($0)
      }
    }

    // A zero delay's deadline is the reading it was armed at, so the timer returns at once and
    // `.active` follows `.delayed` without the test advancing anything.
    await waitForStates(2, on: recorder)
    #expect(recorder.shapes == [.loading(phase: .delayed), .loading(phase: .active)])

    gate.open()

    // Even though the operation is done, the terminal state is withheld: the spinner is held
    // so the tap feedback registers.
    await clock.waitForPendingSleep()
    #expect(recorder.shapes.count == 2)

    clock.advance(by: .milliseconds(400))
    await finish(loadTask) { recorder.shapes.count == 3 }

    #expect(
      recorder.shapes == [
        .loading(phase: .delayed),
        .loading(phase: .active),
        .loaded(updatingPhase: nil, hasError: false),
      ])
  }

  // MARK: - Timeout

  @Test("Exceeding the timeout fails with IndefiniteLoaderError.timedOut")
  func timeoutEmitsTimedOutFailure() async {
    let clock = MockClock()
    let gate = OperationGate()
    let recorder = StateRecorder<String>()
    // `minimumDuration: .zero` keeps the terminal emit off the sleep queue: once the delay timer
    // has fired, a non-zero minimum would park a third sleep and complicate the release order
    // without testing anything this case is about.
    let sut = makeLoader(
      clock: clock,
      minimumDuration: .zero,
      payload: String.self,
      timeout: .seconds(5)
    )

    // Never opened: the operation outlives its timeout.
    let loadTask = Task {
      await sut.load {
        try await gate.wait()
        return "fresh"
      } loadState: {
        recorder.record($0)
      }
    }

    // TWO sleeps are armed here: the delay timer, and the timeout race inside the operation.
    await waitForPendingSleeps(2, on: clock)
    clock.advance(by: .seconds(5))
    await finish(loadTask) { recorder.shapes.last == .failed }

    guard case .failed(let error) = recorder.states.last else {
      Issue.record("Expected `.failed`, got \(String(describing: recorder.states.last))")
      return
    }
    #expect(error as? IndefiniteLoaderError == .timedOut)
  }

  @Test("The timeout fires when the reading reaches it, not one nanosecond before")
  func timeoutFiresExactlyAtDeadline() async {
    let clock = MockClock()
    let gate = OperationGate()
    let recorder = StateRecorder<String>()
    let sut = makeLoader(
      clock: clock,
      minimumDuration: .zero,
      payload: String.self,
      timeout: .seconds(5)
    )

    let loadTask = Task {
      await sut.load {
        try await gate.wait()
        return "fresh"
      } loadState: {
        recorder.record($0)
      }
    }

    await waitForPendingSleeps(2, on: clock)

    // The delay timer's deadline is passed, the timeout's is not: only the timeout stays parked.
    clock.advance(by: .seconds(5) - .nanoseconds(1))
    await waitForStates(2, on: recorder)
    #expect(clock.pendingSleepCount == 1)
    #expect(recorder.shapes == [.loading(phase: .delayed), .loading(phase: .active)])

    clock.advance(by: .nanoseconds(1))
    await finish(loadTask) { recorder.shapes.count == 3 }
    guard case .failed(let error) = recorder.states.last else {
      Issue.record("Expected `.failed`, got \(String(describing: recorder.states.last))")
      return
    }
    #expect(error as? IndefiniteLoaderError == .timedOut)
  }

  // MARK: - Fixtures

  /// Upper bound on every yield-based wait below, so a genuine regression fails loudly instead of
  /// hanging a CI job until the suite-level timeout.
  private static let maximumYieldIterations = 10_000

  private enum TestError: Error, Equatable {
    case boom
  }

  /// Yields a bounded number of times to give whatever `advance(by:)` released room to run.
  ///
  /// The negative cases assert the *absence* of an `.active` state, so there is no count to poll
  /// for; only a drain can distinguish "never emitted" from "not scheduled yet".
  private func drainReleasedWork() async {
    for _ in 0..<Self.maximumYieldIterations {
      await Task.yield()
    }
  }

  /// Awaits `loadTask` once `condition` holds, bounded like every other wait here.
  ///
  /// A load parked on a deadline the test never reaches would hang a bare `await loadTask.value`.
  /// Cancelling first turns that regression into a failed wait and a returned task; once the load
  /// has already finished, the cancel is a no-op.
  private func finish(_ loadTask: Task<Void, Never>, once condition: () -> Bool) async {
    var iterations = 0
    while !condition() {
      guard iterations < Self.maximumYieldIterations else {
        Issue.record("Timed out waiting for the load to finish.")
        break
      }
      iterations += 1
      await Task.yield()
    }
    loadTask.cancel()
    await loadTask.value
  }

  private func makeLoader<Payload: Sendable>(
    clock: any Clock<Duration>,
    delay: Duration = .milliseconds(800),
    minimumDuration: Duration = .milliseconds(1200),
    payload: Payload.Type,
    timeout: Duration? = nil
  ) -> IndefiniteLoader<Payload> {
    IndefiniteLoader<Payload>(
      clock: clock, delay: delay, minimumDuration: minimumDuration, timeout: timeout)
  }

  /// Yields until `count` tasks are parked on `MockClock`. `waitForPendingSleep()` only guarantees
  /// at least one; the `timeout:` configuration arms two, and advancing before both are parked
  /// would move the reading under the late one and push its deadline past the test's advance.
  private func waitForPendingSleeps(_ count: Int, on clock: MockClock) async {
    await clock.waitForPendingSleep()
    while clock.pendingSleepCount < count {
      await Task.yield()
    }
  }

  /// Yields until `recorder` has captured `count` states.
  ///
  /// `advance(by:)` only resumes the delay timer's continuation; the emit happens later, in that
  /// task. A bare `Task.yield()` buys exactly one executor hop, which does not guarantee the
  /// resumed task ran. Waiting on the postcondition itself removes the scheduling assumption.
  private func waitForStates<Payload: Sendable>(
    _ count: Int,
    on recorder: StateRecorder<Payload>
  ) async {
    var iterations = 0
    while recorder.states.count < count {
      guard iterations < Self.maximumYieldIterations else {
        Issue.record("Timed out waiting for \(count) states; recorded \(recorder.states.count).")
        return
      }
      iterations += 1
      await Task.yield()
    }
  }
}

/// `MockClock` proofs for the guarantees the loader suite relies on but cannot observe directly.
@Suite("MockClock")
struct MockClockTests {
  @Test("Cancelling a parked sleeper throws CancellationError and unregisters it")
  func cancellingParkedSleeperThrowsAndUnregisters() async {
    let clock = MockClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    let sleeper = Task {
      try await clock.sleep(until: deadline)
    }

    await clock.waitForPendingSleep()
    sleeper.cancel()
    await #expect(throws: CancellationError.self) {
      try await sleeper.value
    }
    #expect(clock.pendingSleepCount == 0)

    // Reaching the cancelled deadline resumes nothing: a second resume of the same continuation
    // would trap.
    clock.advance(by: .seconds(2))
    #expect(clock.now == deadline.advanced(by: .seconds(1)))
  }
}
