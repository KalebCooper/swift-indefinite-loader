// swift-tools-version:6.2

import PackageDescription

// Two products, one dependency direction. IndefiniteLoading is the loader, its state, and the clock
// it is driven by, with no UI framework behind it, so it builds and tests anywhere Swift does.
// IndefiniteLoadingUI is the SwiftUI binding: the two renderers that encode the grace period
// structurally. A consumer with no SwiftUI never links it, and on Linux it compiles to an empty
// module rather than being absent, so every platform builds the same target list.
let package = Package(
  name: "swift-indefinite-loader",
  platforms: [
    .iOS(.v26), .macOS(.v26), .tvOS(.v26), .visionOS(.v26), .watchOS(.v26),
  ],
  products: [
    .library(name: "IndefiniteLoading", targets: ["IndefiniteLoading"]),
    .library(name: "IndefiniteLoadingUI", targets: ["IndefiniteLoadingUI"]),
  ],
  targets: [
    .target(name: "IndefiniteLoading", swiftSettings: swiftSettings),
    .target(
      name: "IndefiniteLoadingUI",
      dependencies: ["IndefiniteLoading"],
      swiftSettings: swiftSettings
    ),
    // `MockClock` ships in the main module rather than a third product: one type does not earn a
    // product, and the same clock serves previews.
    .testTarget(
      name: "IndefiniteLoadingTests",
      dependencies: ["IndefiniteLoading"],
      swiftSettings: swiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)

// Library code is nonisolated by default (the inverse of an app target's MainActor default), so every
// `@MainActor` in the package is written where it applies; async entry points run on the caller's
// actor until they truly suspend; and every `unsafe` would have to be spelled out. There are none.
var swiftSettings: [SwiftSetting] {
  [
    .defaultIsolation(nil),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .strictMemorySafety(),
  ]
}
