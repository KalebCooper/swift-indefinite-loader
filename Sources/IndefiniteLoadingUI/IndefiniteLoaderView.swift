#if canImport(SwiftUI)
import IndefiniteLoading
import SwiftUI

/// Renders a `loading → loaded/failed` UI driven by ``/IndefiniteLoading/IndefiniteLoadState``
/// and runs the load from its own `.task`.
///
/// The view holds no prior-state cache: callers preserve UI across reloads by passing the existing
/// `loadedData` into ``/IndefiniteLoading/IndefiniteLoader/load(updating:operation:loadState:)``
/// themselves, which makes the loader emit `.loaded(.., updatingPhase: .delayed, ..)` instead of
/// `.loading(.delayed)`.
/// As a result `.loading(.delayed)` only occurs on cold loads and renders blank.
///
/// **Prefer this view (or ``IndefiniteLoadStateView``) to a hand-rolled `switch`.** The
/// `.delayed`/`.active` split below is the entire grace-period mechanism, and it is encoded here
/// *structurally* so consumers cannot opt out of it by accident: a hand-rolled `case .loading:`
/// that misses the split compiles, type-checks, passes every test and renders a perfectly ordinary
/// spinner, while silently defeating the feature.
///
/// Because this view calls `loader` from inside `.task`, do not add a second `.task` that loads
/// outside it; that starts two loads on first render.
public struct IndefiniteLoaderView<T: Sendable, Loaded: View, Loading: View, Failed: View>: View {
  private let failed: (any Error) -> Failed
  private let loaded: (T, IndefiniteLoadingPhase?, (any Error)?) -> Loaded
  private let loader: () async -> Void
  private let loading: () -> Loading
  private let loadingAccessibilityLabel: String?
  private let state: IndefiniteLoadState<T>

  /// Creates a view that runs `loader` once and renders `state`.
  ///
  /// - Parameters:
  ///   - state: The current state, owned by the caller and updated through the loader's callback.
  ///   - loader: The load to run from the view's `.task`.
  ///   - loadingAccessibilityLabel: Optional VoiceOver label for the loading branch. Defaults to
  ///     `nil`, so the caller's `loading` builder keeps whatever label it derives; see
  ///     ``IndefiniteLoadStateView`` for why that view defaults the label and this one does not.
  ///   - loaded: Builds the loaded branch from the data, the refresh phase, and any refresh error.
  ///   - loading: Builds the loading branch, shown only in the `.active` phase.
  ///   - failed: Builds the failed branch.
  public init(
    state: IndefiniteLoadState<T>,
    loader: @escaping () async -> Void,
    loadingAccessibilityLabel: String? = nil,
    @ViewBuilder loaded: @escaping (T, IndefiniteLoadingPhase?, (any Error)?) -> Loaded,
    @ViewBuilder loading: @escaping () -> Loading,
    @ViewBuilder failed: @escaping (any Error) -> Failed
  ) {
    self.state = state
    self.loader = loader
    self.loadingAccessibilityLabel = loadingAccessibilityLabel
    self.loaded = loaded
    self.loading = loading
    self.failed = failed
  }

  /// The rendered branch for `state`, with `loader` attached as the view's task.
  public var body: some View {
    content
      .task { await loader() }
  }

  @ViewBuilder
  private var content: some View {
    switch state {
    case .loading(.active):
      loadingContent
    case .loading(.delayed):
      Color.clear
    case .loaded(_, .active, _):
      // Refresh exceeded the delay: show loading instead of stale data.
      loadingContent
    case let .loaded(data, phase, error):
      loaded(data, phase, error)
    case .failed(let error):
      failed(error)
    }
  }

  /// The caller's loading view plus the accessibility contract this view owns.
  ///
  /// `.updatesFrequently` is applied unconditionally: "a spinner is on screen" is knowable from
  /// the state alone, which is exactly the kind of duplication a shared component should absorb.
  ///
  /// The label, by contrast, is opt-in (`nil` default), and that asymmetry with
  /// ``IndefiniteLoadStateView`` is deliberate: this view does not own its loading content; the
  /// caller supplies it. An unconditional default would silently override copy the caller baked
  /// into its own `loading` builder (`ProgressView { Text("Signing in…") }` would be announced as
  /// "Loading"), turning a convenience into an accessibility regression. `IndefiniteLoadStateView`
  /// owns its spinner, so a default is safe there.
  @ViewBuilder
  private var loadingContent: some View {
    if let loadingAccessibilityLabel {
      loading()
        .accessibilityLabel(loadingAccessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
    } else {
      loading()
        .accessibilityAddTraits(.updatesFrequently)
    }
  }
}

#if DEBUG
/// Renders `state` in a captioned, bordered slot.
///
/// The chrome is evidence, not decoration: `.loading(.delayed)` renders nothing, and a blank
/// screenshot is indistinguishable from a preview that failed to render. The caption proves the
/// preview ran; the border shows the bounds the branch actually occupies.
@MainActor
private func loaderPreviewSlot(
  _ caption: String,
  state: IndefiniteLoadState<[String]>
) -> some View {
  VStack(spacing: 8) {
    Text(caption)
      .font(.caption.monospaced())
    IndefiniteLoaderView(
      state: state,
      loader: {},
      loaded: { items, _, _ in
        VStack { ForEach(items, id: \.self) { Text($0) } }
      },
      loading: { ProgressView { Text("Loading") } },
      failed: { Text($0.localizedDescription) }
    )
    .border(.red)
  }
  .padding()
}

#Preview("Delayed") {
  loaderPreviewSlot(".loading(.delayed)", state: .loading(phase: .delayed))
}

#Preview("Active") {
  loaderPreviewSlot(".loading(.active)", state: .loading(phase: .active))
}

#Preview("Delayed, accessibility Dynamic Type") {
  loaderPreviewSlot(".loading(.delayed) @ AX3", state: .loading(phase: .delayed))
    .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Active, accessibility Dynamic Type") {
  loaderPreviewSlot(".loading(.active) @ AX3", state: .loading(phase: .active))
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
#endif
