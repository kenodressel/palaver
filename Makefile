# One build recipe for local use and CI (.github/workflows/*.yml only call make).
AEC_DIR = palaver/_vendored/webrtc_aec
AEC_LIB = $(AEC_DIR)/libraven_aec.dylib
DIST = dist

.PHONY: aec test wheel requirements icons app release smoke-install clean help

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
	uv build --wheel --out-dir $(DIST)
	@WHEEL=$$(ls $(DIST)/palaver-*.whl | head -1); \
		unzip -l "$$WHEEL" | grep -q "webrtc_aec/libraven_aec.dylib" \
		|| { echo "✗ $$WHEEL lacks libraven_aec.dylib"; exit 1; }; \
		echo "✓ $$WHEEL includes the AEC library"

requirements: ## Export the locked dependency set install.sh installs
	@mkdir -p $(DIST)
	uv export --frozen --no-dev --no-emit-project --no-hashes --format requirements-txt \
		-o $(DIST)/requirements.txt >/dev/null
	@echo "✓ $(DIST)/requirements.txt ($$(grep -c '==' $(DIST)/requirements.txt) pinned packages)"

icons: ## Draw the app and menu bar icons into palaver/assets (needs Pillow)
	uv run --with pillow python tools/make_icons.py

app: ## Build the release Palaver.app and zip it
	@mkdir -p $(DIST)
	@rm -rf "$(DIST)/Palaver.app"
	uv run palaver app build-release --dest $(DIST)
	@cd $(DIST) && ditto -ck --keepParent "Palaver.app" Palaver.zip
	@echo "✓ $(DIST)/Palaver.zip"

release: wheel requirements app ## All release assets in dist/
	@cp install.sh $(DIST)/install.sh
	@ls -lh $(DIST)

smoke-install: ## Install dist/ with install.sh into a throwaway HOME and check it
	@T=$$(mktemp -d); trap 'rm -rf "$$T"' EXIT; \
	HOME="$$T" XDG_CONFIG_HOME="$$T/.config" UV_CACHE_DIR="$$(uv cache dir)" \
		UV_PYTHON_INSTALL_DIR="$$(uv python dir)" MT_ASSETS_DIR="$(CURDIR)/$(DIST)" \
		sh $(DIST)/install.sh --autostart >/dev/null; \
	cd "$$T" && "$$T/Library/Application Support/palaver/venv/bin/python" -I -c \
		"import palaver, torch, mlx.core, pyannote.audio, parakeet_mlx, ScreenCaptureKit, CoreAudio, rumps; \
		import palaver.aec as a; a._load_lib(); \
		assert 'site-packages' in palaver.__file__" \
		|| { echo "✗ installed package does not import"; exit 1; }; \
	if strings "$$T/Applications/Palaver.app/Contents/MacOS/palaver-launcher" \
		| grep -q "^/Users/"; then echo "✗ launcher contains build-machine paths"; exit 1; fi; \
	test -L "$$T/.local/bin/palaver" || { echo "✗ CLI not linked"; exit 1; }; \
	test -f "$$T/Library/LaunchAgents/com.kenodressel.meeting-transcribe.plist" \
		|| { echo "✗ autostart agent missing"; exit 1; }; \
	echo "✓ install.sh installs a working venv, CLI, app and autostart agent"

clean: ## Remove build output
	rm -rf $(DIST) build $(AEC_DIR)/build

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
