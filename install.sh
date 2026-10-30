#!/bin/sh
set -euo pipefail

# Palaver installer
#
#   curl -fsSL https://raw.githubusercontent.com/kenodressel/palaver/master/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --autostart      # also start at login
#
# Installs the latest GitHub release:
#   - a Python venv with exactly the locked dependencies (via uv) in
#     ~/Library/Application Support/palaver/venv
#   - the `palaver` command in ~/.local/bin
#   - Palaver.app (menu bar app) in ~/Applications
#
# Environment overrides:
#   MT_VERSION=v0.2.0      install a specific release instead of the latest
#   MT_ASSETS_DIR=./dist   install from local release assets (no download)

REPO="kenodressel/palaver"
APP_NAME="Palaver.app"
OLD_APP_NAME="Meeting Transcribe.app"  # its name before; same app
APP_ZIP="Palaver.zip"
INSTALL_DIR="${HOME}/Applications"
SUPPORT_DIR="${HOME}/Library/Application Support/palaver"
VENV="${SUPPORT_DIR}/venv"
BIN_DIR="${HOME}/.local/bin"
CONFIG="${XDG_CONFIG_HOME:-${HOME}/.config}/palaver/config.toml"
PYTHON_VERSION="3.13"

AUTOSTART=0
for arg in "$@"; do
  case "${arg}" in
    --autostart) AUTOSTART=1 ;;
    *) printf "Unknown option: %s\n" "${arg}" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
  BOLD="$(printf '\033[1m')"
  RED="$(printf '\033[31m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  CYAN="$(printf '\033[36m')"
  RESET="$(printf '\033[0m')"
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; CYAN=""; RESET=""
fi

info() { printf "%s==>%s %s%s\n" "${CYAN}${BOLD}" "${RESET}" "$*" "${RESET}"; }
success() { printf "%s==>%s %s%s\n" "${GREEN}${BOLD}" "${RESET}" "$*" "${RESET}"; }
warn() { printf "%sWarning:%s %s%s\n" "${YELLOW}${BOLD}" "${RESET}" "$*" "${RESET}" >&2; }
error() { printf "%sError:%s %s%s\n" "${RED}${BOLD}" "${RESET}" "$*" "${RESET}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# System checks
# ---------------------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || error "Palaver requires macOS."
[ "$(uname -m)" = "arm64" ] || error "Palaver requires Apple Silicon (arm64)."
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "${MACOS_MAJOR}" -ge 15 ] || error "Palaver requires macOS 15 or later (found $(sw_vers -productVersion))."

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ---------------------------------------------------------------------------
# uv (installs Python and the locked dependencies)
# ---------------------------------------------------------------------------

if command -v uv >/dev/null 2>&1; then
  UV="$(command -v uv)"
elif [ -x "${HOME}/.local/bin/uv" ]; then
  UV="${HOME}/.local/bin/uv"
else
  info "Installing uv (Python package manager, https://docs.astral.sh/uv/)..."
  curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh >/dev/null
  UV="${HOME}/.local/bin/uv"
  [ -x "${UV}" ] || error "uv installation failed."
fi

# ---------------------------------------------------------------------------
# Release assets
# ---------------------------------------------------------------------------

if [ -n "${MT_ASSETS_DIR:-}" ]; then
  info "Using local release assets from ${MT_ASSETS_DIR}"
  cp "${MT_ASSETS_DIR}"/palaver-*.whl "${MT_ASSETS_DIR}/requirements.txt" \
    "${MT_ASSETS_DIR}/${APP_ZIP}" "${TMP}/"
else
  TAG="${MT_VERSION:-}"
  if [ -z "${TAG}" ]; then
    TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1 || true)"
  fi
  if [ -n "${TAG}" ] && curl -fsSL -o "${TMP}/requirements.txt" \
      "https://github.com/${REPO}/releases/download/${TAG}/requirements.txt" 2>/dev/null; then
    info "Downloading Palaver ${TAG}..."
    WHEEL="palaver-${TAG#v}-py3-none-any.whl"
    curl -fsSL -o "${TMP}/${WHEEL}" "https://github.com/${REPO}/releases/download/${TAG}/${WHEEL}" \
      || error "Download of ${WHEEL} failed."
    curl -fsSL -o "${TMP}/${APP_ZIP}" "https://github.com/${REPO}/releases/download/${TAG}/${APP_ZIP}" \
      || error "Download of ${APP_ZIP} failed."
  elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    # Private repository: anonymous downloads fail, the GitHub CLI's login works.
    info "Downloading Palaver ${TAG:-(latest)} via the GitHub CLI..."
    gh release download ${TAG:+"${TAG}"} --repo "${REPO}" --dir "${TMP}" \
      --pattern "palaver-*.whl" --pattern requirements.txt --pattern "${APP_ZIP}" \
      || error "gh release download failed."
  else
    error "Could not download the release. If the repository is private, install the GitHub CLI and run 'gh auth login' first."
  fi
fi

WHEEL_PATH="$(ls "${TMP}"/palaver-*.whl | head -1)"

# ---------------------------------------------------------------------------
# Python environment
# ---------------------------------------------------------------------------

info "Installing Python ${PYTHON_VERSION} and the locked dependencies (~1 GB on first install)..."
mkdir -p "${SUPPORT_DIR}"
"${UV}" venv --quiet --clear --python "${PYTHON_VERSION}" "${VENV}"
"${UV}" pip install --quiet --python "${VENV}/bin/python" -r "${TMP}/requirements.txt" "${WHEEL_PATH}"
"${VENV}/bin/python" -I -c "import palaver.aec as a; a._load_lib()" \
  || error "The echo-cancellation library in the wheel does not load."

mkdir -p "${BIN_DIR}"
ln -sf "${VENV}/bin/palaver" "${BIN_DIR}/palaver"
case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *) warn "${BIN_DIR} is not on your PATH — add it to use the palaver command." ;;
esac

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

info "Installing ${APP_NAME}..."
AGENT="${HOME}/Library/LaunchAgents/com.kenodressel.meeting-transcribe.plist"
for NAME in "${APP_NAME}" "${OLD_APP_NAME}"; do
  LAUNCHER="${INSTALL_DIR}/${NAME}/Contents/MacOS/"  # the old app's launcher had another name
  if pgrep -f "${LAUNCHER}" >/dev/null 2>&1; then
    # SIGTERM reaches the app through the launcher; it finalizes a running
    # recording before exiting.
    pkill -TERM -f "${LAUNCHER}" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -f "${LAUNCHER}" >/dev/null 2>&1 || break
      sleep 1
    done
  fi
  rm -rf "${INSTALL_DIR:?}/${NAME}"
done
# Under its old name the app had its own Python and command; its settings
# move to the new folders when Palaver first starts.
rm -rf "${HOME}/Library/Application Support/meeting-transcribe/venv"
if [ -L "${BIN_DIR}/meeting-transcribe" ]; then rm -f "${BIN_DIR}/meeting-transcribe"; fi
mkdir -p "${INSTALL_DIR}"
ditto -xk "${TMP}/${APP_ZIP}" "${INSTALL_DIR}"
xattr -dr com.apple.quarantine "${INSTALL_DIR}/${APP_NAME}" 2>/dev/null || true

# An agent from before may still open the app under its old name.
if [ "${AUTOSTART}" = "1" ] || [ -f "${AGENT}" ]; then
  "${VENV}/bin/palaver" app autostart on >/dev/null
  info "Palaver will start at login."
fi

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

if [ ! -f "${CONFIG}" ]; then
  mkdir -p "$(dirname "${CONFIG}")"
  cat > "${CONFIG}" <<'TOML'
[user]
name = "Your Name"

[notion]
# token = "ntn_..."          # or set NOTION_TOKEN, or store it in the Keychain
parent_page_id = "<notion-page-id>"

[hf]
# token = "hf_..."           # pyannote's diarization model is gated

[recording]
output_dir = "~/Meetings/Recordings"
retention_days = 14
TOML
  chmod 600 "${CONFIG}"
  warn "Created ${CONFIG} — fill in your name, Notion page and tokens."
fi

success "Installed Palaver $("${VENV}/bin/python" -I -c 'import palaver as m; print(m.__version__)')"
printf "\nNext steps:\n"
printf "  1. palaver doctor          # checks config, tokens and permissions\n"
printf "  2. open -a \"Palaver\"       # allow Microphone and System Audio Recording\n"
printf "\nAfter an update macOS may ask for the permissions again — the app signature changed.\n"
