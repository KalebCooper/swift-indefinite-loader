# Testing

Drive the loader with `MockClock` and assert the sequence of states it emits.

## Overview

``IndefiniteLoader`` sleeps on, and measures elapsed time with, the clock passed to
``IndefiniteLoader/init(clock:delay:minimumDuration:timeout:)``. A test passes a ``MockClock`` and
owns time: the reading moves only when the test calls ``MockClock/advance(by:)``, so every timing
rule is checked at the exact instant it applies, and no test waits on wall time.

The emitted *sequence* is the contract. A final-state-only assertion would pass even if a spinner
flashed on the way there, so record every state and compare the whole list.

## How the Clock Keeps Time

Two properties of ``MockClock`` shape every test written against it:

1. **A sleep ends at its deadline, not before.** A sleeper parks until
   ``MockClock/advance(by:)`` moves the reading to or past its deadline. A sleep whose deadline the
   reading has already reached returns at once, so a loader built with `delay: .zero` shows its
   indicator without the test advancing anything.
2. **The reading never moves on its own.** The loader measures how long its indicator has been
   visible in the clock's instants, so the time a test advances is the time the loader sees. A
   sleeper computes its deadline from the reading when it registers, which means a test awaits the
   sleeper with ``MockClock/waitForPendingSleep()`` before advancing. Advancing first moves the
   reading under a sleeper that has not registered yet, and its deadline lands later than the test
   assumes.

## Holding an Operation Mid-Flight

To decide which side of the race resolves first, the operation has to wait for something the clock
does not control. Gating it on the clock would let ``MockClock/advance(by:)`` release the operation
along with the timers. A one-shot gate built on `AsyncStream` keeps the two apart:

```swift
struct OperationGate: Sendable {
  private let continuation: AsyncStream<Void>.Continuation
  private let stream: AsyncStream<Void>

  init() {
    (stream, continuation) = AsyncStream<Void>.makeStream()
  }

  func open() { continuation.finish() }

  func wait() async throws {
    for await _ in stream {}
    try Task.checkCancellation()
  }
}
```

The `checkCancellation` matters: `load` awaits the operation, so an operation that ignores
cancellation would hang a cancellation test.

## A Load Inside the Delay

Hold the operation until the delay timer is parked, then let the operation win:

```swift
import IndefiniteLoading
import Testing

@MainActor
@Test func aFastLoadNeverShowsTheSpinner() async {
  let clock = MockClock()
  let gate = OperationGate()
  let loader = IndefiniteLoader<String>(clock: clock)
  var states: [IndefiniteLoadState<String>] = []

  let load = Task {
    await loader.load {
      try await gate.wait()
      return "fresh"
    } loadState: { states.append($0) }
  }

  await clock.waitForPendingSleep()
  gate.open()
  await load.value

  #expect(states == [
    .loading(phase: .delayed),
    .loaded(data: "fresh", updatingPhase: nil, error: nil),
  ])
  #expect(clock.pendingSleepCount == 0)
}
```

Waiting for the parked timer before opening the gate makes the race real rather than absent. The
last expectation is the one with teeth: the timer's sleep is gone, not merely unfired, because the
loader cancelled it on its way out.

## A Load Past the Delay

Advance the reading to each deadline in turn, awaiting every sleeper before moving past it:

```swift
@MainActor
@Test func aSlowLoadShowsTheSpinnerAndHoldsIt() async {
  let clock = MockClock()
  let gate = OperationGate()
  let loader = IndefiniteLoader<String>(clock: clock)
  var states: [IndefiniteLoadState<String>] = []

  let load = Task {
    await loader.load {
      try await gate.wait()
      return "fresh"
    } loadState: { states.append($0) }
  }

  await clock.waitForPendingSleep()
  clock.advance(by: .milliseconds(800))
  while states.count < 2 { await Task.yield() }
  #expect(states == [.loading(phase: .delayed), .loading(phase: .active)])

  clock.advance(by: .milliseconds(500))
  gate.open()
  await clock.waitForPendingSleep()
  #expect(states.count == 2)

  clock.advance(by: .milliseconds(700))
  await load.value
  #expect(states.last == .loaded(data: "fresh", updatingPhase: nil, error: nil))
}
```

``MockClock/advance(by:)`` resumes the delay timer, but the `.active` state is emitted later, on
that timer's task, so the test waits for the state itself rather than assuming one yield is enough.
The indicator appears at 800 ms and has been visible for 500 ms when the operation finishes. The
second ``MockClock/waitForPendingSleep()`` is the minimum-duration hold, measured rather than
assumed: the operation is done, and the loader is parked in a sleep for the remaining 700 ms instead
of emitting the terminal state.

## Deadlines Are Exact

A sleep is released when the reading reaches its deadline, so a boundary test advances to one
nanosecond short of it and then across:

```swift
@MainActor
@Test func theIndicatorShowsExactlyAtTheDelay() async {
  let clock = MockClock()
  let gate = OperationGate()
  let loader = IndefiniteLoader<String>(clock: clock)
  var states: [IndefiniteLoadState<String>] = []

  let load = Task {
    await loader.load {
      try await gate.wait()
      return "fresh"
    } loadState: { states.append($0) }
  }

  await clock.waitForPendingSleep()
  clock.advance(by: .milliseconds(800) - .nanoseconds(1))
  #expect(clock.pendingSleepCount == 1)
  #expect(states == [.loading(phase: .delayed)])

  clock.advance(by: .nanoseconds(1))
  while states.count < 2 { await Task.yield() }
  #expect(states == [.loading(phase: .delayed), .loading(phase: .active)])

  load.cancel()
  await load.value
}
```

``MockClock/pendingSleepCount`` still reading `1` proves the timer is registered and unreleased,
not merely unscheduled. Cancelling the load at the end ends the gate's wait through
`checkCancellation`, so the test finishes without opening it.

## Cases Worth Covering

- A cold load that finishes inside the delay emits `.loading(.delayed)` then `.loaded`, and never
  `.active`.
- A cold load that runs past the delay emits `.delayed`, `.active`, then `.loaded`, with `.active`
  held for `minimumDuration` measured from the instant it appeared.
- A refresh over cached data keeps the data visible in every state it emits.
- A failure with cached data emits `.loaded(data, nil, error)`; without, `.failed(error)`.
- Cancelling the caller's task with cached data rewinds to `.loaded(data, nil, nil)`; without, no
  further callback arrives.
- A second `load` while one is in flight suppresses every callback from the first.
- A `delay: .zero` loader emits `.active` without the test advancing anything, then holds
  `minimumDuration`.
- An operation that outlives `timeout:` fails with ``IndefiniteLoaderError/timedOut``. Two sleeps
  are parked in that configuration, the delay timer and the timeout, and
  ``MockClock/waitForPendingSleep()`` guarantees only one, so yield until
  ``MockClock/pendingSleepCount`` reaches `2` before advancing.

Every yield loop in a real suite carries an upper bound, so a regression fails with a recorded
issue instead of hanging the run. The samples above leave the bound out for brevity.
