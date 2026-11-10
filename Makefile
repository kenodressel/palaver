# One build recipe for local use and CI (.github/workflows/*.yml only call make).
AEC_DIR = palaver/_vendored/webrtc_aec
AEC_LIB = $(AEC_DIR)/libraven_aec.dylib
DIST = dist

.PHONY: aec engine app-swift server worker lm engine-test swift-test notify-helper appctl-helper parity-helper e2e-server eval-engine eval-engine-worker test test-changed wheel requirements icons runtime models app manifest release smoke-install publish clean help

# CMakeLists.txt writes the dylib straight into $(AEC_DIR).
$(AEC_LIB):
	cmake -S $(AEC_DIR) -B $(AEC_DIR)/build -DCMAKE_BUILD_TYPE=Release
	cmake --build $(AEC_DIR)/build
	@test -f $(AEC_LIB) || { echo "✗ $(AEC_LIB) was not built"; exit 1; }

aec: $(AEC_LIB) ## Build the vendored WebRTC echo-cancellation library

# The Swift engine (FluidAudio, CoreML). SwiftPM hangs fetching FluidAudio's
# NemoTextProcessing binary here, so it is fetched by tools/fetch_nemo.sh and
# FluidAudio is cloned locally with its two manifests pointed at that copy.
FLUIDAUDIO_TAG = v0.18.2
ENGINE_DIR = native
VENDOR = $(ENGINE_DIR)/vendor
ENGINE_BIN = $(ENGINE_DIR)/.build/release/palaver-engine
# swift-testing ships with the Command Line Tools, outside SwiftPM's default search paths.
CLT_DEV = /Library/Developer/CommandLineTools/Library/Developer
# Only when the Command Line Tools are the selected toolchain: with Xcode (CI's
# runners have both) swift test finds its own Testing.framework.
SELECTED_DEV = $(or $(DEVELOPER_DIR),$(shell xcode-select -p 2>/dev/null))
TESTING_FLAGS = $(if $(and $(filter /Library/Developer/CommandLineTools,$(SELECTED_DEV)),$(wildcard $(CLT_DEV)/Frameworks/Testing.framework)),\
	-Xswiftc -F -Xswiftc $(CLT_DEV)/Frameworks -Xlinker -F -Xlinker $(CLT_DEV)/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks -Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib)

# Each piece is its own target, keyed on its directory, so a deleted or
# half-cleaned vendor/ is fetched again. The stamp is touched last, after the
# manifests are patched, and removed first: a failure never leaves it behind.
$(VENDOR)/NemoTextProcessing.xcframework:
	sh tools/fetch_nemo.sh $(VENDOR)

# Tied to its tag: the stamp's name holds the tag, so bumping FLUIDAUDIO_TAG clones again
# (the old checkout and patch stamp go first); the clone is atomic via .partial.
$(VENDOR)/FluidAudio-$(FLUIDAUDIO_TAG).stamp:
	rm -rf $(VENDOR)/FluidAudio.partial $(VENDOR)/FluidAudio $(VENDOR)/.patched $(VENDOR)/FluidAudio-*.stamp
	git clone --depth 1 --branch $(FLUIDAUDIO_TAG) https://github.com/FluidInference/FluidAudio.git $(VENDOR)/FluidAudio.partial
	mv $(VENDOR)/FluidAudio.partial $(VENDOR)/FluidAudio
	@touch $@

$(VENDOR)/.patched: $(VENDOR)/NemoTextProcessing.xcframework $(VENDOR)/FluidAudio-$(FLUIDAUDIO_TAG).stamp
	@rm -f $@
	chmod -R u+w $(VENDOR)/FluidAudio
	@for f in Package.swift Package@swift-6.2.swift; do \
		python3 tools/patch_fluidaudio.py $(VENDOR)/FluidAudio/$$f ../NemoTextProcessing.xcframework || exit 1; done
	@touch $@

engine: $(VENDOR)/.patched ## Build the Swift engine (native/.build/release/palaver-engine)
	swift build -c release --package-path $(ENGINE_DIR) --product palaver-engine
	@test -x $(ENGINE_BIN) || { echo "✗ $(ENGINE_BIN) was not built"; exit 1; }

# The native app (phase 2): the release bundle's executable, Contents/MacOS/Palaver.
app-swift: $(VENDOR)/.patched ## Build the Swift app (native/.build/release/Palaver)
	swift build -c release --package-path $(ENGINE_DIR) --product Palaver
	@test -x $(ENGINE_DIR)/.build/release/Palaver || { echo "✗ Palaver was not built"; exit 1; }

# The window's server and the pipeline's worker (phase 3): Contents/MacOS/palaver-server and palaver-worker.
# A release program must not carry this Mac's paths (the checkout, the home folder: the builder's user name),
# e.g. from a #filePath outside #if DEBUG.
no-build-paths = @if strings $(1) | grep -F -e "$(CURDIR)" -e "$$HOME/" >/dev/null; then \
	echo "✗ $(1) contains this Mac's paths:"; strings $(1) | grep -F -e "$(CURDIR)" -e "$$HOME/" | head -5; exit 1; fi

server: $(VENDOR)/.patched ## Build the window's server (native/.build/release/palaver-server)
	swift build -c release --package-path $(ENGINE_DIR) --product palaver-server
	@test -x $(ENGINE_DIR)/.build/release/palaver-server || { echo "✗ palaver-server was not built"; exit 1; }
	$(call no-build-paths,$(ENGINE_DIR)/.build/release/palaver-server)

worker: $(VENDOR)/.patched ## Build the pipeline's worker (native/.build/release/palaver-worker)
	swift build -c release --package-path $(ENGINE_DIR) --product palaver-worker
	@test -x $(ENGINE_DIR)/.build/release/palaver-worker || { echo "✗ palaver-worker was not built"; exit 1; }
	$(call no-build-paths,$(ENGINE_DIR)/.build/release/palaver-worker)

# The language model's worker (phase 4): Contents/MacOS/palaver-lm. Built by xcodebuild, not swift build: only it
# compiles MLX's Metal shaders (mlx-swift_Cmlx.bundle/…/default.metallib, the bundle's Contents/Resources/mlx.metallib).
# The prefix maps keep the checkout's path out of the program (MLX's C++ names its source files).
LM_PRODUCTS = $(ENGINE_DIR)/.build/xcode/Build/Products/Release
LM_BIN = $(LM_PRODUCTS)/palaver-lm
lm: $(VENDOR)/.patched ## Build the language model's worker with MLX (native/.build/xcode/Build/Products/Release/palaver-lm)
	cd $(ENGINE_DIR) && xcodebuild -quiet -scheme palaver-lm -configuration Release -destination 'platform=macOS,arch=arm64' \
		-derivedDataPath .build/xcode -skipPackagePluginValidation -skipMacroValidation \
		'OTHER_CFLAGS=$$(inherited) -ffile-prefix-map=$(CURDIR)/=' 'OTHER_SWIFT_FLAGS=$$(inherited) -file-prefix-map $(CURDIR)/=' build
	@test -x $(LM_BIN) || { echo "✗ palaver-lm was not built"; exit 1; }
	@test -f $(LM_PRODUCTS)/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib || { echo "✗ MLX's shaders were not built"; exit 1; }
	$(call no-build-paths,$(LM_BIN))

# The tests run with a temporary XDG_CONFIG_HOME and PALAVER_HOME: debug builds stop a test that would reach the
# user's real ~/.config, home or ~/Meetings (PalaverCore/TestIsolation.swift).
SWIFT_TEST_HOME = tmp=$$(mktemp -d -t palaver-swift-test) && mkdir -p "$$tmp/config" "$$tmp/home" && \
	export XDG_CONFIG_HOME="$$tmp/config" PALAVER_HOME="$$tmp/home"

engine-test: $(VENDOR)/.patched ## Run all Swift tests (engine and app)
	@$(SWIFT_TEST_HOME) && swift test --package-path $(ENGINE_DIR) $(TESTING_FLAGS); status=$$?; rm -rf "$$tmp"; exit $$status

# One suite while iterating: make swift-test FILTER=PythonJSONTests
swift-test: $(VENDOR)/.patched ## Run the Swift tests FILTER names (a suite or test)
	@test -n "$(FILTER)" || { echo "usage: make swift-test FILTER=<SuiteName>"; exit 2; }
	@$(SWIFT_TEST_HOME) && swift test --package-path $(ENGINE_DIR) $(TESTING_FLAGS) --filter '$(FILTER)'; status=$$?; rm -rf "$$tmp"; exit $$status

# The notify contract test (tests/test_notify_swift_contract.py) runs against this helper.
notify-helper: $(VENDOR)/.patched ## Build the Swift notify test helper
	swift build --package-path $(ENGINE_DIR) --product palaver-notify-helper

# The app.sock contract test (tests/test_appctl_swift_contract.py) runs against this helper.
appctl-helper: $(VENDOR)/.patched ## Build the Swift app.sock test helper
	swift build --package-path $(ENGINE_DIR) --product palaver-appctl-helper

# The parity harness (tests/test_parity.py, tools/parity/run.py) runs its ops against this helper;
# tests/test_mcp_swift_contract.py talks to palaver-cli's `mcp`, tests/test_lm_swift_contract.py runs palaver-lm.
parity-helper: $(VENDOR)/.patched ## Build the Swift parity helper, server, worker, palaver-cli and palaver-lm (debug)
	swift build --package-path $(ENGINE_DIR) --product palaver-parity
	swift build --package-path $(ENGINE_DIR) --product palaver-cli
	swift build --package-path $(ENGINE_DIR) --product palaver-lm
	swift build --package-path $(ENGINE_DIR) --product palaver-server
	swift build --package-path $(ENGINE_DIR) --product palaver-worker

# In parallel (pytest-xdist): a test file's tests stay on one worker, so its
# fixtures (a window's server, the browser) are made once. TEST_WORKERS=0: in order.
TEST_WORKERS ?= auto
PYTEST = uv run --extra dev pytest -q $(if $(filter 0,$(TEST_WORKERS)),,-n $(TEST_WORKERS) --dist loadscope)

# The e2e tests' palaver-server: a debug build (its test hooks, assertions on) that is
# optimized, in its own build folder. Unoptimized, its glossary and audio mix are 5 to
# 40 times slower, and the parallel suite times out on them.
E2E_SERVER_BUILD = $(ENGINE_DIR)/.build/e2e
e2e-server: $(VENDOR)/.patched ## Build palaver-server and palaver-lm for the e2e tests (debug, optimized)
	swift build --package-path $(ENGINE_DIR) --product palaver-server --scratch-path $(E2E_SERVER_BUILD) \
		-Xswiftc -O -Xswiftc -assert-config -Xswiftc Debug
	swift build --package-path $(ENGINE_DIR) --product palaver-lm --scratch-path $(E2E_SERVER_BUILD) \
		-Xswiftc -O -Xswiftc -assert-config -Xswiftc Debug

# The e2e tests run against palaver-server (e2e-server); a missing Playwright or
# WebKit fails them instead of skipping them.
test: aec engine-test notify-helper appctl-helper parity-helper e2e-server ## Run the test suite (in parallel)
	PALAVER_E2E_REQUIRED=1 $(PYTEST)

eval-engine: ## Local gate on your recordings (needs PALAVER_EVAL_DIR). tools/eval_engine.py's exit: 0 pass, 1 a check FAILED, 2 misconfigured (make itself reports 2 for both)
	@test -n "$$PALAVER_EVAL_DIR" -a -f "$$PALAVER_EVAL_DIR/eval.json" || { echo "eval-engine needs PALAVER_EVAL_DIR: a folder with the local eval.json (see tools/eval_engine.py)" >&2; exit 2; }
	@$(MAKE) --no-print-directory engine
	$(PYTHON) tools/eval_engine.py

eval-engine-worker: ## The same gate through palaver-worker's in-process engine (engine-serve, release build); writes engine-gate-worker.md
	@test -n "$$PALAVER_EVAL_DIR" -a -f "$$PALAVER_EVAL_DIR/eval.json" || { echo "eval-engine-worker needs PALAVER_EVAL_DIR: a folder with the local eval.json (see tools/eval_engine.py)" >&2; exit 2; }
	@$(MAKE) --no-print-directory $(VENDOR)/.patched
	swift build -c release --package-path $(ENGINE_DIR) --product palaver-worker
	$(PYTHON) tools/eval_engine.py --worker $(ENGINE_DIR)/.build/release/palaver-worker

test-changed: aec ## Run the tests for what changed since master (tools/changed_tests.py)
	@TESTS="$$(uv run python tools/changed_tests.py)"; \
		if [ -z "$$TESTS" ]; then echo "nothing changed that a test covers"; else echo "$$TESTS" | tr '\n' ' '; echo; $(PYTEST) $$TESTS; fi

icons: ## Draw the app and menu bar icons into palaver/assets (needs Pillow)
	uv run --with pillow python tools/make_icons.py

# Release assets (#60), built on this Mac: the app (the Swift programs, no Python), the placeholder runtime the
# updaters before 0.6 need (a few hundred bytes, uploaded once), manifest.json and install.sh.
PYTHON ?= uv run python
BUILD_RELEASE = $(PYTHON) tools/build_release.py
BUILD_ARGS = --dist $(DIST)
LATEST_MANIFEST = https://github.com/kenodressel/palaver/releases/latest/download/manifest.json
PREVIOUS_MANIFEST ?= $(DIST)/previous-manifest.json

# The `palaver` command (phase 4): Contents/Resources/bin/palaver, which ~/.local/bin/palaver links to.
cli: $(VENDOR)/.patched ## Build the palaver command (native/.build/release/palaver-cli)
	swift build -c release --package-path $(ENGINE_DIR) --product palaver-cli
	@test -x $(ENGINE_DIR)/.build/release/palaver-cli || { echo "✗ palaver-cli was not built"; exit 1; }
	$(call no-build-paths,$(ENGINE_DIR)/.build/release/palaver-cli)

compat-runtime: ## Write the placeholder runtime the updaters before 0.6 need (the same bytes every build)
	$(BUILD_RELEASE) compat-runtime $(BUILD_ARGS)

models: ## Nothing to pack: Palaver hosts no models (kept so old scripts work)
	$(BUILD_RELEASE) models $(BUILD_ARGS)

app: aec engine app-swift server worker lm cli ## Build Palaver.app (the Swift programs and the palaver command; no Python), zipped
	$(BUILD_RELEASE) app $(BUILD_ARGS)

manifest: ## Write manifest.json and upload.txt over the assets in dist/
	@curl -fsSL -o "$(DIST)/previous-manifest.json" "$(LATEST_MANIFEST)" 2>/dev/null \
		|| rm -f "$(DIST)/previous-manifest.json"
	$(BUILD_RELEASE) manifest $(BUILD_ARGS) $$(test -f "$(PREVIOUS_MANIFEST)" && echo --previous "$(PREVIOUS_MANIFEST)") \
		$$(test -f "$(DIST)/notes.md" && echo --notes "$(DIST)/notes.md")

release: app compat-runtime manifest ## All release assets in dist/ (upload.txt: what to upload)
	@cp install.sh $(DIST)/install.sh
	@ls -lh $(DIST) | grep -v "^d"

smoke-install: ## Install dist/ into a throwaway HOME, check it, and simulate an update
	sh tools/smoke_install.sh "$(CURDIR)/$(DIST)" "$(PYTHON)"

VERSION = $(shell sed -n 's/^__version__ = "\(.*\)"/\1/p' palaver/__init__.py)

# Ad hoc signatures differ every build, and macOS asks testers for the
# microphone and system audio again after each update: a release is signed
# with the kept certificate (CONTRIBUTING.md, "Signing releases").
publish: ## Create the GitHub release of this version from dist/upload.txt (needs gh and PALAVER_SIGN_IDENTITY)
	@test -n "$$PALAVER_SIGN_IDENTITY" \
		|| { echo "✗ publish needs PALAVER_SIGN_IDENTITY (and make release built with it)"; exit 1; }
	@T=$$(mktemp -d); ditto -xk "$(DIST)/palaver-app-$(VERSION).zip" "$$T" || exit 1; \
		if codesign -dv "$$T/Palaver.app" 2>&1 | grep -q "Signature=adhoc"; then rm -rf "$$T"; \
			echo "✗ dist/palaver-app-$(VERSION).zip is signed ad hoc: run make release with PALAVER_SIGN_IDENTITY set"; \
			exit 1; fi; rm -rf "$$T"
	cd $(DIST) && gh release create "v$(VERSION)" --repo kenodressel/palaver $$(cat upload.txt) --generate-notes

clean: ## Remove build output
	rm -rf $(DIST) build $(AEC_DIR)/build

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
