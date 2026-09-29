# swift-indefinite-loader

[![CI](https://github.com/KalebCooper/swift-indefinite-loader/actions/workflows/ci.yml/badge.svg)](https://github.com/KalebCooper/swift-indefinite-loader/actions/workflows/ci.yml)
[![Docs](https://github.com/KalebCooper/swift-indefinite-loader/actions/workflows/docs.yml/badge.svg)](https://kalebcooper.github.io/swift-indefinite-loader/documentation/)
[![Swift Version Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FKalebCooper%2Fswift-indefinite-loader%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/KalebCooper/swift-indefinite-loader)
[![Platform Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FKalebCooper%2Fswift-indefinite-loader%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/KalebCooper/swift-indefinite-loader)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A small, reusable loader for async work in Swift apps.

Hand `IndefiniteLoader` an async closure and it emits a clean sequence of load states for your UI to
render, with sensible timing built in. No framework dependency: the `IndefiniteLoading` product
builds and tests on Apple platforms, Linux, Windows, Android, and WebAssembly. SwiftUI views ship
in a separate `IndefiniteLoadingUI` product for the common case.

## Quick start

A view model owns the loader and exposes its state. The view renders the state and starts the load:

```swift
import IndefiniteLoading
import IndefiniteLoadingUI
import SwiftUI

@MainActor
@Observable
final class ProfileModel {
  private let loader = IndefiniteLoader<Profile>()
  private(set) var state: IndefiniteLoadState<Profile> = .loading(phase: .delayed)

  func load() async {
    await loader.load(updating: state.loadedData) {
      try await ProfileService.fetch()
    } loadState: { [weak self] in
      self?.state = $0
    }
  }
}

struct ProfileScreen: View {
  @State private var model = ProfileModel()

  var body: some View {
    IndefiniteLoaderView(
      state: model.state,
      loader: { await model.load() },
      loaded: { profile, _, error in
        ProfileContent(profile)
          .safeAreaInset(edge: .bottom) {
            if let error { Text(error.localizedDescription) }
          }
      },
      loading: { ProgressView() },
      failed: { error in
        ContentUnavailableView(
          "Couldn't load your profile",
          systemImage: "wifi.slash",
          description: Text(error.localizedDescription)
        )
      }
    )
    .refreshable { await model.load() }
  }
}
```

With the defaults, a fetch that resolves inside 0.8 s never shows the spinner. One that runs longer
shows it and keeps it up for at least 1.2 s. Passing the current data as `updating:` keeps the
profile on screen through a refresh that finishes inside the delay instead of dropping back to a
blank grace period, and a refresh that fails keeps the profile and hands the error to the `loaded`
builder.

- One `IndefiniteLoader<T>` per load surface, holding the timing rules and the in-flight task.
- One `IndefiniteLoadState<T>` with three cases and a phase on each running one, so "loading but
  do not show it yet" is a state a view can render, not a flag it has to remember.
- Two SwiftUI renderers, in their own product, that encode the grace period structurally, so a
  view cannot defeat it by accident.
- A clock seam: the loader sleeps on any `Clock` measured in `Duration`, `ContinuousClock` by
  default. `MockClock` moves only when a test moves it, so every timing rule is asserted as a
  sequence of states rather than measured against wall time.

## Installation

```swift
.package(url: "https://github.com/KalebCooper/swift-indefinite-loader.git", from: "2.0.0")
```

| Product | Add it to |
|---|---|
| `IndefiniteLoading` | Any target that loads data or reads load state. No UI framework behind it. |
| `IndefiniteLoadingUI` | A SwiftUI target that renders load state. Depends on `IndefiniteLoading`. |

Versions follow semantic versioning, and every change is recorded in [CHANGELOG.md](CHANGELOG.md).

## Usage

### The state a view renders

`IndefiniteLoadState<T>` has three cases and seven rendering situations. The phase on a running load
is the whole grace-period mechanism: `.delayed` means "render nothing yet", `.active` is the one
moment a spinner is legal.

| Situation | State | Render |
|---|---|---|
| Cold load, inside the delay | `.loading(phase: .delayed)` | Nothing |
| Cold load, past the delay | `.loading(phase: .active)` | The loading indicator |
| Refresh over cached data, inside the delay | `.loaded(data, .delayed, nil)` | The data |
| Refresh over cached data, past the delay | `.loaded(data, .active, nil)` | The data with an updating indicator, or the loading indicator |
| Refresh failed, cached data still useful | `.loaded(data, nil, error)` | The data plus a non-blocking error |
| Loaded | `.loaded(data, nil, nil)` | The data |
| Cold load failed | `.failed(error)` | An error view with retry |

`IndefiniteLoaderView` and `IndefiniteLoadStateView` handle every row; they differ only on a
refresh that runs past the delay, where the first swaps in its loading branch and the second keeps
the data. A hand-rolled `case .loading:` that does not split the phase compiles, passes every test,
and shows a spinner for a 50 ms load.

### Rendering a state the view model owns

`IndefiniteLoadStateView` is a passive renderer with an `empty` branch. It does not run the load, so
the `.task` stays on the parent:

```swift
IndefiniteLoadStateView(
  empty: { Text("No items yet") },
  failure: { error in Text(error.localizedDescription) },
  isEmpty: { $0.isEmpty },
  loaded: { items in List(items) { ItemRow($0) } },
  state: model.state
)
.task { await model.load() }
```

### A submit button

A tap wants immediate feedback, so a submission loader uses no delay and a short minimum:

```swift
private let loader = IndefiniteLoader<Void>(delay: .zero, minimumDuration: .seconds(0.4))
```

```swift
Button {
  Task { await model.signIn() }
} label: {
  if model.state.isLoadingOrUpdatingActive {
    ProgressView()
  } else {
    Text("Sign In")
  }
}
.disabled(model.state.isLoadingOrUpdatingActive)
```

`isLoadingOrUpdatingActive` is `true` exactly when a spinner is legally on screen, so the same flag
drives the label and the disabled state.

### Cancellation

Three things cancel a load: the caller's task (a SwiftUI `.task` on disappear), a new `load` call,
and `cancel()`. When the load was started with `updating:` data, the consumer receives one final
`.loaded(data, nil, nil)` so the cached value stays visible with no indicator. A cold load that is
cancelled receives no further callback.

### A timeout

```swift
private let loader = IndefiniteLoader<Report>(minimumDuration: .seconds(2), timeout: .seconds(30))
```

An operation that outlives `timeout` fails with `IndefiniteLoaderError.timedOut`, through the same
minimum-duration hold as any other failure.

### Testing

`MockClock` moves its reading only when told and ends each sleep when the reading reaches the
sleep's deadline, so a test drives the loader through each transition and asserts the sequence it
emitted:

```swift
import IndefiniteLoading
import Testing

@MainActor
@Test func aFastLoadNeverShowsTheSpinner() async {
  let clock = MockClock()
  let loader = IndefiniteLoader<String>(clock: clock)
  let (released, release) = AsyncStream<Void>.makeStream()
  var states: [IndefiniteLoadState<String>] = []

  let load = Task {
    await loader.load {
      for await _ in released {}
      return "fresh"
    } loadState: { states.append($0) }
  }

  await clock.waitForPendingSleep()
  release.finish()
  await load.value

  #expect(states == [
    .loading(phase: .delayed),
    .loaded(data: "fresh", updatingPhase: nil, error: nil),
  ])
  #expect(clock.pendingSleepCount == 0)
}
```

The operation waits on a stream until the delay timer is parked on the clock, then finishes inside
the delay. The loader cancels the timer on its way out, so its sleep is gone rather than merely
unfired, and nothing emits `.active`. The [Testing](https://kalebcooper.github.io/swift-indefinite-loader/documentation/indefiniteloading/testing/)
article covers holding an operation mid-flight and advancing `MockClock` to each deadline a timing
test depends on.

## Requirements

- Swift 6.2 tools, Swift 6 language mode
- `IndefiniteLoading`: Apple platforms, Linux, Windows, Android, and WebAssembly (WASI). Every one
  runs the test suite in CI.
- `IndefiniteLoadingUI`: iOS 26 / macOS 26 / tvOS 26 / visionOS 26 / watchOS 26. On a platform
  without SwiftUI it compiles to an empty module.
- No dependencies

## Documentation

The full API reference is at
**[kalebcooper.github.io/swift-indefinite-loader](https://kalebcooper.github.io/swift-indefinite-loader/documentation/)**,
rebuilt from `main` on every push, with one section per product. Three articles accompany it:

| Article | |
|---|---|
| [Getting Started](https://kalebcooper.github.io/swift-indefinite-loader/documentation/indefiniteloading/gettingstarted/) | Give a view model a loader, read the state it emits, refresh over cached data, and configure a submission |
| [Testing](https://kalebcooper.github.io/swift-indefinite-loader/documentation/indefiniteloading/testing/) | Drive the loader with `MockClock` and assert the emitted sequence |
| [Rendering](https://kalebcooper.github.io/swift-indefinite-loader/documentation/indefiniteloadingui/rendering/) | Render the state with the two SwiftUI views, refresh over cached data, and bind a submit button |

Or build them locally in Xcode with **Product ▸ Build Documentation**.

## License

MIT. See [LICENSE](LICENSE).
