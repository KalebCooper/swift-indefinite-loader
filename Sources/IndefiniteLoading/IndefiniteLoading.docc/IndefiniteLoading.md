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

Every sleep and every elapsed-time measurement goes through one standard library `Clock` measured
in `Duration`, passed to ``IndefiniteLoader/init(clock:delay:minimumDuration:timeout:)``.
Production code takes the default, `ContinuousClock`. Tests pass a ``MockClock``, whose reading
moves only when the test advances it, so every timing rule is asserted as a sequence of states
rather than measured against wall time.

The module depends on no UI framework and builds wherever Swift does: Apple platforms, Linux,
Windows, Android, and WebAssembly. Rendering is the consumer's job. The `IndefiniteLoadingUI`
product in the same package ships two SwiftUI views that encode the `.delayed`/`.active` split
structurally, so a view cannot defeat the grace period by accident.

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
- ``MockClock``

### Substituting the Loader

- ``IndefiniteLoaderProtocol``
