# Changelog

All notable changes to MonitorKit are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Until 1.0.0, a minor version may change the public API; every such change is listed under **Changed** or **Removed**.

## [0.1.1] - 2026-10-24

### Fixed

- The library compiles with Xcode 26.0.1 and 26.6 (Swift 6.2 and 6.3), and its tests with Xcode 26.6. Those compilers gave up type-checking the waveform and chroma graticule tick builders (`WaveformScale.ticks`, `chromaTicks`) and several test expressions. Behaviour is unchanged. Running the tests needs Xcode 26.6 or later.

## [0.1.0] - 2026-10-24

The first public release.

### Added

Picture (`MonitorKit`, `MonitorKitCore`):

- `MonitorEngine`, `MonitorFeed`, `MonitorPass` and `MonitorMultiview`: one picture pass per surface (decode, burn-in and monitor LUTs, false colour or display transform, display adjustments, output conversion, zebras, clip indicators, peaking, guides, navigator), encoded into the host's command buffers. Classic Metal (`MTLCommandBuffer`) and Metal 4 (`MonitorSubmission` over an `MTL4CommandBuffer`) produce bit-identical pixels.
- Frame layouts: v210, UYVY, YUYV, 8/10/16-bit biplanar 4:2:0, 4:2:2 and 4:4:4, BGRA8/RGBA8, RGB10A2, RGBA16 and RGBA16F/RGBA32F; legal and full range, BT.601, BT.709, BT.2020 and SMPTE 240M matrices, and every ITU-T H.273 chroma siting. `MonitorFrame.wrap(_:cache:signal:)` reads CoreVideo attachments, including the clean aperture and pixel aspect ratio.
- Exposure tools: two zebra sets (band or lower limit); false colour (Sony S-Log3 Monitor & Control Pattern 2, ARRI LogC3/LogC4 code-value tables, ARRI-style on S-Log3, six-band display IRE, custom bands in IRE or stops); per-channel clip indicators with exact clip percentages.
- Focus and framing: focus peaking at source resolution (coloured edges or traditional peak); magnify with 1:1, 1–64× zoom, pan and a navigator inset; aspect guides, safe areas, thirds, grids, diagonals and centre marks drawn analytically; anamorphic de-squeeze, flip and clean aperture.
- Per-surface picture stage (`MonitorState.pictureStage`: source, output or monitor), with every tool measuring its own stage. A distinct output reading (`SignalDescription.outputReading`) lets the output and monitor stages decode the codes differently from the source declaration, in the same pass.
- `.cube` LUTs (`CubeLUT`, `MonitorLUT`): 3D 2³–65³, 1D and shaper tables, tetrahedral, trilinear and hardware interpolation, monitor-only and burn-in routing.
- Display transforms: log to Rec.709 (S-Log3, LogC3, LogC4), PQ to SDR (BT.2408 Annex 5 EETF), HLG to SDR (Report ITU-R BT.2446-1 Method C), each followed by the Report ITU-R BT.2407 gamut step, and HDR passthrough with roll-off to the EDR headroom.
- Display adjustments: brightness, contrast, saturation, white-point trim (temperature and tint), luma monochrome and blue only.
- Output colour (`MonitorOutputColor`, `MonitorLayerColor`): signal-native, SDR (BT.1886, sRGB, gamma 2.2), extended linear, PQ and HLG on Rec.709, Display P3 or Rec.2020; overlays at BT.2408 graphics white; layer tagging with colour space and EDR metadata.
- Freeze (`MonitorFeed.freeze(_:into:)`, `unfreeze(keepingMemory:)`): one compute copy into feed-owned planes, the only frame copy the library makes.
- `MonitorStatus`: what each surface shows and, through `MonitorTool` and `MonitorUnavailableReason`, why a tool that is on is not drawn.
- Metal 4 support: `MonitorSubmission`, `MonitorUniformAllocator`, `MonitorResidency`, `MonitorUniformRing`, `MonitorTextureCache` (IOSurface-keyed, residency-aware frame textures); library-owned argument tables and barriers.
- Start-up: `MonitorEngine.warmUp(targets:layouts:surfaces:save:)`, a host `MTL4Compiler` (`MonitorEngine(…, compiler:)`), and a persistent pipeline warm start (`MonitorPipelineArchive`, `cacheDirectory:`) with content-verified Metal 4 archives.
- Fused tier: `MonitorShaders` with `MKLUT.msl` (`mk_applyLUT`) and `MKDecode.msl` (`mk_decodeRGB`), versioned (`MonitorShaders.lutLayoutVersion`) and include-guarded, so a host kernel burns in exactly the LUT the monitor shows.
- Settings: `MonitorState` is a `Codable` value with fail-closed JSON (`"kind": "MonitorKit.MonitorState"`, `schemaVersion` 2), lenient decoding inside a valid blob, and non-throwing helpers (`MonitorState(decodingOrDefault:)`, `decodedOrDefault(from:)`, `@LenientMonitorState`).

Scopes (`MonitorKitScopes`):

- `ScopeEngine`, `ScopeAccumulator`, `ScopeGroup` (one fused pass for a stage's waveform, histogram and vectorscope), `ScopeRenderer` and `ScopeStatisticsReader`, classic and Metal 4, counting every pixel on the GPU with no readback.
- Waveform (luma, RGB overlay, RGB parade, Y'CbCr parade), vectorscope (1/2/4×, 75 and 100 % targets for BT.601/709/2020, skin-tone line), histogram (luma, RGB overlay, parade; linear or log).
- Percent, code-value and PQ/HLG nit graticules; HDR-aware colours; level ranges `.standard` (−7…109 %) and `.minus10To110`; trace palettes `.standard` and `.plain`, and the `ScopeSettings.plainWaveform(mode:stage:)` preset (768 × 256 over −10…110 IRE).
- GPU statistics: luma extremes and mean, clip fractions per channel.

Audio (`MonitorKitAudio`):

- `AudioMeter` for 1–16 channels at 8–768 kHz: sample peak, ITU-R BS.1770 true peak, RMS, VU (IEC 60268-17), PPM Type I / IIa / IIb (IEC 60268-10), and BS.1770 / EBU R 128 loudness (momentary, short-term, integrated, loudness range, maxima, Max TP), with hold, decay, pause and reset. `LoudnessMeter` for loudness alone. `MeterScale` marks and zones for every meter type. Realtime-safe: no allocation, lock or blocking in `process`.

UI (`MonitorKitUI`):

- `MonitorMetalView` (convenience or host-driven, `CAMetalDisplayLink`, EDR headroom tracking, gestures) and `MonitorRenderer`, with scene handles (`MonitorScene`, `MonitorSource`, `MonitorSurface`, `MonitorScopeOverlay`, `MonitorRegion`).
- SwiftUI views: `MonitorView`, `MonitorSceneView`, `ScopeView`, `ScopeStackView`, `ClipReadout`, `MonitorStatusOverlay`, `AudioMeterView`, `FalseColorLegendView`, `ScopeIREScaleView`, and `MonitorTileToolbar` with per-tool controls.

Documentation: README, FEATURES, API, INTEGRATION, ARCHITECTURE and MATH (every constant with its source and the test that checks it).

[0.1.1]: https://github.com/andrewfitz/MonitorKit/releases/tag/0.1.1
[0.1.0]: https://github.com/andrewfitz/MonitorKit/releases/tag/0.1.0
