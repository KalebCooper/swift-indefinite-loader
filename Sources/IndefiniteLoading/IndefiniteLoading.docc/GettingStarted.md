# Getting Started

Give a view model a loader, read the state it emits, refresh over cached data, and configure a
submission.

## Overview

``IndefiniteLoader`` belongs to whichever object renders the load state. In practice that is a
view model; a small `@State`-driven view can hold one directly. Create one loader per load surface:
a screen with two independently loaded sections gets two loaders.

```swift
import IndefiniteLoading

@MainActor
@Observable
final class ProfileModel {
  private let loader = IndefiniteLoader<Profile>()
  private(set) var state: IndefiniteLoadState<Profile> = .loading(phase: .delayed)

  func load(updating cached: Profile? = nil) async {
    await loader.load(updating: cached) {
      try await ProfileService.fetch()
    } loadState: { [weak self] in
      self?.state = $0
    }
  }
}
```

The initial state is `.loading(phase: .delayed)` because that is what the loader emits first, so
the view renders the same thing before and after the first call. The loader holds the `loadState`
closure only while a load is in flight and clears it on completion, so `[weak self]` is a defence
against a hung operation keeping the model alive, not a leak fix.

The operation runs on the global concurrent executor. CPU-bound work inside it does not block the
main actor, and the closure inherits the caller's task-local values.

## Reading the State

``IndefiniteLoadState`` has three cases, and the phase on a running one is the whole grace-period
mechanism: ``IndefiniteLoadingPhase/delayed`` means "render nothing yet", and
``IndefiniteLoadingPhase/active`` is the one moment a loading indicator is legal.

| Situation | State |
|---|---|
| Cold load, inside the delay | `.loading(phase: .delayed)` |
| Cold load, past the delay | `.loading(phase: .active)` |
| Refresh over cached data, inside the delay | `.loaded(data, .delayed, nil)` |
| Refresh over cached data, past the delay | `.loaded(data, .active, nil)` |
| Refresh failed, cached data still useful | `.loaded(data, nil, error)` |
| Loaded | `.loaded(data, nil, nil)` |
| Cold load failed | `.failed(error)` |

Whatever renders the state has to split the phase. A hand-rolled `switch` that matches
`case .loading:` without it compiles, passes every test, and shows a spinner for a 50 ms load. The
accessors on the state exist so that split is one read rather than a pattern match:
``IndefiniteLoadState/isLoadingOrUpdatingActive`` is `true` exactly when an indicator belongs on
screen, ``IndefiniteLoadState/loadedData`` is the data in either loaded situation, and
``IndefiniteLoadState/error`` is the error from either failure.

The `IndefiniteLoadingUI` product in this package ships two SwiftUI views that encode the split
structurally. Its Rendering article walks through both.

## Refreshing Over Cached Data

Pull-to-refresh and reactive reloads pass the current data as `updating:`. The consumer first sees
`.loaded(data, updatingPhase: .delayed, error: nil)`, then `.loaded(data, .active, nil)` if the
refresh runs past the delay, then the fresh value. A refresh that fails keeps the cached data and
attaches the error as `.loaded(data, nil, error)`, so the user keeps their context and the failure
is informational:

```swift
await model.load(updating: model.state.loadedData)
```

Read ``IndefiniteLoadState/error`` for a banner and ``IndefiniteLoadState/updatingPhase`` for a
toolbar indicator while the data itself stays in place.

## A Submission

A tap wants immediate feedback. The submission configuration drops the delay and shortens the
minimum so the indicator appears on the first tick and stays long enough to register:

```swift
@MainActor
@Observable
final class SignInModel {
  var email = ""
  var password = ""
  private(set) var state: IndefiniteLoadState<Void> = .loading(phase: .delayed)

  private let loader = IndefiniteLoader<Void>(delay: .zero, minimumDuration: .seconds(0.4))

  func signIn() async {
    await loader.load { [email, password] in
      try await AuthService.signIn(email: email, password: password)
    } loadState: { [weak self] in
      self?.state = $0
    }
  }
}
```

Bind the control to ``IndefiniteLoadState/isLoadingOrUpdatingActive``, which is `true` exactly when
an indicator is legally on screen, so one flag drives its label and its disabled state. Watch
`state` for the terminal `.loaded` case to navigate on success, and read
``IndefiniteLoadState/error`` to show a failure inline.

## Cancellation

Three things cancel a load:

1. The caller's task is cancelled, as a SwiftUI `.task` does when its view disappears.
2. `load` is called again while a load is in flight. The previous load is superseded and none of
   its callbacks arrive.
3. ``IndefiniteLoader/cancel()`` is called.

In every case the in-flight operation is cancelled. When the load was started with `updating:`
data, the consumer receives one final `.loaded(data, updatingPhase: nil, error: nil)`, so the cached
value stays visible with no indicator. A cold load that is cancelled receives no further callback;
the view keeps whatever it was showing.

The operation should observe cancellation. Most Foundation and system APIs do; a tight CPU loop
does not, and its result is discarded while the work keeps running.

## A Timeout

Pass `timeout:` for an operation that could hang. One that outlives it fails with
``IndefiniteLoaderError/timedOut``, through the same minimum-duration hold as any other failure,
and over cached data the timeout arrives as `.loaded(data, nil, error)`:

```swift
private let loader = IndefiniteLoader<Report>(minimumDuration: .seconds(2), timeout: .seconds(30))
```

## Choosing the Timing

| Surface | Configuration | Why |
|---|---|---|
| A screen fetching data | The defaults | Hide brief loads; hold the indicator once shown. |
| Pull-to-refresh | The defaults, with `updating:` | Keep the data on screen while it refreshes. |
| A submit button | `delay: .zero, minimumDuration: .seconds(0.4)` | Tap feedback must be instant. |
| A known-slow operation | `minimumDuration: .seconds(2)`, optionally `timeout:` | Avoid a blink across several seconds of work. |

Do not lower `delay` on a fetch to make the indicator appear sooner. The flash that produces is the
bug the default exists to prevent.
