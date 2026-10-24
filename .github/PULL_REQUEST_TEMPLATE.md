## What and why

<!-- What this change does and the problem it solves. Link the issue: "Fixes #123". -->

## How it was tested

<!-- The tests you added or changed, and the hardware you ran them on (Mac or device and chip). -->

## Checklist

- [ ] `swift build`, `swift build -c release` and `swift test` pass with no warnings.
- [ ] The libraries still compile for iOS (`xcodebuild build -scheme MonitorKit-Package -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`).
- [ ] New or changed behaviour has tests. GPU math is checked against a CPU reference in `MonitorKitCore`.
- [ ] GPU changes pass under `MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 swift test`, on both the classic and the Metal 4 encode paths.
- [ ] Frame-path code allocates nothing (it uses `while` loops, no capturing closures), and the allocation tests still count 0.
- [ ] Performance-sensitive changes: the benchmarks pass on a quiet machine. Before and after numbers are below.
- [ ] New constants cite their source in `Docs/MATH.md`.
- [ ] Public API changes are documented in `Docs/API.md` and in `CHANGELOG.md`.

## Benchmarks

<!-- Optional: the BENCH lines before and after, with the machine they were measured on. -->
