# Dictate Nemotron

Dictate Nemotron is a macOS menu-bar dictation application for Apple Silicon. Press a global keyboard shortcut, speak, and have finalized text pasted into whichever application currently has focus.

The project is intentionally app-focused. [Speech Swift](https://github.com/soniqo/speech-swift) is pinned under `vendor/speech-swift` as a Git submodule and provides the on-device speech models and audio infrastructure.

## Current Status

The development app currently:

- Uses Right Option as a global push-to-talk shortcut.
- Captures microphone audio and transcribes it locally.
- Shows partial and finalized text in a menu-bar popover.
- Uses voice activity detection to finalize utterances promptly.
- Pastes each finalized utterance at the cursor in the frontmost app.
- Flushes pending audio when dictation stops so the ending is not truncated.

The current transcription backend is Speech Swift's Nemotron 3.5 streaming ASR model with Silero VAD. Sessions currently use `en-US` for predictable English dictation. The backend is isolated behind an app-local streaming session interface and factory so model-specific transcripts and lifecycle rules do not leak into the view model.

## Recognition latency and accuracy

Nemotron 3.5 supports several streaming recognition modes. The lever is the encoder's right-attention context (lookahead), expressed by NVIDIA and Hugging Face as `num_lookahead_tokens`. More lookahead lets the model consider more future speech before emitting an encoder chunk, generally improving recognition at the cost of delay.

| Mode | Lookahead tokens | Native streaming latency | Availability in this app |
|---|---:|---:|---|
| Ultra-low latency | 0 | 80 ms | Requires another CoreML bundle |
| Low latency | 3 | 320 ms | **Current mode** |
| Balanced | 6 | 560 ms | Requires another CoreML bundle |
| Accuracy | 13 | 1,120 ms | Requires another CoreML bundle |

In the original PyTorch/Transformers model this can be selected with `processor.set_num_lookahead_tokens(...)`. Speech Swift runs a fixed-shape CoreML export, so the recognition mode is compiled into `encoder.mlmodelc` and its accompanying `config.json`. Passing smaller or larger arrays to `pushAudio`, changing `transcribeStream`'s caller-side `chunkDuration`, or editing `config.json` does not retune the model and can produce an invalid graph/session combination. A mode change therefore requires a separately exported Speech Swift-compatible CoreML bundle, loaded through `NemotronStreamingASRModel.fromPretrained(modelId:)` or `fromLocal(bundleDir:)`.

The compatible bundle currently used by the app is `aufklarer/Nemotron-3.5-ASR-Streaming-0.6B-CoreML-INT8`, exported at 320 ms. `RecognitionMode` in `DictateViewModel.swift` makes this selection explicit and is the integration point for additional compatible bundles. At present there is no published 1,120 ms bundle in Speech Swift's expected layout, so the app cannot safely select that mode just by changing a constant.

The model's recognition latency and the app's text-commit delay overlap rather than simply adding for speech in progress. The app currently waits until a token has remained unchanged for 1.7 seconds and retains the newest three words before pasting. Because a 1,120 ms hypothesis would normally arrive within that existing stability window, moving from 320 ms to 1,120 ms would often add less than 800 ms to an already-stable interior word. It would still delay the first partial by roughly 800 ms and can delay the last words or explicit-stop result by up to roughly 800 ms because no later stability wait can hide that initial model delay. These are geometry-based estimates; an alternate bundle should be measured on representative dictation before making it the default.

Silero VAD is a separate lever. Nemotron does not emit an end-of-utterance signal, so this app uses VAD only to decide when about 960 ms of sustained silence should finalize and reset the streaming session. VAD does not select the model's recognition mode, but removing it would remove automatic utterance finalization; releasing the push-to-talk key would still explicitly finalize the session.

This is currently a Swift Package Manager development executable. Packaging, signing, configurable shortcuts, login-item support, and an installable macOS app bundle are future work.

## Requirements

- Apple Silicon Mac
- macOS 15 or newer
- Xcode 16 or a compatible Swift 5.10+ toolchain
- Git

The models are downloaded on first launch, so the first run requires a network connection and takes longer than subsequent launches.

## Clone

Clone with the vendored Speech Swift submodule:

```bash
git clone --recurse-submodules <repository-url>
cd dictate-nemotron
```

If the repository was cloned without submodules, initialize them separately:

```bash
git submodule update --init --recursive
```

## Build

From the repository root:

```bash
swift build
```

For an optimized build:

```bash
swift build -c release
```

## Run

Launch the development executable from the repository root:

```bash
swift run DictateNemotron
```

For the optimized build:

```bash
swift run -c release DictateNemotron
```

The app appears as a microphone icon in the macOS menu bar rather than in the Dock.

## Usage

1. Launch the app and wait for the ASR and VAD models to load.
2. Put the cursor in the application where dictated text should be inserted.
3. Press and hold the right Option key to record.
4. Speak normally. Finalized utterances are pasted into the focused application.
5. Release right Option to flush pending speech and stop recording.

On first use, macOS asks for microphone and Accessibility access. Accessibility access is required to synthesize `Cmd+V` in the frontmost application. Development builds may need to be re-authorized after the executable changes. Permissions can be managed in **System Settings > Privacy & Security**.

Diagnostic logs and captured debug audio are currently written to `/tmp/dictate.log` and `/tmp/dictate-debug.wav`.

## Updating Speech Swift

The submodule is pinned so upstream changes are explicit and reviewable:

```bash
git -C vendor/speech-swift fetch origin
git -C vendor/speech-swift checkout main
git -C vendor/speech-swift pull --ff-only
git add vendor/speech-swift
```

Commit the updated submodule pointer together with any required app changes.

## Roadmap

- Expose language/model options using the existing backend boundary.
- Add configurable global keybindings.
- Produce a signed, installable macOS app bundle.
- Add launch-at-login support so dictation shortcuts are always available.
- Replace development diagnostics with structured application logging.
