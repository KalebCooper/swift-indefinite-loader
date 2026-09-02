# Contributing to swift-indefinite-loader

Thanks for your interest. The public surface follows semantic versioning: a breaking change lands in
a major release, never a minor one.

## Getting started

1. Fork and clone the repository.
2. Open the package directory in Xcode 26 or later.
3. Build and run tests on the `swift-indefinite-loader-Package` scheme (⌘U) on an iOS 26 simulator,
   or run the package tests from the command line. The `IndefiniteLoading` product also builds and
   tests on Linux, Windows, Android, and WebAssembly, and CI runs every one of them.

## Guidelines

- **Public API:** every public symbol needs a DocC comment.
- **Concurrency:** the loader is `@MainActor`; the wrapped operation runs off the main actor. Library
  code is nonisolated by default, so every `@MainActor` is written where it applies. No actors, no
  `DispatchQueue`, no Combine.
- **Portability:** `Sources/IndefiniteLoading/` imports Foundation and Synchronization only, and
  nothing Darwin-specific from either. Anything that needs SwiftUI belongs in
  `Sources/IndefiniteLoadingUI/`, inside `#if canImport(SwiftUI)`, so the module compiles to nothing
  where SwiftUI is absent.
- **Tests:** Swift Testing only. Deterministic: every sleep and every reading of "now" goes through
  the injected `MockClock`; never sleep or read the wall clock. The emitted state *sequence* is the
  contract, so assert the whole sequence, not the final state.
- **Style:** `swift format lint --strict --recursive Sources Tests` must report zero findings.
  Parameters, stored properties, and enum cases are alphabetical within their grouping unless
  initialization order or a logical dependency dictates otherwise.
- **Scope:** the package is intentionally small: one loader, one state type, two renderers, one
  clock seam. Open an issue to discuss additions before investing in a large PR.

## Pull requests

- Target `main`. One concern per PR.
- Update `CHANGELOG.md` under **Unreleased**.
- CI must pass.

## Reporting issues

Use the issue templates and include a minimal reproduction where possible.
