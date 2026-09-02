# Rendering

Render a load state with the two views, refresh over cached data, and bind a submit button.

## Overview

Every sample here assumes a view model like the one in the `IndefiniteLoading` module's Getting
Started article: it owns an `IndefiniteLoader`, exposes an `IndefiniteLoadState`, and starts a load
from `load()`. The views take that state and decide what is on screen.

```swift
import IndefiniteLoading
import IndefiniteLoadingUI
import SwiftUI
```

## Running the Load From the View

``IndefiniteLoaderView`` runs the load from its own `.task` and renders the state through three
builders. Do not add a second `.task` that loads outside it; that starts two loads on first render.

```swift
struct ProfileScreen: View {
  @State private var model = ProfileModel()

  var body: some View {
    IndefiniteLoaderView(
      state: model.state,
      loader: { await model.load(updating: model.state.loadedData) },
      loaded: { profile, _, _ in ProfileContent(profile) },
      loading: { ProgressView() },
      failed: { error in Text(error.localizedDescription) }
    )
  }
}
```

Passing `model.state.loadedData` as `updating:` means a reload keeps the current profile on screen
through the grace delay instead of dropping back to a blank one. A refresh that runs past the delay
shows the `loading` branch in place of the data, the same as a cold load, so the screen never
carries a spinner and stale content at once.

The `loaded` builder receives the data, the refresh phase, and the error from a failed refresh. The
phase is `.delayed` while a refresh is inside the grace period and `nil` otherwise; the error is
how a failed refresh reaches the screen without unmounting the data:

```swift
loaded: { profile, _, error in
  ProfileContent(profile)
    .safeAreaInset(edge: .bottom) {
      if let error { Text(error.localizedDescription) }
    }
}
```

## Rendering a State the View Model Owns

``IndefiniteLoadStateView`` is the passive alternative, with an `empty` branch for loaded data that
has nothing to show. It does not drive the loader, so the `.task` stays on the parent view, and it
keeps the data on screen through every phase of a refresh:

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

Its loading view is built in, with a label that is both the visible text and the VoiceOver label.
``IndefiniteLoaderView`` takes the loading view from the caller instead and labels it only when
asked, because a default label would overwrite whatever copy the caller's own `ProgressView`
carries.

## Refreshing Over Cached Data

Pull-to-refresh passes the current data as `updating:`. The data stays on screen through the delay,
and a failed refresh keeps the data and attaches the error:

```swift
.refreshable {
  await model.load(updating: model.state.loadedData)
}
```

Read `IndefiniteLoadState.updatingPhase` for a toolbar indicator and `IndefiniteLoadState.error`
for a banner while the data itself stays in place.

## A Submit Button

A submission loader is configured with no delay and a short minimum, so the spinner appears on the
first tick and stays long enough to register. Bind the button to
`IndefiniteLoadState.isLoadingOrUpdatingActive`, which is `true` exactly when a spinner is legally
on screen, so one flag drives the label and the disabled state:

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

Watch `state` for the terminal `.loaded` case to navigate on success, and read
`IndefiniteLoadState.error` to show a failure inline.

## What Each State Renders

The phase on a running load is the grace period: `.delayed` renders nothing, `.active` is the one
moment a spinner is legal. The two views differ in one row, a refresh that runs past the delay:
``IndefiniteLoaderView`` swaps in its loading branch, ``IndefiniteLoadStateView`` keeps the data.

| Situation | State | `IndefiniteLoaderView` | `IndefiniteLoadStateView` |
|---|---|---|---|
| Cold load, inside the delay | `.loading(phase: .delayed)` | Nothing | Nothing |
| Cold load, past the delay | `.loading(phase: .active)` | `loading` | The built-in loading view |
| Refresh, inside the delay | `.loaded(data, .delayed, nil)` | `loaded` | `loaded` or `empty` |
| Refresh, past the delay | `.loaded(data, .active, nil)` | `loading` | `loaded` or `empty` |
| Refresh failed, data still useful | `.loaded(data, nil, error)` | `loaded`, with the error | `loaded` or `empty` |
| Loaded | `.loaded(data, nil, nil)` | `loaded` | `loaded` or `empty` |
| Cold load failed | `.failed(error)` | `failed` | `failure` |
