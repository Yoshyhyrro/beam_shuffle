# Target settings
APP_NAME = sidechannel_sim
BUILD_DIR = burrito_out

.PHONY: all deps test build clean

all: build

# Install dependencies
deps:
	mix deps.get

# Run tests (Unit tests for engine logic)
test: deps
	MIX_ENV=test mix test

# Build single binaries for Windows/Linux/macOS via Burrito
build: deps
	MIX_ENV=prod mix release

# Fast local run without Burrito wrapper (for quick development)
run-dev:
	mix run -e 'SidechannelSim.main(["--steps", "100000"])'

# Clean build artifacts
clean:
	mix clean
	rm -rf _build $(BUILD_DIR)
