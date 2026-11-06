# One build recipe for local use and CI (.github/workflows/*.yml only call make).
AEC_DIR = palaver/_vendored/webrtc_aec
AEC_LIB = $(AEC_DIR)/libraven_aec.dylib
DIST = dist

.PHONY: aec engine app-swift engine-test notify-helper appctl-helper eval-engine test test-changed wheel requirements icons runtime models app manifest release smoke-install publish clean help

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

engine-test: $(VENDOR)/.patched ## Run all Swift tests (engine and app)
	swift test --package-path $(ENGINE_DIR) $(TESTING_FLAGS)

# The notify contract test (tests/test_notify_swift_contract.py) runs against this helper.
notify-helper: $(VENDOR)/.patched ## Build the Swift notify test helper
	swift build --package-path $(ENGINE_DIR) --product palaver-notify-helper

# The app.sock contract test (tests/test_appctl_swift_contract.py) runs against this helper.
appctl-helper: $(VENDOR)/.patched ## Build the Swift app.sock test helper
	swift build --package-path $(ENGINE_DIR) --product palaver-appctl-helper

# In parallel (pytest-xdist): a test file's tests stay on one worker, so its
# fixtures (a window's server, the browser) are made once. TEST_WORKERS=0: in order.
TEST_WORKERS ?= auto
PYTEST = uv run --extra dev pytest -q $(if $(filter 0,$(TEST_WORKERS)),,-n $(TEST_WORKERS) --dist loadscope)

test: aec engine-test notify-helper appctl-helper ## Run the test suite (in parallel)
	$(PYTEST)

eval-engine: ## Local gate on your recordings (needs PALAVER_EVAL_DIR). tools/eval_engine.py's exit: 0 pass, 1 a check FAILED, 2 misconfigured (make itself reports 2 for both)
	@test -n "$$PALAVER_EVAL_DIR" -a -f "$$PALAVER_EVAL_DIR/eval.json" || { echo "eval-engine needs PALAVER_EVAL_DIR: a folder with the local eval.json (see tools/eval_engine.py)" >&2; exit 2; }
	@$(MAKE) --no-print-directory engine
	$(PYTHON) tools/eval_engine.py

test-changed: aec ## Run the tests for what changed since master (tools/changed_tests.py)
	@TESTS="$$(uv run python tools/changed_tests.py)"; \
		if [ -z "$$TESTS" ]; then echo "nothing changed that a test covers"; else echo "$$TESTS" | tr '\n' ' '; echo; $(PYTEST) $$TESTS; fi

wheel: aec ## Build the wheel (includes the AEC library)
	@mkdir -p $(DIST)
	@rm -f $(DIST)/palaver-*.whl
	uv build --wheel --out-dir $(DIST)
	@WHEEL=$$(ls $(DIST)/palaver-*.whl | head -1); \
		unzip -l "$$WHEEL" | grep -q "webrtc_aec/libraven_aec.dylib" \
		|| { echo "✗ $$WHEEL lacks libraven_aec.dylib"; exit 1; }; \
		echo "✓ $$WHEEL includes the AEC library"

requirements: ## Export the locked dependency set the runtime is built from
	@mkdir -p $(DIST)
	uv export --frozen --no-dev --no-emit-project --no-hashes --format requirements-txt \
		-o $(DIST)/requirements.txt >/dev/null
	@echo "✓ $(DIST)/requirements.txt ($$(grep -c '==' $(DIST)/requirements.txt) pinned packages)"

icons: ## Draw the app and menu bar icons into palaver/assets (needs Pillow)
	uv run --with pillow python tools/make_icons.py

# Release assets (#60), built on this Mac: the app (Palaver's code), the
# runtime (python-build-standalone + uv.lock, rebuilt only when the lock
# changes), manifest.json and install.sh.
# The latest Python 3.13 of python-build-standalone's latest release (#60).
RUNTIME_PYTHON ?= 3.13.18
PBS_RELEASE ?= 20261026
COMPRESSION ?= gz
PYTHON ?= uv run python
BUILD_RELEASE = $(PYTHON) tools/build_release.py
BUILD_ARGS = --dist $(DIST) --python $(RUNTIME_PYTHON) --pbs-release $(PBS_RELEASE)
LATEST_MANIFEST = https://github.com/kenodressel/palaver/releases/latest/download/manifest.json
PREVIOUS_MANIFEST ?= $(DIST)/previous-manifest.json

runtime: requirements ## Build the runtime archive (kept while uv.lock is unchanged)
	nice -n 10 $(BUILD_RELEASE) runtime $(BUILD_ARGS) --compression $(COMPRESSION)

models: ## Nothing to pack: Palaver hosts no models (kept so old scripts work)
	$(BUILD_RELEASE) models $(BUILD_ARGS)

app: wheel requirements engine app-swift ## Build Palaver.app (the Swift app, the wheel's code, the engine), zipped
	$(BUILD_RELEASE) app $(BUILD_ARGS)

manifest: ## Write manifest.json and upload.txt over the assets in dist/
	@curl -fsSL -o "$(DIST)/previous-manifest.json" "$(LATEST_MANIFEST)" 2>/dev/null \
		|| rm -f "$(DIST)/previous-manifest.json"
	$(BUILD_RELEASE) manifest $(BUILD_ARGS) $$(test -f "$(PREVIOUS_MANIFEST)" && echo --previous "$(PREVIOUS_MANIFEST)") \
		$$(test -f "$(DIST)/notes.md" && echo --notes "$(DIST)/notes.md")

release: runtime app manifest ## All release assets in dist/ (upload.txt: what to upload)
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

clean: ## Remove build output (the runtime archive too: it takes minutes to build again)
	rm -rf $(DIST) build $(AEC_DIR)/build

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
