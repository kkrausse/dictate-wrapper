# Dictate Nemotron

Dictate Nemotron is a macOS menu-bar dictation application for Apple Silicon. Press a global keyboard shortcut, speak, and have finalized text pasted into whichever application currently has focus.

The project is intentionally app-focused. [Speech Swift](https://github.com/soniqo/speech-swift) is pinned under `vendor/speech-swift` as a Git submodule and provides the on-device speech models and audio infrastructure.

## Current Status

The development app currently:

- Registers `Cmd+Shift+D` as a global start/stop shortcut.
- Captures microphone audio and transcribes it locally.
- Shows partial and finalized text in a menu-bar popover.
- Uses voice activity detection to finalize utterances promptly.
- Pastes each finalized utterance at the cursor in the frontmost app.
- Flushes pending audio when dictation stops so the ending is not truncated.

The current transcription backend is Speech Swift's Parakeet EOU 120M streaming ASR model with Silero VAD. The intended next backend is Speech Swift's Nemotron 3.5 streaming ASR implementation. Keeping that migration in this repository makes it possible to develop app-specific behavior, language selection, model lifecycle, and keybinding preferences without modifying the Speech Swift repository.

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
3. Press `Cmd+Shift+D` to start recording.
4. Speak normally. Finalized utterances are pasted into the focused application.
5. Press `Cmd+Shift+D` again to flush pending speech and stop recording.

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

- Replace Parakeet with `NemotronStreamingASR` and expose language/model options.
- Add configurable global keybindings.
- Produce a signed, installable macOS app bundle.
- Add launch-at-login support so dictation shortcuts are always available.
- Replace development diagnostics with structured application logging.
