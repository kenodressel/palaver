#!/bin/sh
set -eu

# Palaver installer — and updater: run it again to update.
#
#   curl -fsSL https://raw.githubusercontent.com/kenodressel/palaver/master/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --autostart --cli
#
# Installs the latest release into your home folder, nothing else:
#   ~/Applications/Palaver.app                               the app (Palaver's code)
#   ~/Library/Application Support/palaver/runtime/<id>/      its Python and libraries (~1.5 GB),
#                                                            downloaded again only when they change
# No Homebrew, no system Python, no PATH or shell changes. The models
# (speech, speakers, notes) are downloaded by the app's setup assistant,
# with your OK and with progress.
#
# Options:
#   --autostart    start Palaver at login
#   --cli          link the `palaver` command into ~/.local/bin (when that is on your PATH)
#   --uninstall    remove the app, its runtime, the login item and the command;
#                  recordings, settings and models stay (add --models to remove the models too)
#
# Environment:
#   PALAVER_VERSION=0.2.0     install that release instead of the latest
#   PALAVER_ASSETS_DIR=dist   install from local release assets (no download; for testing)

REPO="kenodressel/palaver"
RELEASES="https://github.com/${REPO}/releases"
BUNDLE_ID="com.kenodressel.meeting-transcribe"
APPS="${HOME}/Applications"
APP="${APPS}/Palaver.app"
OLD_APP="${APPS}/Meeting Transcribe.app"  # its name before; same app
SUPPORT="${HOME}/Library/Application Support/palaver"
RUNTIMES="${SUPPORT}/runtime"
MODELS="${SUPPORT}/models"
AGENT="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"
BIN_DIR="${HOME}/.local/bin"
ASSETS_DIR="${PALAVER_ASSETS_DIR:-${MT_ASSETS_DIR:-}}"
VERSION="${PALAVER_VERSION:-${MT_VERSION:-}}"

# Everything runs from main(), called on the last line: a download cut
# short (curl | sh) defines functions and runs nothing.

AUTOSTART=0
CLI=0
UNINSTALL=0
UNINSTALL_MODELS=0
parse_args() {
  for arg in "$@"; do
    case "${arg}" in
      --autostart) AUTOSTART=1 ;;
      --cli) CLI=1 ;;
      --uninstall) UNINSTALL=1 ;;
      --models) UNINSTALL_MODELS=1 ;;
      -h|--help) sed -n '3,26p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) printf "Unknown option: %s\n" "${arg}" >&2; exit 2 ;;
    esac
  done
}

if [ -t 1 ]; then
  BOLD="$(printf '\033[1m')"; RED="$(printf '\033[31m')"; GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"; CYAN="$(printf '\033[36m')"; RESET="$(printf '\033[0m')"
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; CYAN=""; RESET=""
fi
info() { printf "%s==>%s %s\n" "${CYAN}${BOLD}" "${RESET}" "$*"; }
success() { printf "%s==>%s %s\n" "${GREEN}${BOLD}" "${RESET}" "$*"; }
warn() { printf "%sWarning:%s %s\n" "${YELLOW}${BOLD}" "${RESET}" "$*" >&2; }
error() { printf "%sError:%s %s\n" "${RED}${BOLD}" "${RESET}" "$*" >&2; exit 1; }

check_mac() {
  [ "$(uname -s)" = "Darwin" ] || error "Palaver runs on macOS only."
  [ "$(uname -m)" = "arm64" ] || error "Palaver needs a Mac with Apple Silicon (M1 or later)."
}

# --- helpers -----------------------------------------------------------------------------------

# A value from a JSON file: plutil reads JSON on every macOS Palaver supports.
# Nothing for a missing key: macOS 15's plutil prints its error on stdout.
json() { _v="$(plutil -extract "$2" raw -o - "$1" 2>/dev/null)" && printf '%s' "${_v}"; }

WAIT_SECONDS="${PALAVER_WAIT_SECONDS:-10}"
OPEN_COMMAND="${PALAVER_OPEN_COMMAND:-open}"
WAS_RUNNING=0

app_running() {
  pgrep -f "${APP}/Contents/MacOS/palaver-launcher" >/dev/null 2>&1 \
    || pgrep -f "${OLD_APP}/Contents/MacOS/" >/dev/null 2>&1
}

# What Palaver is doing that an update must not cut off; nothing when idle.
busy_reason() {
  state="${SUPPORT}/daemon.json"
  pid="$(json "${state}" pid || true)"
  if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
    [ "$(json "${state}" state)" = "recording" ] && { echo "recording a meeting"; return; }
    [ "$(json "${state}" transcribing)" = "true" ] && { echo "transcribing a meeting"; return; }
    [ "$(json "${state}" queued || echo 0)" -gt 0 ] 2>/dev/null && { echo "transcribing a meeting"; return; }
    [ -n "$(json "${state}" writing_notes || true)" ] && { echo "writing notes"; return; }
    [ "$(json "${state}" notes_queued || echo 0)" -gt 0 ] 2>/dev/null && { echo "writing notes"; return; }
  fi
  # A transcription or notes helper of the app (the menu bar app, the window's
  # server and the search index stop with it).
  if pgrep -lf "${APP}/Contents/MacOS/Palaver -m palaver" 2>/dev/null \
      | grep -vqE ' (menubar|webapp-serve|index)( |$)'; then
    echo "processing a meeting"
  fi
}

# Wait while Palaver records or processes; then quit only the menu bar app
# (SIGTERM through its launcher, as the menu's Quit) and wait as long as it
# takes until nothing of it runs. Its helpers are never killed.
quit_app() {
  app_running || pgrep -f "${APP}/Contents/MacOS/" >/dev/null 2>&1 || return 0
  app_running && WAS_RUNNING=1
  told=""
  while reason="$(busy_reason)" && [ -n "${reason}" ]; do
    if [ "${told}" != "${reason}" ]; then
      info "Palaver is ${reason}: this waits until it is done (Ctrl-C stops here; nothing has changed yet)."
      told="${reason}"
    fi
    sleep "${WAIT_SECONDS}"
  done
  if app_running; then
    info "Quitting Palaver..."
    pkill -TERM -f "${APP}/Contents/MacOS/palaver-launcher" >/dev/null 2>&1 || true
    pkill -TERM -f "${OLD_APP}/Contents/MacOS/" >/dev/null 2>&1 || true
  fi
  n=0
  while app_running || pgrep -f "${APP}/Contents/MacOS/" >/dev/null 2>&1; do
    n=$((n + 1))
    [ "${n}" = "60" ] && info "Waiting for Palaver to finish quitting..."
    sleep 0.5
  done
}

reopen_app() {
  if [ "${WAS_RUNNING}" = "1" ]; then
    "${OPEN_COMMAND}" "${APP}" || warn "Palaver did not open; open it from ~/Applications."
  fi
}

# The command link is ours when it points into the app or the venv of the installer before.
our_link() {
  [ -L "${BIN_DIR}/palaver" ] || return 1
  case "$(readlink "${BIN_DIR}/palaver")" in
    "${APP}/"*|"${SUPPORT}/venv/"*) return 0 ;;
    *) return 1 ;;
  esac
}

on_path() { case ":${PATH}:" in *":${BIN_DIR}:"*) return 0 ;; *) return 1 ;; esac; }

# https only, also after a redirect.
download() { curl --proto '=https' --proto-redir '=https' -fL --retry 3 "$@"; }

# Unpackings that never finished (a crash, a lost power), older than an hour.
sweep_stale() {
  for found in "${RUNTIMES}:.*" "${MODELS}:.*" "${SUPPORT}:.install.*" "${APPS}:.Palaver.app.*"; do
    dir="${found%%:*}"
    [ -d "${dir}" ] || continue
    find "${dir}" -mindepth 1 -maxdepth 1 -type d -name "${found#*:}" -mmin +60 -exec rm -rf {} + 2>/dev/null || true
  done
}

# A link in the unpacked runtime that points out of it; nothing when all stay inside.
link_out_of() {
  root="$(cd "$1" && pwd -P)"
  find "$1" -type l | while IFS= read -r link; do
    target="$(readlink -f "${link}" 2>/dev/null || true)"
    case "${target}" in
      "${root}"/*) ;;
      *) echo "${link}"; break ;;
    esac
  done
}

# --- uninstall ---------------------------------------------------------------------------------

uninstall() {
  quit_app
  rm -rf "${APP}" "${OLD_APP}" "${RUNTIMES}" "${SUPPORT}/venv" "${SUPPORT}/updates" "${SUPPORT}/update.json"
  rm -f "${AGENT}"
  if our_link; then rm -f "${BIN_DIR}/palaver"; fi
  if [ "${UNINSTALL_MODELS}" = "1" ]; then rm -rf "${MODELS}"; fi
  success "Palaver is removed."
  printf "Kept: your recordings, settings (~/.config/palaver) and Palaver's data in\n  %s\n" "${SUPPORT}"
  [ "${UNINSTALL_MODELS}" = "1" ] || printf "The models stay too; remove them with --uninstall --models.\n"
  printf "Models downloaded from Hugging Face (Parakeet, the notes model) are in ~/.cache/huggingface.\n"
}

# --- the release -------------------------------------------------------------------------------

# fetch NAME URL SHA256 SIZE: the asset into $TMP, its checksum checked.
fetch() {
  if [ -n "${ASSETS_DIR}" ]; then
    [ -f "${ASSETS_DIR}/$1" ] || error "$1 is not in ${ASSETS_DIR}."
    cp "${ASSETS_DIR}/$1" "${TMP}/$1"
  else
    download --progress-bar -o "${TMP}/$1" "$2" || error "Download of $1 failed."
  fi
  got="$(shasum -a 256 "${TMP}/$1" | cut -d' ' -f1)"
  [ "${got}" = "$3" ] || { rm -f "${TMP}/$1"; error "$1 arrived damaged (checksum mismatch). Nothing was changed; try again."; }
}

install() {
mkdir -p "${SUPPORT}"
sweep_stale
TMP="$(mktemp -d "${SUPPORT}/.install.XXXXXX")"  # in the home folder: nothing is written elsewhere
trap 'rm -rf "${TMP}"' EXIT

if [ -n "${ASSETS_DIR}" ]; then
  info "Using local release assets from ${ASSETS_DIR}"
  cp "${ASSETS_DIR}/manifest.json" "${TMP}/manifest.json" || error "No manifest.json in ${ASSETS_DIR}."
else
  if [ -n "${VERSION}" ]; then
    URL="${RELEASES}/download/v${VERSION#v}/manifest.json"
  else
    URL="${RELEASES}/latest/download/manifest.json"
  fi
  download -sS -o "${TMP}/manifest.json" "${URL}" || error "Could not get ${URL}."
fi
M="${TMP}/manifest.json"
[ "$(json "${M}" schema)" = "1" ] || error "This release needs a newer installer: run the command from the README again."
NEW_VERSION="$(json "${M}" version)"
MIN_MACOS="$(json "${M}" minimum_macos)"
MACOS="$(sw_vers -productVersion)"
[ "$(printf '%s\n%s\n' "${MIN_MACOS}" "${MACOS}" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "${MIN_MACOS}" ] \
  || error "Palaver ${NEW_VERSION} needs macOS ${MIN_MACOS} or later (this Mac has ${MACOS})."

OLD_VERSION="$(json "${APP}/Contents/Resources/runtime.json" version || true)"
OLD_RUNTIME="$(json "${APP}/Contents/Resources/runtime.json" runtime || true)"
if [ -n "${OLD_VERSION}" ]; then
  info "Updating Palaver ${OLD_VERSION} to ${NEW_VERSION}"
else
  info "Installing Palaver ${NEW_VERSION}"
fi

# --- the runtime: only when this release needs another one ---------------------------------------

RUNTIME_ID="$(json "${M}" runtime.id)"
case "${RUNTIME_ID}" in ""|*/*|.*) error "The release names no valid runtime." ;; esac
if [ -x "${RUNTIMES}/${RUNTIME_ID}/bin/python3" ]; then
  info "Its runtime ${RUNTIME_ID} is here already: not downloaded again."
else
  NAME="$(json "${M}" runtime.name)"
  SIZE="$(json "${M}" runtime.size)"
  info "Downloading its runtime (Python and libraries, $((SIZE / 1000000)) MB; once, until they change)..."
  fetch "${NAME}" "$(json "${M}" runtime.url)" "$(json "${M}" runtime.sha256)"
  mkdir -p "${RUNTIMES}"
  STAGE="$(mktemp -d "${RUNTIMES}/.${RUNTIME_ID}.XXXXXX")"
  info "Unpacking the runtime..."
  tar -xf "${TMP}/${NAME}" -C "${STAGE}" || { rm -rf "${STAGE}"; error "The runtime archive can't be unpacked."; }
  rm -f "${TMP}/${NAME}"
  [ -x "${STAGE}/${RUNTIME_ID}/bin/python3" ] || { rm -rf "${STAGE}"; error "The runtime archive is incomplete."; }
  OUT="$(link_out_of "${STAGE}/${RUNTIME_ID}")"
  [ -z "${OUT}" ] || { rm -rf "${STAGE}"; error "The runtime archive has a link out of its folder (${OUT##*/}); nothing was changed."; }
  rm -rf "${RUNTIMES:?}/${RUNTIME_ID}"
  mv "${STAGE}/${RUNTIME_ID}" "${RUNTIMES}/${RUNTIME_ID}"
  rm -rf "${STAGE}"
fi

# --- the app ---------------------------------------------------------------------------------

NAME="$(json "${M}" app.name)"
fetch "${NAME}" "$(json "${M}" app.url)" "$(json "${M}" app.sha256)"
ditto -xk "${TMP}/${NAME}" "${TMP}/app" || error "The app archive can't be unpacked."
[ "$(json "${TMP}/app/Palaver.app/Contents/Resources/runtime.json" runtime)" = "${RUNTIME_ID}" ] \
  || error "The app in this release does not match its runtime."
xattr -dr com.apple.quarantine "${TMP}/app/Palaver.app" 2>/dev/null || true

quit_app
mkdir -p "${APPS}"
NEW="$(mktemp -d "${APPS}/.Palaver.app.XXXXXX")"
mv "${TMP}/app/Palaver.app" "${NEW}/Palaver.app"
if [ -e "${APP}" ]; then
  mv "${APP}" "${NEW}/old.app"
fi
if mv "${NEW}/Palaver.app" "${APP}"; then
  rm -rf "${NEW}"
else
  [ -e "${NEW}/old.app" ] && mv "${NEW}/old.app" "${APP}"
  rm -rf "${NEW}"
  reopen_app
  error "Palaver.app could not be replaced; the version before stays."
fi
rm -rf "${OLD_APP}"
# A new build is a new signature to macOS: Palaver asks for its permissions at its next start, not mid-call.
rm -f "${SUPPORT}/permissions-requested"

# The runtime in use and the one before it (to go back with PALAVER_VERSION) stay; older ones go.
if [ -n "${OLD_RUNTIME}" ] && [ "${OLD_RUNTIME}" != "${RUNTIME_ID}" ]; then
  printf '%s\n' "${OLD_RUNTIME}" > "${RUNTIMES}/.previous"
fi
PREVIOUS="$(cat "${RUNTIMES}/.previous" 2>/dev/null || true)"
for dir in "${RUNTIMES}"/*; do
  [ -d "${dir}" ] || continue
  id="$(basename "${dir}")"
  if [ "${id}" != "${RUNTIME_ID}" ] && [ "${id}" != "${PREVIOUS}" ]; then
    rm -rf "${dir}"
  fi
done
# The installer before this one made a venv (and a command into it) with uv; the runtime replaces it.
rm -rf "${SUPPORT}/venv" "${HOME}/Library/Application Support/meeting-transcribe/venv"
if [ -L "${BIN_DIR}/meeting-transcribe" ]; then rm -f "${BIN_DIR}/meeting-transcribe"; fi

# --- the command and the login item ------------------------------------------------------------

if our_link; then
  ln -sfn "${APP}/Contents/Resources/bin/palaver" "${BIN_DIR}/palaver"
elif [ "${CLI}" = "1" ]; then
  if [ -e "${BIN_DIR}/palaver" ] || [ -L "${BIN_DIR}/palaver" ]; then
    warn "${BIN_DIR}/palaver is not Palaver's: left as it is. Palaver's command is ${APP}/Contents/Resources/bin/palaver."
  elif on_path; then
    mkdir -p "${BIN_DIR}"
    ln -s "${APP}/Contents/Resources/bin/palaver" "${BIN_DIR}/palaver"
    info "The palaver command is linked into ${BIN_DIR}."
  else
    warn "${BIN_DIR} is not on your PATH: the palaver command was not linked. The app works without it."
  fi
fi

if [ "${AUTOSTART}" = "1" ] || [ -f "${AGENT}" ]; then
  mkdir -p "$(dirname "${AGENT}")"
  # printf, not a here-document: sh writes those to /tmp, and this installer writes only into your home.
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0">' '<dict>' \
    "	<key>Label</key><string>${BUNDLE_ID}</string>" \
    '	<key>ProgramArguments</key>' \
    "	<array><string>/usr/bin/open</string><string>-g</string><string>-a</string><string>${APP}</string></array>" \
    '	<key>RunAtLoad</key><true/>' '</dict>' '</plist>' > "${AGENT}"
  plutil -lint "${AGENT}" >/dev/null || error "The login item could not be written."
  info "Palaver starts at login."
fi

if [ -n "${OLD_VERSION}" ]; then
  success "Updated Palaver to ${NEW_VERSION}."
else
  success "Installed Palaver ${NEW_VERSION}."
  printf "\nNext: open Palaver (in ~/Applications, or: open -a Palaver).\n"
  printf "Its setup assistant downloads the models it needs, with your OK, and asks for the\n"
  printf "Microphone and System Audio Recording permissions.\n"
fi
reopen_app
}

main() {
  parse_args "$@"
  check_mac
  if [ "${UNINSTALL}" = "1" ]; then
    uninstall
  else
    install
  fi
}

main "$@"
