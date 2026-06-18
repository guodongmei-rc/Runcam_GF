# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`runcam_gf` is a Flutter **plugin** wrapping the Gyroflow video-stabilization engine for iOS and Android. The repo is mid-migration (see `docs/flutter-ui-migration.md`): the goal is to move the editor UI + parameter state from two native codebases (iOS Obj-C/Swift, Android Kotlin) into **one shared Dart layer**, while keeping native only for the four things it must do — video decode, GPU preview render, export encoding, and file picking/permissions. The Rust core, `ios/Libs/gyroflow_ffi.h`, and `android/.../GyroflowNative.kt` are **not** to be modified — only thin forwarding shells around them.

Most code comments and docs are in Chinese; match that when editing existing files.

## Commands

Run everything from `example/` for device builds; from repo root for the plugin's own tests.

```bash
# Plugin unit tests (pure Dart, no device)
flutter test                              # repo root — runs test/params_model_test.dart
flutter test test/params_model_test.dart --plain-name "smoothness"   # single test by name

# Example app unit/widget tests
cd example && flutter test                # runs example/test/stabilize_panel_test.dart

# Run the example app (REAL DEVICE ONLY — see below)
cd example && flutter run                 # pick an attached iOS/Android device

# Static analysis (flutter_lints via analysis_options.yaml)
flutter analyze

# Regenerate the Pigeon bridge after editing pigeons/runcam_gf_api.dart
dart run pigeon --input pigeons/runcam_gf_api.dart
```

**Device-only constraint:** the native engine ships as arm64 static libs (iOS) / `.so` (Android) with no simulator slices. iOS Simulator throws `SIMULATOR_UNSUPPORTED`. Any engine/preview/export work must be verified on a physical device; only the Dart `ParamsModel`/widget tests run host-side.

## Architecture

Three layers, top to bottom:

1. **Dart UI + state** (shared, the migration target). The example editor lives in `example/lib/edit/`: `EditController` (a `ChangeNotifier`) owns the engine lifecycle, the `ParamsModel`, and the current preview backend; panels under `edit/panels/` only read/write `ParamsModel` and never touch a channel directly.

2. **Pigeon bridge** — the single source of truth is `pigeons/runcam_gf_api.dart`. It generates `lib/src/bridge/engine_api.g.dart` (Dart), `ios/Classes/EngineApi.g.swift`, and `android/.../EngineApi.g.kt`. **Never hand-edit the `.g.*` files.** Three interfaces:
   - `EngineApi` (HostApi, Dart→native): discrete parameter setters/getters, `recomputeBlocking`, lens, timelines.
   - `PreviewApi` (HostApi): create/dispose preview texture, play/pause/seek, export mode.
   - `EngineEvents` (FlutterApi, native→Dart): recompute-finished, autosync/export progress, playback ticks.
   High-frequency per-frame `process`/autosync feeding does **not** go over the bridge — it stays inside native.

3. **Native thin shells** forward Pigeon calls to the existing engine:
   - iOS `EngineApiImpl.swift` / `PreviewApiImpl.swift` → `gyroflow_*` C FFI (`ios/Libs/gyroflow_ffi.h`); MDK decode + Metal render + AVAssetWriter export.
   - Android `EngineApiImpl.kt` → `GyroflowNative.kt` JNI; MediaCodec decode + wgpu render + MediaCodec export.
   The legacy native full-screen editor still exists (`GyroflowActivity`, `GyroflowLauncher`) and is reachable via `RuncamGF.open()` over the **separate** `com.runcam/gyroflow` channel — independent of the Pigeon bridge.

### ParamsModel — the core of the Dart state layer

`lib/src/state/params_model.dart` (+ `part` files `params_model_{stabilize,zoom,advanced}.dart`) mirrors the authoritative `ios/Sources/ParamsModel.m`. Every parameter setter follows the same contract:

**clamp → push to engine immediately → arm a shared 200ms debounce → `recomputeBlocking` → write back read-only outputs (`maxAngle{Pitch,Yaw,Roll}`, `minFov`) → `notifyListeners`.**

Key conventions baked in (don't "fix" these without checking `.m`):
- `defaults.dart` and `clamp.dart` are transcribed from `ParamsModel.m`; where `.h` comments disagree with `.m`, **`.m` wins** (noted inline).
- Some params need multi-field atomic pushes via dedicated methods: `pushHorizonLock` (9 args; amount forced 0 when lock off), `pushVideoSpeed`, `pushBackgroundColor`, `pushAdaptiveZoom` (croppingMode→adaptive_zoom mapping 0→0.0 / 1→sec / 2→-1.0).
- `pushAllDefaultsAndRecompute()` is called once by the controller after `createStabilizer`, pushing every FFI-backed value then recomputing directly (bypassing debounce).
- `ParamsModel` depends only on the `EngineBridge` abstract interface (`lib/src/state/engine_bridge.dart`), so tests inject `FakeEngineBridge`. The real `EngineBridgeImpl` 1:1-forwards to the generated `EngineApi`.

### Lifecycle when opening a video (`EditController.openAndStart`)

`pickVideo` (native picker channel) → `createStabilizer` → `openVideo` → `setStabEnabled(true)` (the stab toggle is **not** a panel param; the controller must enable it explicitly, mirroring `ViewController`) → `setGyroOffset(48.0)` (raw-IMU device default, replaced by autosync later) → `pushAllDefaultsAndRecompute` → fetch recording-settings/lens metadata → start preview backend.

### Preview backends

Two interchangeable backends share one engine stabilizer (`example/lib/edit/preview_backend.dart`): `texture` (Flutter `Texture(textureId)` composited) and `platformView` (native MTKView/SurfaceView embedded via `UiKitView`/PlatformView). Switching backends re-decodes but leaves parameter state untouched.

## Migration status & references

`docs/flutter-ui-migration.md` is the master plan (steps 0/1/3/4; step 2 — a `dart:ffi` unified engine — is intentionally skipped). Per-slice design + plan docs live in `docs/superpowers/{specs,plans}/`. When implementing a slice, read its design doc first; it lists the exact native files being ported and the field-by-field checklist against `ParamsModel.h`/`GyroflowNative.kt`.
