# ``IndefiniteLoadingUI``

SwiftUI views that render an `IndefiniteLoadState` with the grace period encoded structurally.

## Overview

`IndefiniteLoading` emits a sequence of load states with a `.delayed` phase before any indicator
should appear and an `.active` phase once one should. That split is the whole grace-period
mechanism, and a hand-rolled `switch` that matches `case .loading:` without the phase compiles,
passes every test, and shows a spinner for a 50 ms load.

This module ships two views that make the split impossible to miss. ``IndefiniteLoaderView`` runs
the load from its own `.task` and renders the state through `loaded`, `loading`, and `failed`
builders. ``IndefiniteLoadStateView`` is the passive renderer for a state a view model owns, with
an `empty` branch and a built-in loading view. Both render nothing during `.delayed` and the loading
branch during `.active`.

```swift
import IndefiniteLoading
import IndefiniteLoadingUI
import SwiftUI

struct ProfileScreen: View {
  @State private var model = ProfileModel()

  var body: some View {
    IndefiniteLoaderView(
      state: model.state,
      loader: { await model.load() },
      loaded: { profile, _, _ in ProfileContent(profile) },
      loading: { ProgressView() },
      failed: { error in Text(error.localizedDescription) }
    )
  }
}
```

The module depends on `IndefiniteLoading` and on SwiftUI. On a platform without SwiftUI it
compiles to an empty module, so a package that lists both products still builds everywhere.

## Topics

### Essentials

- <doc:Rendering>

### Views

- ``IndefiniteLoaderView``
- ``IndefiniteLoadStateView``
