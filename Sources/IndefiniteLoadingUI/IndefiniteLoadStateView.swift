#if canImport(SwiftUI)
import IndefiniteLoading
import SwiftUI

/// Renders an ``/IndefiniteLoading/IndefiniteLoadState`` with explicit branches for `loading`,
/// `loaded`, `loaded`-but-empty, and `failed`.
///
/// Unlike ``IndefiniteLoaderView``, this view is a passive renderer: it does not drive the
/// loader. Pair it with a view model that owns the ``/IndefiniteLoading/IndefiniteLoader`` and
/// exposes the current state, and keep the `.task` that starts the load on the parent view.
///
/// **Prefer this view to a hand-rolled `switch`.** The `.delayed`/`.active` split in `body` is
/// the entire grace-period mechanism, encoded *structurally* so consumers cannot opt out by
/// accident: a hand-rolled `case .loading:` that misses the split compiles, type-checks, passes
/// every test and renders a perfectly ordinary spinner, while silently defeating the feature.
public struct IndefiniteLoadStateView<T: Sendable, Loaded: View, Empty: View, Failure: View>: View {
  private let empty: () -> Empty
  private let failure: (any Error) -> Failure
  private let isEmpty: (T) -> Bool
  private let loaded: (T) -> Loaded
  private let loadingAccessibilityLabel: String
  private let state: IndefiniteLoadState<T>

  /// Creates a renderer for `state`.
  ///
  /// - Parameters:
  ///   - empty: Builds the branch shown when `isEmpty` reports the loaded data as empty.
  ///   - failure: Builds the failed branch.
  ///   - isEmpty: Decides whether loaded data should render the `empty` branch.
  ///   - loaded: Builds the loaded branch.
  ///   - loadingAccessibilityLabel: The VoiceOver label *and* visible label for the loading
  ///     branch. Safe to default here: unlike ``IndefiniteLoaderView``, this view owns its
  ///     spinner, so there is no caller-supplied copy to override.
  ///   - state: The current state, owned by the caller.
  public init(
    @ViewBuilder empty: @escaping () -> Empty,
    @ViewBuilder failure: @escaping (any Error) -> Failure,
    isEmpty: @escaping (T) -> Bool,
    @ViewBuilder loaded: @escaping (T) -> Loaded,
    loadingAccessibilityLabel: String = "Loading",
    state: IndefiniteLoadState<T>
  ) {
    self.empty = empty
    self.failure = failure
    self.isEmpty = isEmpty
    self.loaded = loaded
    self.loadingAccessibilityLabel = loadingAccessibilityLabel
    self.state = state
  }

  /// The rendered branch for `state`.
  public var body: some View {
    switch state {
    case .loading(.delayed):
      Color.clear
    case .loading(.active):
      defaultLoadingView
    case .loaded(let data, _, _) where isEmpty(data):
      empty()
    case .loaded(let data, _, _):
      loaded(data)
    case .failed(let error):
      failure(error)
    }
  }

  /// The shared loading UI.
  ///
  /// `ProgressView { Text(_) }` delegates to `ProgressView`'s native label layout, which stacks
  /// the label under the indicator and wraps it at large Dynamic Type sizes for free. A
  /// hand-rolled `HStack { ProgressView(); Text(_) }` would need its own accessibility-size
  /// layout switch. The label is a `Text`, never a `String` forced into a fixed frame (fixed frame
  /// plus an accessibility size means truncation), and Dynamic Type is never clamped.
  private var defaultLoadingView: some View {
    ProgressView {
      Text(loadingAccessibilityLabel)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityLabel(loadingAccessibilityLabel)
    .accessibilityAddTraits(.updatesFrequently)
  }
}

#if DEBUG
/// Renders `state` in a captioned, bordered slot.
///
/// The chrome is evidence, not decoration: `.loading(.delayed)` renders nothing, and a blank
/// screenshot is indistinguishable from a preview that failed to render. The caption proves the
/// preview ran; the border shows the bounds the branch actually occupies.
@MainActor
private func loadStatePreviewSlot(
  _ caption: String,
  state: IndefiniteLoadState<[String]>
) -> some View {
  VStack(spacing: 8) {
    Text(caption)
      .font(.caption.monospaced())
    IndefiniteLoadStateView(
      empty: { Text("No items") },
      failure: { Text($0.localizedDescription) },
      isEmpty: { $0.isEmpty },
      loaded: { items in
        VStack { ForEach(items, id: \.self) { Text($0) } }
      },
      state: state
    )
    .border(.red)
  }
  .padding()
}

#Preview("Delayed") {
  loadStatePreviewSlot(".loading(.delayed)", state: .loading(phase: .delayed))
}

#Preview("Active") {
  loadStatePreviewSlot(".loading(.active)", state: .loading(phase: .active))
}

#Preview("Delayed, accessibility Dynamic Type") {
  loadStatePreviewSlot(".loading(.delayed) @ AX3", state: .loading(phase: .delayed))
    .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Active, accessibility Dynamic Type") {
  loadStatePreviewSlot(".loading(.active) @ AX3", state: .loading(phase: .active))
    .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("All branches") {
  @Previewable @State var branch: Int = 0

  VStack {
    Picker("Branch", selection: $branch) {
      Text(".loading(.delayed)").tag(0)
      Text(".loading(.active)").tag(1)
      Text(".loaded (empty)").tag(2)
      Text(".loaded (data)").tag(3)
      Text(".failed").tag(4)
    }
    .padding()

    let state: IndefiniteLoadState<[String]> =
      switch branch {
      case 0: .loading(phase: .delayed)
      case 1: .loading(phase: .active)
      case 2: .loaded(data: [], updatingPhase: nil, error: nil)
      case 3: .loaded(data: ["Alpha", "Beta", "Gamma"], updatingPhase: nil, error: nil)
      default: .failed(error: PreviewLoadError.fetch)
      }

    IndefiniteLoadStateView(
      empty: { Text("No items") },
      failure: { Text($0.localizedDescription) },
      isEmpty: { $0.isEmpty },
      loaded: { items in List(items, id: \.self) { Text($0) } },
      state: state
    )
  }
}

private enum PreviewLoadError: LocalizedError {
  case fetch

  var errorDescription: String? { "Failed to load items. Check your connection." }
}
#endif
#endif
