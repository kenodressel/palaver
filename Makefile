# One build recipe for local use and CI (.github/workflows/*.yml only call make).
AEC_DIR = palaver/_vendored/webrtc_aec
AEC_LIB = $(AEC_DIR)/libraven_aec.dylib
DIST = dist

.PHONY: aec test wheel requirements icons runtime models app manifest release smoke-install publish clean help

# CMakeLists.txt writes the dylib straight into $(AEC_DIR).
$(AEC_LIB):
	cmake -S $(AEC_DIR) -B $(AEC_DIR)/build -DCMAKE_BUILD_TYPE=Release
	cmake --build $(AEC_DIR)/build
	@test -f $(AEC_LIB) || { echo "✗ $(AEC_LIB) was not built"; exit 1; }

aec: $(AEC_LIB) ## Build the vendored WebRTC echo-cancellation library

test: aec ## Run the test suite
	uv run --extra dev pytest -q

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
# changes), the hosted models, manifest.json and install.sh.
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

models: ## Pack the models Palaver hosts (pyannote) with their licenses
	$(BUILD_RELEASE) models $(BUILD_ARGS)

app: wheel requirements ## Build Palaver.app with the wheel's code inside, zipped
	$(BUILD_RELEASE) app $(BUILD_ARGS)

manifest: ## Write manifest.json and upload.txt over the assets in dist/
	@curl -fsSL -o "$(DIST)/previous-manifest.json" "$(LATEST_MANIFEST)" 2>/dev/null \
		|| rm -f "$(DIST)/previous-manifest.json"
	$(BUILD_RELEASE) manifest $(BUILD_ARGS) $$(test -f "$(PREVIOUS_MANIFEST)" && echo --previous "$(PREVIOUS_MANIFEST)") \
		$$(test -f "$(DIST)/notes.md" && echo --notes "$(DIST)/notes.md")

release: runtime models app manifest ## All release assets in dist/ (upload.txt: what to upload)
	@cp install.sh $(DIST)/install.sh
	@ls -lh $(DIST) | grep -v "^d"

smoke-install: ## Install dist/ into a throwaway HOME, check it, and simulate an update
	sh tools/smoke_install.sh "$(CURDIR)/$(DIST)" "$(PYTHON)"

VERSION = $(shell sed -n 's/^__version__ = "\(.*\)"/\1/p' palaver/__init__.py)

# Ad hoc signatures differ every build, and macOS asks testers for the
# microphone and system audio again after each update: a release is signed
# with the kept certificate (README, "Signing releases").
publish: ## Create the GitHub release of this version from dist/upload.txt (needs gh and PALAVER_SIGN_IDENTITY)
	@test -n "$$PALAVER_SIGN_IDENTITY" \
		|| { echo "✗ publish needs PALAVER_SIGN_IDENTITY (and make release built with it)"; exit 1; }
	@T=$$(mktemp -d); ditto -xk "$(DIST)/palaver-app-$(VERSION).zip" "$$T" || exit 1; \
		if codesign -dv "$$T/Palaver.app" 2>&1 | grep -q "Signature=adhoc"; then rm -rf "$$T"; \
			echo "✗ dist/palaver-app-$(VERSION).zip is signed ad hoc: run make release with PALAVER_SIGN_IDENTITY set"; \
			exit 1; fi; rm -rf "$$T"
	cd $(DIST) && gh release create "v$(VERSION)" $$(cat upload.txt) --generate-notes

clean: ## Remove build output (the runtime archive too: it takes minutes to build again)
	rm -rf $(DIST) build $(AEC_DIR)/build

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
