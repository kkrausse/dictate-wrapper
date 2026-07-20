# Dictate Nemotron

Dictate Nemotron is a macOS menu-bar dictation application for Apple Silicon. Press a global keyboard shortcut, speak, and have dictated text pasted into whichever application currently has focus.

The project is intentionally app-focused. [FluidAudio](https://github.com/FluidInference/FluidAudio) and [Speech Swift](https://github.com/soniqo/speech-swift) are pinned Git submodules under `vendor/`. FluidAudio provides the default native streaming path; Speech Swift remains available as an explicit rollback path.

## Current Status

The development app currently:

- Uses Right Option as a global push-to-talk shortcut.
- Captures microphone audio and transcribes it locally.
- Shows partial and finalized text in a menu-bar popover.
- Pastes append-only FluidAudio token suffixes at the cursor in the frontmost app.
- Flushes pending audio when dictation stops so the ending is not truncated.

The default transcription backend is FluidAudio's Parakeet Unified English 0.6B CoreML model at its 1120 ms streaming latency tier. On first run, FluidAudio downloads the required CoreML artifacts from `FluidInference/parakeet-unified-en-0.6b-coreml` and caches them in `~/Library/Application Support/FluidAudio/Models/parakeet-unified-en-0.6b`. Its streaming encoder reprocesses a bounded left/chunk/right audio window while preserving RNN-T decoder state across microphone callbacks. First startup downloads and compiles the model artifacts, while later starts use that cache.

## Model Selection

The app reads `DICTATE_ASR_BACKEND` once at startup. Omitting it, including when running plain `make run`, selects the default Parakeet Unified model. An unknown value is shown as a load error; the app never silently falls back to a different model after a load or inference failure.

| Backend value | Model | Implementation | Launch command |
| --- | --- | --- | --- |
| `fluid-parakeet-unified-1120` | Parakeet Unified English 0.6B CoreML, 1120 ms | FluidAudio native streaming | `make run` |
| `fluid-nemotron-1120` | Nemotron Speech Streaming English 0.6B CoreML, 1120 ms | FluidAudio native streaming | `DICTATE_ASR_BACKEND=fluid-nemotron-1120 make run` |
| `speech-swift-nemotron` | Nemotron Speech Streaming English 0.6B CoreML, 160 ms artifact geometry | Speech Swift native streaming | `DICTATE_ASR_BACKEND=speech-swift-nemotron make run` |
| `qwen3` | Qwen3-ASR 0.6B MLX 4-bit | Speech Swift batch adapter | `make metal` once, then `DICTATE_ASR_BACKEND=qwen3 make run` |

The FluidAudio models download and cache independently on their first use. The previous FluidAudio Nemotron backend downloads the `nemotron_coreml_1120ms` artifact from `FluidInference/nemotron-speech-streaming-en-0.6b-coreml` and caches it in `~/Library/Application Support/FluidAudio/Models/nemotron-streaming/1120ms`.

`speech-swift-nemotron` defaults to `aufklarer/Nemotron-Speech-Streaming-0.6B-CoreML-INT8`. Set `DICTATE_NEMOTRON_MODEL_ID` to use a compatible alternative bundle, such as a future bundle with a different exported chunk geometry:

```bash
DICTATE_ASR_BACKEND=speech-swift-nemotron \
DICTATE_NEMOTRON_MODEL_ID=<compatible-model-id> \
make run
```

`qwen3` currently uses the fixed `aufklarer/Qwen3-ASR-0.6B-MLX-4bit` model ID. It does not have a model-ID override.

## Recognition behavior

FluidAudio Parakeet Unified emits a cumulative decode of an append-only RNN-T token stream. The app validates that every callback has the previous callback as a prefix and pastes only the new suffix immediately. It does not apply the legacy 5.1-second stability delay, trailing-word guard, or edit-distance realignment. If the prefix invariant fails, the changed hypothesis remains visible in the dictation UI and is logged, but the app does not guess at a replacement in the focused application.

FluidAudio finalizes only when push-to-talk is released. The app drains all captured recorder audio, then calls FluidAudio `finish()` exactly once; FluidAudio flushes its held-back streaming context, so the app does not add a silent post-roll or load a separate VAD model. Qwen3-ASR and Speech Swift Nemotron retain the existing legacy processor, including its Silero VAD and stability handling where required.

When the `speech-swift-nemotron` rollback backend is selected, NVIDIA supports 80, 160, 560, and 1120 ms runtime geometries, but the currently published Speech Swift English CoreML artifact is compiled for 160 ms. Chunk geometry is part of that CoreML encoder export, so buffering 560 ms in this app would not produce the 560 ms accuracy operating point. `DICTATE_NEMOTRON_MODEL_ID` can select a future Speech Swift-compatible English bundle compiled for 560 ms without changing app code; the active native geometry is logged at startup.

Set `DICTATE_SAVE_DEBUG_AUDIO=1` in the app environment to retain the complete session and write `/tmp/dictate-debug.wav` when recording stops. Debug audio is disabled by default to avoid continuously growing memory use during dictation.

The legacy backends use Silero VAD to finalize after about 960 ms of sustained silence. FluidAudio Parakeet Unified instead finalizes explicitly when the push-to-talk key is released.

### Batch-ASR performance settings

These environment variables tune the Qwen batch adapter. They will also apply to other non-streaming batch models such as Parakeet-TDT if added later; native streaming models such as Nemotron use their own stateful configuration.

| Variable | Default | Effect |
| --- | ---: | --- |
| `DICTATE_PARTIALS` | `1` | Set to `0` to disable all repeated partial transcription. Audio is transcribed only at VAD, the maximum segment boundary, or explicit stop. This minimizes compute and avoids falling behind, at the cost of no live transcript. |
| `DICTATE_PARTIAL_INTERVAL_SECONDS` | `2` | Seconds of new audio between cumulative partial transcriptions at the start of an utterance. Larger values reduce redundant work but update the live transcript less often. |
| `DICTATE_LONG_UTTERANCE_SECONDS` | `10` | Utterance length at which the adapter switches to the slower long-utterance cadence. |
| `DICTATE_LONG_PARTIAL_INTERVAL_SECONDS` | `4` | Seconds of new audio between partials after the long-utterance threshold. |
| `DICTATE_MAX_SEGMENT_SECONDS` | `20` | Finalizes and resets a continuous batch segment at this duration, bounding cumulative inference cost. Lower values reduce worst-case latency but can split sentences more often. |
| `DICTATE_BACKPRESSURE_SECONDS` | `1` | If at least this much audio accumulated while inference was busy, skip the now-stale partial and catch up. Final transcriptions are never skipped. |
| `DICTATE_MLX_CLEAR_CACHE` | `1` | Clears MLX's reusable temporary-allocation cache after every completed Qwen transcription. Leave enabled to prevent cumulative passes over growing inputs from retaining a large GPU-memory high-water mark. Set to `0` only when benchmarking whether allocator reuse improves latency enough to justify higher memory use. |
| `DICTATE_SAVE_DEBUG_AUDIO` | `0` | Set to `1` to retain the entire recording in memory and write `/tmp/dictate-debug.wav` on stop. Leave disabled for normal use. |

All duration values accept positive decimal seconds. Missing, non-numeric, zero, and negative values use the documented defaults.

For the lowest compute use, run final-only transcription:

```bash
DICTATE_PARTIALS=0 make run
```

For live text with fewer repeated passes than the defaults:

```bash
DICTATE_PARTIAL_INTERVAL_SECONDS=3 \
DICTATE_LONG_PARTIAL_INTERVAL_SECONDS=6 \
DICTATE_MAX_SEGMENT_SECONDS=20 \
make run
```

This is currently a Swift Package Manager development executable. Packaging, signing, configurable shortcuts, login-item support, and an installable macOS app bundle are future work.

## Requirements

- Apple Silicon Mac
- macOS 15 or newer
- Xcode Command Line Tools with a Swift 5.10+ toolchain
- Git

The models are downloaded on first launch, so the first run requires a network connection and takes longer than subsequent launches.

Full Xcode (not just Command Line Tools) and its Metal Toolchain component are only required for the `qwen3` backend, which runs on MLX's GPU path. See [Build](#build).

## Clone

Clone with both vendored submodules:

```bash
git clone --recurse-submodules <repository-url>
cd dictate-nemotron
```

If the repository was cloned without submodules, initialize them separately:

```bash
git submodule update --init --recursive
```

## Build

```bash
make build
```

`make build` runs plain `swift build` and is all that's needed for the FluidAudio backends (`fluid-parakeet-unified-1120`, the default; `fluid-nemotron-1120`) and for `speech-swift-nemotron`. None of them touch MLX's GPU path.

Only the `qwen3` backend needs MLX's compiled `mlx.metallib`, since Qwen3-ASR runs on MLX's GPU path. Build that separately, once, with:

```bash
make metal
```

`make metal` requires the Metal Toolchain, which is part of full Xcode (Xcode 16+), not Command Line Tools alone. If it's missing, install Xcode and run `xcodebuild -downloadComponent MetalToolchain`. Without it, an executable built with plain `swift build` will fail only when Qwen3-ASR first initializes the GPU — every other backend is unaffected.

## Run

Launch the development executable from the repository root:

```bash
make run
```

`make run` depends on `make build`, not `make metal`. If you're using `DICTATE_ASR_BACKEND=qwen3`, run `make metal` first:

```bash
make metal
DICTATE_ASR_BACKEND=qwen3 make run
```

After `make metal` has generated `.build/debug/mlx.metallib`, `swift run DictateNemotron` also works until the build directory is cleaned.

The app appears as a microphone icon in the macOS menu bar rather than in the Dock.

## Usage

1. Launch the app and wait for the ASR and VAD models to load.
2. Put the cursor in the application where dictated text should be inserted.
3. Press and hold the right Option key to record.
4. Speak normally. Finalized utterances are pasted into the focused application.
5. Release right Option to flush pending speech and stop recording.

On first use, macOS asks for microphone and Accessibility access. Accessibility access is required to synthesize `Cmd+V` in the frontmost application. Development builds may need to be re-authorized after the executable changes. Permissions can be managed in **System Settings > Privacy & Security**.

Diagnostic logs are written to `~/Library/Logs/DictateNemotron/dictate.log` with owner-only permissions. Dictated text is redacted from the log (only lengths are recorded) unless `DICTATE_LOG_TRANSCRIPTS=1` is set. Debug audio is written to `/tmp/dictate-debug.wav` only when `DICTATE_SAVE_DEBUG_AUDIO=1`.

## Updating Submodules

The submodule is pinned so upstream changes are explicit and reviewable:

```bash
git -C vendor/speech-swift fetch origin
git -C vendor/speech-swift checkout main
git -C vendor/speech-swift pull --ff-only
git -C vendor/FluidAudio fetch origin
git -C vendor/FluidAudio checkout 300165b240c45375add402265f62410b6df33cf1
git add vendor/speech-swift vendor/FluidAudio
```

FluidAudio is pinned to `300165b240c45375add402265f62410b6df33cf1`; choose and review a replacement commit before changing that checkout. Commit updated submodule pointers together with any required app changes.

## Roadmap

- Expose language/model options using the existing backend boundary.
- Add configurable global keybindings.
- Produce a signed, installable macOS app bundle.
- Add launch-at-login support so dictation shortcuts are always available.
- Replace development diagnostics with structured application logging.
