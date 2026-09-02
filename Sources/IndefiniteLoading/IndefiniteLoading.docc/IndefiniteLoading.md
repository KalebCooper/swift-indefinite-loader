# ``IndefiniteLoading``

Loading state for a single async call, with a grace delay before any indicator is shown and a
minimum duration once one is.

## Overview

``IndefiniteLoader`` runs one async operation and reports its progress as a sequence of
``IndefiniteLoadState`` values. Two timing rules shape that sequence:

1. **Grace delay.** An operation that finishes within `delay` (0.8 s by default) never shows a
   loading indicator. The consumer sees `.loading(phase: .delayed)`, which renders nothing, and
   then `.loaded`.
2. **Minimum duration.** Once the indicator has been shown, it stays up for at least
   `minimumDuration` (1.2 s by default), so a load that completes just after the delay does not
   flash.

Cached data passed as `updating:` flows through the same pipeline and stays on screen while the
operation runs. A failure over cached data keeps the data and attaches the error. Cancelling the
caller's task rewinds to the cached value. Calling `load` again cancels the previous load.

```swift
private let loader = IndefiniteLoader<Profile>()
private(set) var state: IndefiniteLoadState<Profile> = .loading(phase: .delayed)

func load(updating cached: Profile? = nil) async {
  await loader.load(updating: cached) {
    try await ProfileService.fetch()
  } loadState: { [weak self] in
    self?.state = $0
  }
}
```

The module depends on no UI framework and builds wherever Swift does: Apple platforms, Linux, and
Windows. Rendering is the consumer's job. The `IndefiniteLoadingUI` product in the same package
ships two SwiftUI views that encode the `.delayed`/`.active` split structurally, so a view cannot
defeat the grace period by accident. ``MockClock`` stands in for the clock in tests, so every timing
rule is asserted as a sequence of states rather than measured against wall time.

## Topics

### Essentials

- <doc:GettingStarted>
- ``IndefiniteLoader``
- ``IndefiniteLoadState``
- ``IndefiniteLoadingPhase``

### Errors

- ``IndefiniteLoaderError``

### Time

- <doc:Testing>
- ``ClockProtocol``
- ``SystemClock``
- ``MockClock``

### Substituting the Loader

- ``IndefiniteLoaderProtocol``
