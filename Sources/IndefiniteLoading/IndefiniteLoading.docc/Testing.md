# Testing

Drive the loader with `MockClock` and assert the sequence of states it emits.

## Overview

``IndefiniteLoader`` reads and sleeps on its ``ClockProtocol``, so a test hands it a ``MockClock``
and owns time. The emitted *sequence* is the contract: a final-state-only assertion would pass even
if a spinner flashed on the way there, so record every state and compare the whole list.

```swift
import IndefiniteLoading
import Testing

@MainActor
@Test func aFastLoadNeverShowsTheSpinner() async {
  let clock = MockClock()
  let loader = IndefiniteLoader<String>(clock: clock)
  var states: [IndefiniteLoadState<String>] = []

  await loader.load {
    "fresh"
  } loadState: { states.append($0) }

  #expect(states == [
    .loading(phase: .delayed),
    .loaded(data: "fresh", updatingPhase: nil, error: nil),
  ])
  #expect(clock.pendingSleepCount == 0)
}
```

The delay timer parked on the clock, the operation won, and the loader cancelled the timer on its
way out. The second expectation is the one with teeth: it distinguishes "cancelled" from "never
released by the test".

## Two Rules the Clock Enforces

1. ``MockClock/sleep(for:)`` **ignores the duration** and parks until ``MockClock/advanceAllSleeps()``,
   `sleep(for: .zero)` included. A loader built with `delay: .zero` never fires its delay timer
   unless the test releases it.
2. ``MockClock/now()`` does **not** move when sleeps are released. The loader reads `now()` to
   compute how long its indicator has been visible, so a minimum-duration test calls
   ``MockClock/advance(by:)`` *and* `advanceAllSleeps()`, or the elapsed time computes as zero.

## Holding an Operation Mid-Flight

To make the delay timer win the race, the operation has to wait for something the clock does not
control. A one-shot gate built on `AsyncStream` does it; keeping it off the clock is what lets the
test choose which side of the race resolves first:

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

## Awaiting a Sleeper, Then Releasing It

A sleeper registers on its own task, so releasing sleeps right after spawning that task races the
registration. ``MockClock/waitForPendingSleep()`` returns once a sleeper is parked, which makes the
sequence deterministic:

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
  clock.advance(by: .seconds(0.8))
  clock.advanceAllSleeps()
  while states.count < 2 { await Task.yield() }
  #expect(states == [.loading(phase: .delayed), .loading(phase: .active)])

  clock.advance(by: .seconds(0.5))
  gate.open()
  await clock.waitForPendingSleep()
  #expect(states.count == 2)

  clock.advance(by: .seconds(0.7))
  clock.advanceAllSleeps()
  await load.value
  #expect(states.last == .loaded(data: "fresh", updatingPhase: nil, error: nil))
}
```

The second `waitForPendingSleep()` is the minimum-duration hold, measured rather than assumed: the
operation has finished, and the loader is parked in a sleep instead of emitting the terminal state.

## Cases Worth Covering

- A cold load that finishes inside the delay emits `.loading(.delayed)` then `.loaded`, and never
  `.active`.
- A cold load that runs past the delay emits `.delayed`, `.active`, then `.loaded`, with `.active`
  held for `minimumDuration`.
- A refresh over cached data keeps the data visible in every state it emits.
- A failure with cached data emits `.loaded(data, nil, error)`; without, `.failed(error)`.
- Cancelling the caller's task with cached data rewinds to `.loaded(data, nil, nil)`; without, no
  further callback arrives.
- A second `load` while one is in flight suppresses every callback from the first.
- A `delay: .zero` loader emits `.active` once the timer is released, then holds `minimumDuration`.
- An operation that outlives `timeout:` fails with ``IndefiniteLoaderError/timedOut``. Two sleeps
  are parked in that configuration, the delay timer and the timeout, so wait for both before
  releasing.
