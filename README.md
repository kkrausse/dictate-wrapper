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

The current transcription backend is Speech Swift's Qwen3-ASR 0.6B MLX model with Silero VAD. It uses the `aufklarer/Qwen3-ASR-0.6B-MLX-4bit` bundle and an explicit `en` language hint for English-only dictation. The backend is isolated behind an app-local streaming session interface and factory so model-specific transcripts and lifecycle rules do not leak into the view model.

## Recognition behavior

Qwen3-ASR transcribes the accumulated utterance rather than maintaining Nemotron-style native streaming state. The reusable batch-ASR adapter refreshes its partial hypothesis every two seconds initially and every four seconds after ten seconds of continuous audio. It finalizes at a VAD or explicit-stop boundary and caps uninterrupted batch segments at 20 seconds, avoiding unbounded cumulative retranscription without guessing word-to-audio boundaries. Its stable-token commit policy currently waits 2.1 seconds and holds back the newest three words before pasting partial text.

Set `DICTATE_SAVE_DEBUG_AUDIO=1` in the app environment to retain the complete session and write `/tmp/dictate-debug.wav` when recording stops. Debug audio is disabled by default to avoid continuously growing memory use during dictation.

Silero VAD decides when about 960 ms of sustained silence should finalize and reset the utterance. Releasing the push-to-talk key also explicitly finalizes any pending audio.

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

From the repository root, use the project build target so the MLX Metal shader library is compiled alongside the Swift executable:

```bash
make build
```

Plain `swift build` does not compile MLX's `mlx.metallib`; an executable built that way will fail when Qwen3-ASR first initializes the GPU.

## Run

Launch the development executable from the repository root:

```bash
make run
```

After `make build` has generated `.build/debug/mlx.metallib`, `swift run DictateNemotron` also works until the build directory is cleaned.

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
