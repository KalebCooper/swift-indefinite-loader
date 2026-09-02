import Foundation

/// Whether a loading indicator is allowed on screen yet.
///
/// `.delayed` is the grace period: the load is running but the consumer must render **nothing**.
/// `.active` is the one and only moment a spinner becomes legal. Collapsing these two, by matching
/// `case .loading:` without splitting the phase, compiles, type-checks, and looks fine on screen
/// while silently defeating the entire grace-period mechanism.
public enum IndefiniteLoadingPhase: Sendable, Equatable {
  /// The grace delay has elapsed; a loading indicator may be shown.
  case active
  /// The load is running inside the grace delay; render nothing.
  case delayed
}

/// The state of a one-shot load driven by ``IndefiniteLoader``.
///
/// `loaded` carries an `updatingPhase` (non-nil while a refresh runs over cached data) and an
/// `error` (non-nil when a refresh failed but the cached data is still worth showing), so a stale
/// value and its failure can coexist without dropping the user's context.
public enum IndefiniteLoadState<T: Sendable>: Sendable {
  /// A cold load failed with no cached data to fall back on.
  case failed(error: any Error)
  /// Data is available. `updatingPhase` is non-nil while a refresh runs over it, and `error` is
  /// non-nil when a refresh failed and the data shown is the cached value.
  case loaded(data: T, updatingPhase: IndefiniteLoadingPhase?, error: (any Error)?)
  /// A cold load is running with nothing to show yet.
  case loading(phase: IndefiniteLoadingPhase)
}

extension IndefiniteLoadState: Equatable where T: Equatable {
  /// Compares two states case by case, comparing errors as `NSError` values.
  ///
  /// - Parameters:
  ///   - lhs: The first state.
  ///   - rhs: The second state.
  /// - Returns: `true` when both states are the same case with equal payloads.
  public static func == (lhs: IndefiniteLoadState, rhs: IndefiniteLoadState) -> Bool {
    switch (lhs, rhs) {
    case let (.failed(lhsError), .failed(rhsError)):
      return (lhsError as NSError) == (rhsError as NSError)
    case let (.loaded(lhsData, lhsPhase, lhsError), .loaded(rhsData, rhsPhase, rhsError)):
      let errorsEqual: Bool
      switch (lhsError, rhsError) {
      case (nil, nil): errorsEqual = true
      case let (lhs?, rhs?): errorsEqual = (lhs as NSError) == (rhs as NSError)
      default: errorsEqual = false
      }
      return lhsData == rhsData && lhsPhase == rhsPhase && errorsEqual
    case let (.loading(lhsPhase), .loading(rhsPhase)):
      return lhsPhase == rhsPhase
    default:
      return false
    }
  }
}

extension IndefiniteLoadState {
  /// The error carried by `failed`, or the refresh error carried by `loaded`; `nil` otherwise.
  public var error: (any Error)? {
    switch self {
    case .failed(let error): error
    case .loaded(_, _, let error): error
    case .loading: nil
    }
  }

  /// `true` while a load or a refresh is running, in either phase.
  public var isLoadingOrUpdating: Bool {
    loadingPhase != nil || updatingPhase != nil
  }

  /// `true` exactly when a spinner is legally on screen: the flag to drive `.disabled` and
  /// spinner-versus-label swaps from. Deliberately `false` during `.delayed`.
  public var isLoadingOrUpdatingActive: Bool {
    loadingPhase == .active || updatingPhase == .active
  }

  /// The data carried by `loaded`; `nil` otherwise.
  public var loadedData: T? {
    if case .loaded(let data, _, _) = self { return data }
    return nil
  }

  /// The phase carried by `loading`; `nil` otherwise.
  public var loadingPhase: IndefiniteLoadingPhase? {
    if case .loading(let phase) = self { return phase }
    return nil
  }

  /// The refresh phase carried by `loaded`; `nil` when no refresh is running or the state is not
  /// `loaded`.
  public var updatingPhase: IndefiniteLoadingPhase? {
    if case .loaded(_, let phase, _) = self { return phase }
    return nil
  }
}
