.PHONY: build metal run test

BUILD_DIR := $(CURDIR)/.build
MLX_METALLIB := vendor/speech-swift/scripts/build_mlx_metallib.sh

# Plain `swift build` is enough for the default FluidAudio backends
# (fluid-parakeet-unified-1120, fluid-nemotron-1120) and for
# speech-swift-nemotron; none of them touch MLX's GPU path. Only the qwen3
# backend needs mlx.metallib, which requires the Metal Toolchain (part of
# full Xcode, not Command Line Tools alone). Run `make metal` once before
# using DICTATE_ASR_BACKEND=qwen3.
build:
	swift build

metal: build
	BUILD_DIR="$(BUILD_DIR)" $(MLX_METALLIB) debug

run: build
	swift run --skip-build DictateNemotron

test: build
	swift test --skip-build
