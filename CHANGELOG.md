# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## Unreleased

### Changed

- **Breaking:** `IndefiniteLoader.init(clock:delay:minimumDuration:timeout:)` takes
  `any Clock<Duration>`, defaulting to `ContinuousClock()`. The loader measures how long its
  indicator has been visible in the clock's own instants.
- **Breaking:** `MockClock` is a standard library `Clock` with its own `MockClock.Instant`. A sleep
  parks until `advance(by:)` moves the reading to its deadline and returns at once when the
  deadline has already been reached, so a `delay: .zero` loader shows its indicator without the
  test advancing anything. `now` is a property, and `init()` replaces `init(now:)`.

### Removed

- **Breaking:** `ClockProtocol` and `SystemClock`. Pass any `Clock` measured in `Duration`;
  `ContinuousClock` is the default.
- **Breaking:** `MockClock.advanceAllSleeps()`. Advance the reading to a sleep's deadline instead;
  releasing a sleeper before its deadline would contradict the clock's reading.

## [1.0.0] - 2026-09-02

### Added

- `IndefiniteLoader<T>`, a one-shot loader that drives `loading`, `loaded`, and `failed`
  transitions for a single async operation through two timing rules: a grace delay before any
  loading indicator is shown (0.8 s by default) and a minimum visible duration once one is (1.2 s
  by default). Cached data passed as `updating:` stays on screen while the operation runs, a
  failure over cached data keeps the data and attaches the error, caller cancellation rewinds to
  the cached value, re-entry cancels the previous load, and an optional `timeout` fails the
  operation with `IndefiniteLoaderError.timedOut`.
- `IndefiniteLoadState<T>` and `IndefiniteLoadingPhase`, the state the loader emits, with
  `Equatable` conformance when `T` is `Equatable` and the `error`, `isLoadingOrUpdating`,
  `isLoadingOrUpdatingActive`, `loadedData`, `loadingPhase`, and `updatingPhase` accessors.
- `IndefiniteLoaderProtocol`, the loader's interface, for consumers that substitute their own
  implementation.
- `IndefiniteLoaderView`, in the `IndefiniteLoadingUI` product, a SwiftUI view that runs the load
  from its own `.task` and renders the state through caller-supplied `loaded`, `loading`, and
  `failed` builders, rendering nothing during the grace delay.
- `IndefiniteLoadStateView`, in the `IndefiniteLoadingUI` product, a passive SwiftUI renderer for a
  state a view model owns, with `loaded`, `empty`, and `failure` branches and a built-in loading
  view.
- `ClockProtocol`, `SystemClock`, and `MockClock`: the clock the loader sleeps on and reads, the
  production implementation, and a test clock that moves only when a test moves it.
- Two products. `IndefiniteLoading` carries the loader, its state, and the clock, depends on no UI
  framework, and builds and tests on Apple platforms, Linux, Windows, Android, and WebAssembly
  (WASI). `IndefiniteLoadingUI` carries the SwiftUI views and compiles to an empty module where
  SwiftUI is unavailable.
