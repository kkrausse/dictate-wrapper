.PHONY: build run test

BUILD_DIR := $(CURDIR)/.build
MLX_METALLIB := vendor/speech-swift/scripts/build_mlx_metallib.sh

build:
	swift build
	BUILD_DIR="$(BUILD_DIR)" $(MLX_METALLIB) debug

run: build
	swift run --skip-build DictateNemotron

test: build
	swift test --skip-build
