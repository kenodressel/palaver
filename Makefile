# One build recipe for local use and CI (.github/workflows/*.yml only call make). Palaver is the Swift package in
# native/; Python (uv, pyproject.toml) is only the developer tooling: the end-to-end tests and the release build.
DIST = dist
VERSION = $(shell cat VERSION)

.PHONY: engine app-swift server worker lm cli engine-test swift-test debug-programs e2e-server test-build test-build-args eval-engine eval-engine-worker test test-all test-long test-changed icons compat-runtime models app manifest release smoke-install publish clean help

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
# On GitHub Actions the paths are the runner's (/Users/runner/…), which name nobody: nothing to check there, and a
# prebuilt dependency (NemoTextProcessing's Rust crates) carries /Users/runner/.cargo paths of its own build.
ifeq ($(GITHUB_ACTIONS),true)
no-build-paths = @echo "(GitHub Actions: the build's paths are the runner's; $(notdir $(1)) not checked for them)"
else
no-build-paths = @if strings $(1) | grep -F -e "$(CURDIR)" -e "$$HOME/" >/dev/null; then \
	echo "✗ $(1) contains this Mac's paths:"; strings $(1) | grep -F -e "$(CURDIR)" -e "$$HOME/" | head -5; exit 1; fi
endif

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

# The tests' build: debug (assertions, test hooks, TestIsolation's guard) and optimized, in its own folder so it never
# trades places with a plain `swift build`. One build serves the Swift tests, the programs they start
# (palaver-server, palaver-cli, palaver-lm, palaver-worker) and the e2e tests' palaver-server and palaver-lm.
# Unoptimized, the tests' synthetic audio and the server's glossary and audio mix are 2 to 40 times slower.
TEST_BUILD = $(ENGINE_DIR)/.build/test
TEST_BUILD_ARGS = --scratch-path $(TEST_BUILD) -Xswiftc -O -Xswiftc -assert-config -Xswiftc Debug $(TESTING_FLAGS)
# About half the cores for the build's jobs (tools/test.sh sizes the tests), so the Mac stays usable during a call.
# A bundle runs as many tests at once as there are cores: most of them wait (on a process, a lock, a timeout).
CORES := $(shell sysctl -n hw.ncpu)
TEST_JOBS ?= $(shell n=$(CORES); echo $$(( n > 3 ? n / 2 : 1 )))

test-build: $(VENDOR)/.patched ## Build the tests and the programs they start (native/.build/test: debug, optimized)
	swift build --package-path $(ENGINE_DIR) --build-tests -j $(TEST_JOBS) $(TEST_BUILD_ARGS)

test-build-args:
	@echo $(TEST_BUILD_ARGS)

# The tests run with a temporary XDG_CONFIG_HOME and PALAVER_HOME each (tools/swift_tests_parallel.sh): debug builds
# stop a test that would reach the user's real ~/.config, home or ~/Meetings (PalaverCore/TestIsolation.swift).
# `make test` runs the tests of what changed (tools/changed_tests.py): the Swift bundles a change can break, the e2e
# tests of its area, the Python tests that name it; the Swift bundles and pytest side by side (tools/test.sh).
test: $(VENDOR)/.patched ## Run the tests of what changed since master (Swift and pytest side by side, on half the cores)
	@tools/test.sh

test-all: $(VENDOR)/.patched ## Run every test: Swift, e2e, the page's JS, the release tooling and install.sh
	@tools/test.sh --all

test-long: $(VENDOR)/.patched ## test-all with the long tests too (PALAVER_LONG_TESTS=1: minutes of synthetic audio); before a release
	@tools/test.sh --long

engine-test: test-build ## Run all Swift tests (engine and app)
	@tools/swift_tests_parallel.sh -w $(CORES) -- $(TEST_BUILD_ARGS)

# One suite while iterating: make swift-test FILTER=VoiceActivityTests
swift-test: test-build ## Run the Swift tests FILTER names (a suite or test)
	@test -n "$(FILTER)" || { echo "usage: make swift-test FILTER=<SuiteName>"; exit 2; }
	@tools/swift_tests_parallel.sh -f '$(FILTER)' -w $(CORES) -- $(TEST_BUILD_ARGS)

# The debug programs, to run by hand (CONTRIBUTING.md): a plain debug build in native/.build/debug.
debug-programs: $(VENDOR)/.patched ## Build palaver-cli, palaver-lm, palaver-server and palaver-worker (debug)
	swift build --package-path $(ENGINE_DIR) --product palaver-cli
	swift build --package-path $(ENGINE_DIR) --product palaver-lm
	swift build --package-path $(ENGINE_DIR) --product palaver-server
	swift build --package-path $(ENGINE_DIR) --product palaver-worker

e2e-server: test-build ## Build palaver-server and palaver-lm for the e2e tests (the tests' build)

# Only the Python tests of what changed, in parallel (pytest-xdist: a test file's tests stay on one worker, so its
# fixtures, a window's server and the browser, are made once). TEST_WORKERS=0: in order.
TEST_WORKERS ?= $(TEST_JOBS)
PYTEST = uv run --extra dev pytest -q $(if $(filter 0,$(TEST_WORKERS)),,-n $(TEST_WORKERS) --dist loadscope)

eval-engine: ## Local gate on your recordings (needs PALAVER_EVAL_DIR). tools/eval_engine.py's exit: 0 pass, 1 a check FAILED, 2 misconfigured (make itself reports 2 for both)
	@test -n "$$PALAVER_EVAL_DIR" -a -f "$$PALAVER_EVAL_DIR/eval.json" || { echo "eval-engine needs PALAVER_EVAL_DIR: a folder with the local eval.json (see tools/eval_engine.py)" >&2; exit 2; }
	@$(MAKE) --no-print-directory engine
	$(PYTHON) tools/eval_engine.py

eval-engine-worker: ## The same gate through palaver-worker's in-process engine (engine-serve, release build); writes engine-gate-worker.md
	@test -n "$$PALAVER_EVAL_DIR" -a -f "$$PALAVER_EVAL_DIR/eval.json" || { echo "eval-engine-worker needs PALAVER_EVAL_DIR: a folder with the local eval.json (see tools/eval_engine.py)" >&2; exit 2; }
	@$(MAKE) --no-print-directory $(VENDOR)/.patched
	swift build -c release --package-path $(ENGINE_DIR) --product palaver-worker
	$(PYTHON) tools/eval_engine.py --worker $(ENGINE_DIR)/.build/release/palaver-worker

test-changed: ## Run only the Python tests for what changed since master (tools/changed_tests.py)
	@TESTS="$$(python3 tools/changed_tests.py)"; \
		if [ -z "$$TESTS" ]; then echo "nothing changed that a test covers"; else echo "$$TESTS" | tr '\n' ' '; echo; $(PYTEST) $$TESTS; fi

icons: ## Draw the app and menu bar icons into native/Bundle (needs Pillow)
	uv run --extra dev python tools/make_icons.py

# Release assets (#60), built on this Mac: the app (the Swift programs, no Python), the placeholder runtime the
# updaters before 0.6 need (a few hundred bytes, uploaded once), manifest.json and install.sh.
PYTHON ?= uv run python
BUILD_RELEASE = $(PYTHON) tools/build_release.py
BUILD_ARGS = --dist $(DIST)
LATEST_MANIFEST = https://github.com/kenodressel/palaver/releases/latest/download/manifest.json
PREVIOUS_MANIFEST ?= $(DIST)/previous-manifest.json
# This release's notes: the manifest's (the app's update shows them) and the GitHub release's.
NOTES = docs/release-notes/$(VERSION).md

# The `palaver` command (phase 4): Contents/Resources/bin/palaver, which ~/.local/bin/palaver links to.
cli: $(VENDOR)/.patched ## Build the palaver command (native/.build/release/palaver-cli)
	swift build -c release --package-path $(ENGINE_DIR) --product palaver-cli
	@test -x $(ENGINE_DIR)/.build/release/palaver-cli || { echo "✗ palaver-cli was not built"; exit 1; }
	$(call no-build-paths,$(ENGINE_DIR)/.build/release/palaver-cli)

compat-runtime: ## Write the placeholder runtime the updaters before 0.6 need (the same bytes every build)
	$(BUILD_RELEASE) compat-runtime $(BUILD_ARGS)

models: ## Nothing to pack: Palaver hosts no models (kept so old scripts work)
	$(BUILD_RELEASE) models $(BUILD_ARGS)

app: engine app-swift server worker lm cli ## Build Palaver.app (the Swift programs and the palaver command; no Python), zipped
	$(BUILD_RELEASE) app $(BUILD_ARGS)

manifest: ## Write manifest.json and upload.txt over the assets in dist/
	@curl -fsSL -o "$(DIST)/previous-manifest.json" "$(LATEST_MANIFEST)" 2>/dev/null \
		|| rm -f "$(DIST)/previous-manifest.json"
	$(BUILD_RELEASE) manifest $(BUILD_ARGS) $$(test -f "$(PREVIOUS_MANIFEST)" && echo --previous "$(PREVIOUS_MANIFEST)") \
		$$(test -f "$(NOTES)" && echo --notes "$(NOTES)")

release: app compat-runtime manifest ## All release assets in dist/ (upload.txt: what to upload)
	@cp install.sh $(DIST)/install.sh
	@ls -lh $(DIST) | grep -v "^d"

smoke-install: ## Install dist/ into a throwaway HOME, check it, and simulate an update
	sh tools/smoke_install.sh "$(CURDIR)/$(DIST)" "$(PYTHON)"

# Ad hoc signatures differ every build, and macOS asks testers for the
# microphone and system audio again after each update: a release is signed
# with the kept certificate (CONTRIBUTING.md, "Signing releases").
publish: ## Create the GitHub release of this version from dist/upload.txt (the fallback: a pushed tag does it on CI)
	@test -n "$$PALAVER_SIGN_IDENTITY" \
		|| { echo "✗ publish needs PALAVER_SIGN_IDENTITY (and make release built with it)"; exit 1; }
	@test -s "$(NOTES)" || { echo "✗ $(NOTES) is missing: every release has its notes"; exit 1; }
	@T=$$(mktemp -d); ditto -xk "$(DIST)/palaver-app-$(VERSION).zip" "$$T" || exit 1; \
		if codesign -dv "$$T/Palaver.app" 2>&1 | grep -q "Signature=adhoc"; then rm -rf "$$T"; \
			echo "✗ dist/palaver-app-$(VERSION).zip is signed ad hoc: run make release with PALAVER_SIGN_IDENTITY set"; \
			exit 1; fi; rm -rf "$$T"
	cd $(DIST) && gh release create "v$(VERSION)" --repo kenodressel/palaver --title "Palaver $(VERSION)" \
		--notes-file "$(CURDIR)/$(NOTES)" --generate-notes --latest $$(cat upload.txt)

clean: ## Remove build output
	rm -rf $(DIST) build

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
