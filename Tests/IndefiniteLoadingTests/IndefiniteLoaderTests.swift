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
/// so gating the operation there would make `advanceAllSleeps()` release the operation too; the
/// test could no longer control which side of the race wins, which is the only thing these tests
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
/// (`waitForPendingSleep()` awaits the loader parking in a sleep; `advance(by:)` moves `now()`;
/// `advanceAllSleeps()` releases parked sleeps). No wall-clock sleeps anywhere.
///
/// Two `MockClock` properties shape every test here and are easy to get wrong:
/// 1. `sleep(for:)` **ignores the duration** and parks until `advanceAllSleeps()`, including
///    `sleep(for: .zero)`. A `delay: .zero` loader therefore never fires its delay timer unless
///    the test releases it explicitly.
/// 2. `now()` does **not** auto-advance when sleeps are released. `enforceMinimumDuration` reads
///    `clock.now()`, so a minimum-duration test must `advance(by:)` *and* `advanceAllSleeps()`, or
///    `elapsed` computes as 0.
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

    // Releasing every sleep must still produce no `.active`. This does NOT catch a missing
    // `delayTimerTask?.cancel()` (`finalize()` clears `activeLoadID`, and `handleDelayExpired`
    // guards on it, so a late timer is suppressed anyway). It proves that second, independent
    // guard holds: defence in depth.
    clock.advanceAllSleeps()
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

    // `now()` must advance too: `handleDelayExpired` stamps `loadingShownAt = clock.now()`, and
    // the minimum-duration arithmetic below is computed from it.
    clock.advance(by: .seconds(0.8))
    clock.advanceAllSleeps()
    await waitForStates(2, on: recorder)

    #expect(recorder.states == [.loading(phase: .delayed), .loading(phase: .active)])

    // The spinner has been up 0.5 s of its 1.2 s minimum when the operation resolves.
    clock.advance(by: .seconds(0.5))
    gate.open()

    // The loader parks in `enforceMinimumDuration`'s sleep instead of emitting the terminal
    // state. That parked sleep IS the hold: measured, not assumed.
    await clock.waitForPendingSleep()
    #expect(recorder.states.count == 2)

    // Release the remaining 0.7 s.
    clock.advance(by: .seconds(0.7))
    clock.advanceAllSleeps()
    await loadTask.value

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

    clock.advanceAllSleeps()
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
    clock.advance(by: .seconds(0.8))
    clock.advanceAllSleeps()
    await waitForStates(2, on: recorder)

    #expect(
      recorder.states == [
        .loaded(data: "cached", updatingPhase: .delayed, error: nil),
        .loaded(data: "cached", updatingPhase: .active, error: nil),
      ])

    // Advancing past the full minimum BEFORE the operation resolves means `remaining <= .zero`,
    // so the terminal state emits without parking a second sleep.
    clock.advance(by: .seconds(1.2))
    gate.open()
    await loadTask.value

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
    "The submission configuration (delay: .zero) emits .active once released, then holds minimumDuration"
  )
  func submissionConfigShowsSpinnerThenHoldsMinimumDuration() async {
    let clock = MockClock()
    let gate = OperationGate()
    let recorder = StateRecorder<Void>()
    let sut = makeLoader(
      clock: clock,
      delay: .zero,
      minimumDuration: .seconds(0.4),
      payload: Void.self
    )

    let loadTask = Task {
      await sut.load {
        try await gate.wait()
      } loadState: {
        recorder.record($0)
      }
    }

    // `MockClock.sleep(for:)` ignores the duration, so `.zero` parks exactly like `.seconds(0.8)`
    // and `.active` cannot fire until the test releases it. Asserting `.delayed` alone here is
    // the empirical proof of that trap, rather than a claim about it.
    await clock.waitForPendingSleep()
    #expect(recorder.shapes == [.loading(phase: .delayed)])

    clock.advanceAllSleeps()
    await waitForStates(2, on: recorder)
    #expect(recorder.shapes == [.loading(phase: .delayed), .loading(phase: .active)])

    gate.open()

    // Even though the operation is done, the terminal state is withheld: the spinner is held
    // so the tap feedback registers.
    await clock.waitForPendingSleep()
    #expect(recorder.shapes.count == 2)

    clock.advance(by: .seconds(0.4))
    clock.advanceAllSleeps()
    await loadTask.value

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
    clock.advanceAllSleeps()
    await loadTask.value

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

  /// Yields a bounded number of times to give whatever `advanceAllSleeps()` released room to run.
  ///
  /// The negative cases assert the *absence* of an `.active` state, so there is no count to poll
  /// for; only a drain can distinguish "never emitted" from "not scheduled yet".
  private func drainReleasedWork() async {
    for _ in 0..<Self.maximumYieldIterations {
      await Task.yield()
    }
  }

  private func makeLoader<Payload: Sendable>(
    clock: any ClockProtocol,
    delay: Duration = .seconds(0.8),
    minimumDuration: Duration = .seconds(1.2),
    payload: Payload.Type,
    timeout: Duration? = nil
  ) -> IndefiniteLoader<Payload> {
    IndefiniteLoader<Payload>(
      clock: clock, delay: delay, minimumDuration: minimumDuration, timeout: timeout)
  }

  /// Yields until `count` tasks are parked in `MockClock.sleep(for:)`. `waitForPendingSleep()` only
  /// guarantees at least one; the `timeout:` configuration arms two, and releasing them before both
  /// are parked would strand one and hang the test.
  private func waitForPendingSleeps(_ count: Int, on clock: MockClock) async {
    await clock.waitForPendingSleep()
    while clock.pendingSleepCount < count {
      await Task.yield()
    }
  }

  /// Yields until `recorder` has captured `count` states.
  ///
  /// `advanceAllSleeps()` only resumes the delay timer's continuation; the emit happens later, in
  /// that task. A bare `Task.yield()` buys exactly one executor hop, which does not guarantee the
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
