.PHONY: build metal run test

BUILD_DIR := $(CURDIR)/.build
MLX_METALLIB := vendor/speech-swift/scripts/build_mlx_metallib.sh

# Command Line Tools ship Swift Testing but do not add its search paths the
# way full Xcode does, so point the build at the CLT copy explicitly. With
# full Xcode selected, plain `swift test` finds Testing on its own.
DEV_DIR := $(shell xcode-select -p)
ifeq ($(DEV_DIR),/Library/Developer/CommandLineTools)
TEST_FLAGS := \
  -Xswiftc -F -Xswiftc $(DEV_DIR)/Library/Developer/Frameworks \
  -Xswiftc -plugin-path -Xswiftc $(DEV_DIR)/usr/lib/swift/host/plugins/testing \
  -Xlinker -F -Xlinker $(DEV_DIR)/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker $(DEV_DIR)/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker $(DEV_DIR)/Library/Developer/usr/lib
endif

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

test:
	swift test $(TEST_FLAGS)
