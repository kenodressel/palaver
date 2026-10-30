#!/bin/sh
# `make smoke-install`: install the release assets in DIST into a throwaway
# home folder, exactly as testers run install.sh, and check the result:
#   - install.sh and everything the installed Palaver runs here writes
#     nothing outside that home and reaches no network (sandbox-exec);
#   - the runtime imports Palaver and its heavy dependencies, as Palaver.app
#     (its main bundle, its name: what the Dock shows);
#   - the launcher finds the runtime by its id; pyannote loads from the
#     hosted copy without a Hugging Face token;
#   - an update (version bumped, app rebuilt) through install.sh downloads
#     no runtime, and one through the app's updater neither.
#
#   sh tools/smoke_install.sh DIST [PYTHON]
set -eu

DIST="$1"
PYTHON="${2:-uv run python}"
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(mktemp -d)"
T="$(cd "${T}" && pwd -P)"
trap 'chmod -R u+w "${T}" 2>/dev/null; rm -rf "${T}"' EXIT
H="${T}/home"
mkdir -p "${H}/tmp" "${H}/.local/bin"
fail() { echo "✗ $*" >&2; exit 1; }
ok() { echo "✓ $*"; }

PROFILE="${T}/sandbox.sb"
cat > "${PROFILE}" <<SB
(version 1)
(allow default)
(deny network-outbound (remote ip))
(deny file-write* (subpath "/"))
(allow file-write* (subpath "${H}") (subpath "/dev"))
SB

# A command as a tester's Mac runs it: this home only, no network.
in_home() {
  cd "${H}" && env -i HOME="${H}" TMPDIR="${H}/tmp/" PATH="${H}/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    HF_HUB_OFFLINE=1 LANG=en_US.UTF-8 "$@"
}
sandboxed() { in_home sandbox-exec -f "${PROFILE}" "$@"; }

APP="${H}/Applications/Palaver.app"
RID="$(plutil -extract runtime.id raw -o - "${DIST}/manifest.json")"
VERSION="$(plutil -extract version raw -o - "${DIST}/manifest.json")"

# --- install --------------------------------------------------------------------------------------
sandboxed env PALAVER_ASSETS_DIR="${DIST}" sh "${DIST}/install.sh" --autostart --cli >"${T}/install.log" 2>&1 \
  || { cat "${T}/install.log"; fail "install.sh failed"; }
RUNTIME="${H}/Library/Application Support/palaver/runtime/${RID}"
[ -x "${RUNTIME}/bin/python3" ] || fail "runtime ${RID} not installed"
[ -L "${H}/.local/bin/palaver" ] || fail "the palaver command is not linked"
[ -f "${H}/Library/LaunchAgents/com.kenodressel.meeting-transcribe.plist" ] || fail "autostart agent missing"
codesign --verify --strict "${APP}" || fail "Palaver.app's signature does not verify"
strings "${APP}/Contents/MacOS/palaver-launcher" | grep -q "Library/Application Support/palaver/runtime/${RID}/bin/python3" \
  || fail "the launcher does not point at runtime ${RID}"
strings "${APP}/Contents/MacOS/Palaver" | grep -q "palaver/runtime/${RID}" \
  || fail "the app's Python host does not point at runtime ${RID}"
if strings "${APP}/Contents/MacOS/palaver-launcher" "${APP}/Contents/MacOS/Palaver" | grep -q "^/Users/"; then
  fail "the app contains build-machine paths"
fi
ok "install.sh: runtime ${RID}, Palaver.app ${VERSION}, command, login item; nothing written outside the home"

# --- the runtime, as the app runs it ----------------------------------------------------------------
sandboxed "${H}/.local/bin/palaver" --help >/dev/null || fail "the palaver command does not run"
sandboxed "${APP}/Contents/Resources/bin/python" -c "
import palaver, torch, mlx.core, pyannote.audio, parakeet_mlx, rumps, mlx_lm
import AVFoundation, CoreAudio, ScreenCaptureKit, WebKit, EventKit, Vision, Foundation, AppKit
import palaver.aec as a; a._load_lib()
assert palaver.__file__.startswith('${APP}/Contents/Resources/python/'), palaver.__file__
assert palaver.__version__ == '${VERSION}', palaver.__version__
from Foundation import NSBundle
from AppKit import NSApplication, NSRunningApplication
NSApplication.sharedApplication()  # as rumps does: the process is an app now (LSUIElement: no Dock icon yet)
assert NSBundle.mainBundle().bundleIdentifier() == 'com.kenodressel.meeting-transcribe', NSBundle.mainBundle().bundlePath()
assert NSRunningApplication.currentApplication().localizedName() == 'Palaver'
import sys
assert sys.executable == '${APP}/Contents/MacOS/Palaver', sys.executable
assert sys.prefix == '${RUNTIME}', sys.prefix
assert sys.version_info >= (3, 13, 4), sys.version  # tarfile's CVE fixes
" 2>"${T}/imports.log" || { grep -v "^ " "${T}/imports.log" | tail -5; fail "the installed runtime does not import Palaver and its dependencies"; }
ok "imports palaver, torch, mlx, pyannote.audio, parakeet_mlx, rumps and the PyObjC frameworks, as Palaver.app (Dock name \"Palaver\")"

# --- the hosted pyannote copy, loaded without a token --------------------------------------------------
MODEL="$(ls "${DIST}"/palaver-models-pyannote-community-1-*.tar | head -1)"
sandboxed "${APP}/Contents/Resources/bin/python" -c "
from pathlib import Path
from palaver import model_store
from palaver.diarizer import PyannoteDiarizer
repo = 'pyannote/speaker-diarization-community-1'
version = Path('${MODEL}').stem.rsplit('-', 1)[1]
model_store.install_archive(Path('${MODEL}'), name='pyannote-community-1', version=version)
assert model_store.resolve(repo).startswith('${H}/'), model_store.resolve(repo)
d = PyannoteDiarizer(repo=repo, hf_token=None)
d._ensure_pipeline()
assert d._pipeline is not None
" 2>"${T}/pyannote.log" || { tail -20 "${T}/pyannote.log"; fail "pyannote does not load from the hosted copy"; }
ok "pyannote loads from ~/Library/Application Support/palaver/models without a token, offline"

# --- an update through install.sh: the app only ---------------------------------------------------------
NEXT="${VERSION}.1"
D2="${T}/dist-${NEXT}"
mkdir -p "${D2}"
cp "${DIST}"/palaver-*.whl "${DIST}/requirements.txt" "${D2}/"
cp "${DIST}"/palaver-models-*.tar "${D2}/"
ln "${DIST}/palaver-runtime-${RID}".tar.* "${D2}/"  # for the manifest; removed before installing
(cd "${REPO}" && ${PYTHON} tools/build_release.py app --dist "${D2}" --version "${NEXT}" >/dev/null \
  && ${PYTHON} tools/build_release.py manifest --dist "${D2}" --version "${NEXT}" >/dev/null) \
  || fail "rebuilding the app as ${NEXT} failed"
rm "${D2}/palaver-runtime-${RID}".tar.*  # install.sh must not need it
cp "${DIST}/install.sh" "${D2}/install.sh"
BEFORE="$(stat -f %i "${RUNTIME}")"
sandboxed env PALAVER_ASSETS_DIR="${D2}" sh "${D2}/install.sh" >"${T}/update.log" 2>&1 \
  || { cat "${T}/update.log"; fail "updating with install.sh failed"; }
grep -q "not downloaded again" "${T}/update.log" || fail "install.sh fetched the runtime again"
[ "$(stat -f %i "${RUNTIME}")" = "${BEFORE}" ] || fail "the runtime was replaced"
[ "$(plutil -extract version raw -o - "${APP}/Contents/Resources/runtime.json")" = "${NEXT}" ] \
  || fail "the app was not updated to ${NEXT}"
sandboxed "${H}/.local/bin/palaver" --help >/dev/null || fail "the command does not run after the update"
ok "update to ${NEXT} with install.sh: the app only, the runtime not downloaded again"

# --- an update from inside the app: the app only ----------------------------------------------------------
LAST="${VERSION}.2"
D3="${T}/dist-${LAST}"
mkdir -p "${D3}"
cp "${D2}"/palaver-*.whl "${D2}/requirements.txt" "${D2}"/palaver-models-*.tar "${D3}/"
ln "${DIST}/palaver-runtime-${RID}".tar.* "${D3}/"
(cd "${REPO}" && ${PYTHON} tools/build_release.py app --dist "${D3}" --version "${LAST}" >/dev/null \
  && ${PYTHON} tools/build_release.py manifest --dist "${D3}" --version "${LAST}" --base-url "file://${D3}" >/dev/null) \
  || fail "rebuilding the app as ${LAST} failed"
rm "${D3}/palaver-runtime-${RID}".tar.*
# `open` as the new app answers it: it writes its started-ok mark, as the
# menu bar app does after its first tick (else the swap puts the old one back).
OPENER="${H}/open-app"
printf '%s\n' '#!/bin/sh' \
  "plutil -extract version raw -o - \"\$1/Contents/Resources/runtime.json\" > \"${H}/Library/Application Support/palaver/started-ok\"" \
  > "${OPENER}"
chmod +x "${OPENER}"
sandboxed env PALAVER_MANIFEST_URL="file://${D3}/manifest.json" "${APP}/Contents/Resources/bin/python" -c "
import json
from palaver import downloader, release, updater
spawned = []
installer = updater.Installer(open_command='${OPENER}', spawn=spawned.append)
u = updater.Updater(installed=updater.installed_now, fetch_manifest=downloader.fetch_manifest,
                    stage=installer.stage, apply=installer.apply, macos=updater.macos_version())
status = u.check()
assert status['state'] == 'available', status
assert status['available']['runtime'] is False and status['available']['models'] == [], status
assert u.request()
assert u.download()['state'] == 'ready', u.status()
assert u.tick() is True
open('${H}/swap-argv.json', 'w').write(json.dumps(spawned[0]))
" || fail "the in-app update failed"
# The swap runs once the app (here: the python above) has quit, as from the app.
SWAP="$(plutil -extract 1 raw -o - "${H}/swap-argv.json")"
sandboxed /bin/sh "${SWAP}" || fail "the swap script failed"
[ ! -e "${H}/Library/Application Support/palaver/previous-app" ] || fail "the version before was not dropped"
[ "$(plutil -extract version raw -o - "${APP}/Contents/Resources/runtime.json")" = "${LAST}" ] \
  || fail "the app's updater did not install ${LAST}"
[ "$(stat -f %i "${RUNTIME}")" = "${BEFORE}" ] || fail "the app's updater replaced the runtime"
codesign --verify --strict "${APP}" || fail "the updated app's signature does not verify"
ok "update to ${LAST} from inside the app: the app only, swapped after quitting, the runtime kept"

# --- uninstall ------------------------------------------------------------------------------------------
sandboxed sh "${DIST}/install.sh" --uninstall >/dev/null || fail "install.sh --uninstall failed"
[ ! -e "${APP}" ] && [ ! -e "${H}/Library/Application Support/palaver/runtime" ] \
  && [ ! -e "${H}/.local/bin/palaver" ] && [ ! -e "${H}/Library/LaunchAgents/com.kenodressel.meeting-transcribe.plist" ] \
  || fail "install.sh --uninstall left something behind"
[ -d "${H}/Library/Application Support/palaver/models/pyannote-community-1" ] || fail "--uninstall removed the models"
ok "install.sh --uninstall removes the app, runtime, command and login item; the models stay"
