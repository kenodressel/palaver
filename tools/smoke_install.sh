#!/bin/sh
# `make smoke-install`: install the release assets in DIST into a throwaway
# home folder, exactly as testers run install.sh, and check the result:
#   - install.sh and everything the installed Palaver runs here writes
#     nothing outside that home and reaches no network (sandbox-exec);
#   - the runtime imports Palaver and its heavy dependencies, as Palaver.app
#     (its main bundle, its name: what the Dock shows);
#   - the app's executable is the Swift app (Mach-O, linked against Swift; never
#     started here), its Python host palaver-python finds the runtime by its id,
#     and every program in Contents/MacOS is signed;
#   - an update (version bumped, app rebuilt) through install.sh downloads
#     no runtime, and one through the app's updater neither;
#   - 0.3.14's own swap.sh (frozen in that release) installs the new bundle,
#     and puts the version before back when started-ok does not come.
# Not here, as they need the app running (docs/swift-app-manual-check.md):
# `palaver app ping` on app.sock, the window's server (webapp-serve) up.
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
engine_hello() {
  [ "$(printf '%s\n' '{"id":1,"cmd":"hello"}' | sandboxed "${APP}/Contents/MacOS/palaver-engine" --version x 2>/dev/null \
    | grep -c '"ok" *: *true')" = 1 ] || fail "palaver-engine does not answer hello ($1)"
}
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
MACOS="${APP}/Contents/MacOS"
# The Swift app is only looked at, never started: it would ask for the microphone and system audio.
[ "$(plutil -extract CFBundleExecutable raw -o - "${APP}/Contents/Info.plist")" = "Palaver" ] \
  || fail "the bundle's executable is not Palaver"
file "${MACOS}/Palaver" | grep -q "Mach-O 64-bit executable arm64" || fail "Contents/MacOS/Palaver is not an arm64 program"
otool -L "${MACOS}/Palaver" | grep -q "/usr/lib/swift/libswiftCore.dylib" || fail "Contents/MacOS/Palaver is not the Swift app"
[ ! -e "${MACOS}/palaver-launcher" ] || fail "the release still carries the ObjC launcher"
[ -f "${APP}/Contents/Resources/menubar.png" ] || fail "the menu bar icon is missing"
strings "${MACOS}/palaver-python" | grep -q "palaver/runtime/${RID}" \
  || fail "the app's Python host does not point at runtime ${RID}"
engine_hello "after install"
for program in Palaver palaver-python palaver-engine; do
  codesign --verify --strict "${MACOS}/${program}" || fail "${program}'s signature does not verify"
done
if strings "${MACOS}/Palaver" "${MACOS}/palaver-python" | grep -q "^/Users/"; then
  fail "the app contains build-machine paths"
fi
ok "install.sh: runtime ${RID}, Palaver.app ${VERSION} (the Swift app, palaver-python, palaver-engine, all signed), command, login item; nothing written outside the home"

# --- the runtime, as the app runs it ----------------------------------------------------------------
sandboxed "${H}/.local/bin/palaver" --help >/dev/null || fail "the palaver command does not run"
sandboxed "${APP}/Contents/Resources/bin/python" -c "
import palaver, mlx.core, rumps, mlx_lm
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
assert sys.executable == '${APP}/Contents/MacOS/palaver-python', sys.executable
assert sys.prefix == '${RUNTIME}', sys.prefix
assert sys.version_info >= (3, 13, 4), sys.version  # tarfile's CVE fixes
" 2>"${T}/imports.log" || { grep -v "^ " "${T}/imports.log" | tail -5; fail "the installed runtime does not import Palaver and its dependencies"; }
ok "imports palaver, mlx, mlx_lm, rumps and the PyObjC frameworks, as Palaver.app (Dock name \"Palaver\")"

# --- an update through install.sh: the app only ---------------------------------------------------------
# What the app keeps in Application Support survives every update: its state with the queue (a crash
# is recovered from it), the fallback's marker.
SUPPORT="${H}/Library/Application Support/palaver"
printf '%s\n' '{"state": "stopped", "queued": ["'"${H}"'/Meetings/Recordings/2026-11-01T10-00-00"], "cut": null}' \
  > "${SUPPORT}/daemon.json"
cp "${SUPPORT}/daemon.json" "${T}/daemon.json.before"
touch "${SUPPORT}/legacy-app"
# A later version than the one built: rc1 -> rc2, else 0.3.14 -> 0.3.14.1 (the updater rejects 0.5.0rc1.1).
later() { case "$1" in *rc[0-9]*) echo "${1%rc*}rc$(( ${1##*rc} + $2 ))" ;; *) echo "$1.$2" ;; esac; }
NEXT="$(later "${VERSION}" 1)"
D2="${T}/dist-${NEXT}"
mkdir -p "${D2}"
cp "${DIST}"/palaver-*.whl "${DIST}/requirements.txt" "${D2}/"
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
engine_hello "after the update"
ok "update to ${NEXT} with install.sh: the app only, the runtime not downloaded again"

# --- an update from inside the app: the app only ----------------------------------------------------------
LAST="$(later "${VERSION}" 2)"
D3="${T}/dist-${LAST}"
mkdir -p "${D3}"
cp "${D2}"/palaver-*.whl "${D2}/requirements.txt" "${D3}/"
ln "${DIST}/palaver-runtime-${RID}".tar.* "${D3}/"
(cd "${REPO}" && ${PYTHON} tools/build_release.py app --dist "${D3}" --version "${LAST}" >/dev/null \
  && ${PYTHON} tools/build_release.py manifest --dist "${D3}" --version "${LAST}" --base-url "file://${D3}" >/dev/null) \
  || fail "rebuilding the app as ${LAST} failed"
rm "${D3}/palaver-runtime-${RID}".tar.*
# `open` as the new app answers it: it writes its started-ok mark, as the
# app does after its first tick (else the swap puts the old one back). The
# real app is never opened here.
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
cmp -s "${SUPPORT}/daemon.json" "${T}/daemon.json.before" || fail "an update changed daemon.json"
[ -f "${SUPPORT}/legacy-app" ] || fail "an update removed the legacy-app marker"
rm -f "${SUPPORT}/legacy-app"
ok "update to ${LAST} from inside the app: the app only, swapped after quitting, the runtime, daemon.json and the markers kept"

# --- the update from 0.3.14 (the last Python app): its swap.sh, which can never change ---------------
# 0.3.14 writes its own swap script (tests/fixtures/updater_0.3.14/swap.sh.txt, from git 8956274) and
# runs it against the new bundle; here the bundle just installed plays the new one, staged as 0.3.14's
# updater stages it. The real app is never started: `open` is a fake. Success: it writes started-ok as
# the Swift app does at its first tick. Failure: it writes nothing and starts a sleeping stand-in at
# Contents/MacOS/Palaver; 0.3.14 then restores the version before and ends only palaver-launcher, so
# the stand-in is still running afterwards (the Swift app ends itself when its bundle is put aside:
# native/Tests/PalaverDaemonTests/OldSwapTests.swift runs that against this script).
cat > "${T}/render_old_swap.py" <<'PY'
# 0.3.14's Installer.apply, as far as it fills the template: render_old_swap.py SUPPORT APP STAGED OPEN VERSION OUT REPO
import json
import sys
from pathlib import Path

support, app, staged, opener, version, out = sys.argv[1:7]


def sh(value):
    return "'" + str(value).replace("'", "'\\''") + "'"


def failure(error):
    return json.dumps({"state": "failed", "from_swap": True, "error": error,
                       "available": {"version": version}}).replace("'", "")


template = (Path(sys.argv[7]) / "tests/fixtures/updater_0.3.14/swap.sh.txt").read_text()
Path(out).write_text(template.format(
    current="0.3.14", version=version, version_sh=sh(version), pids="999999", target=sh(app), staged=sh(staged),
    keep=sh(Path(support) / "previous-app"), ok=sh(Path(support) / "started-ok"), status=sh(Path(support) / "update.json"),
    open=opener, start_ticks=50,
    not_replaced=failure(f"Palaver {version} could not replace the app; 0.3.14 stays."),
    did_not_start=failure(f"Palaver {version} did not start; 0.3.14 is back.")))
PY
old_swap() {  # old_swap NAME OPENER: 0.3.14's script with the bundle at ${APP} staged again as the new one
  mkdir -p "${H}/staged-$1" "${H}/fastbin"
  ditto "${APP}" "${H}/staged-$1/Palaver.app"
  printf '%s\n' '#!/bin/sh' 'exec /bin/sleep 0.01' > "${H}/fastbin/sleep"  # its 0.2 s waits, shorter
  chmod +x "${H}/fastbin/sleep"
  (cd "${REPO}" && ${PYTHON} "${T}/render_old_swap.py" "${SUPPORT}" "${APP}" "${H}/staged-$1/Palaver.app" "$2" "${LAST}" \
    "${H}/swap-0.3.14-$1.sh" "${REPO}") || fail "rendering 0.3.14's swap.sh failed"
  rm -f "${SUPPORT}/update.json"
  sandboxed env PATH="${H}/fastbin:/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh "${H}/swap-0.3.14-$1.sh"
}
# Success: the new bundle takes the place and stays, the one before goes.
OK_OPENER="${H}/open-writes-started-ok"
printf '%s\n' '#!/bin/sh' \
  "plutil -extract version raw -o - \"\$1/Contents/Resources/runtime.json\" > \"${SUPPORT}/started-ok\"" > "${OK_OPENER}"
chmod +x "${OK_OPENER}"
old_swap ok "${OK_OPENER}" || fail "0.3.14's swap.sh failed although the new app started"
KEPT_INODE="$(stat -f %i "${APP}")"
[ ! -e "${H}/staged-ok/Palaver.app" ] && [ ! -e "${SUPPORT}/previous-app" ] && [ ! -e "${SUPPORT}/update.json" ] \
  || fail "0.3.14's swap.sh did not keep the new app"
codesign --verify --strict "${APP}" || fail "the app 0.3.14's swap.sh installed does not verify"
cmp -s "${SUPPORT}/daemon.json" "${T}/daemon.json.before" || fail "0.3.14's swap.sh changed daemon.json"
# Failure: no started-ok. The version before comes back and update.json says so.
STANDIN_PID="${H}/standin.pid"
NO_OPENER="${H}/open-starts-a-standin"
printf '%s\n' '#!/bin/sh' \
  'if [ "$1" = "'"${APP}"'" ] && [ ! -e "'"${STANDIN_PID}"'" ]; then' \
  "  /bin/sh -c 'while :; do /bin/sleep 0.2; done' \"\$1/Contents/MacOS/Palaver\" </dev/null >/dev/null 2>&1 &" \
  "  echo \$! > \"${STANDIN_PID}\"" \
  'fi' > "${NO_OPENER}"
chmod +x "${NO_OPENER}"
old_swap failed "${NO_OPENER}" || fail "0.3.14's swap.sh failed on its failure branch"
STANDIN="$(cat "${STANDIN_PID}" 2>/dev/null || true)"
STILL_RUNNING=no
if [ -n "${STANDIN}" ] && kill -0 "${STANDIN}" 2>/dev/null; then STILL_RUNNING=yes; kill "${STANDIN}"; fi
[ "$(stat -f %i "${APP}")" = "${KEPT_INODE}" ] || fail "0.3.14's swap.sh did not put the version before back"
grep -q "did not start; 0.3.14 is back" "${SUPPORT}/update.json" || fail "update.json does not say the update failed"
[ ! -e "${SUPPORT}/previous-app" ] && [ ! -e "${SUPPORT}/started-ok" ] || fail "0.3.14's failure branch left files behind"
[ "${STILL_RUNNING}" = yes ] || fail "the stand-in app ended: 0.3.14's failure branch no longer behaves as this smoke assumes"
codesign --verify --strict "${APP}" || fail "the app put back by 0.3.14's swap.sh does not verify"
rm -f "${SUPPORT}/update.json"
ok "update from 0.3.14 with its own swap.sh: kept when started-ok comes; else the version before is back, update.json says so (and the new app must end itself: 0.3.14 ends only palaver-launcher)"

# --- uninstall ------------------------------------------------------------------------------------------
mkdir -p "${H}/Library/Application Support/palaver/models/fluidaudio"  # the engine's models: --uninstall keeps them
sandboxed sh "${DIST}/install.sh" --uninstall >/dev/null || fail "install.sh --uninstall failed"
[ ! -e "${APP}" ] && [ ! -e "${H}/Library/Application Support/palaver/runtime" ] \
  && [ ! -e "${H}/.local/bin/palaver" ] && [ ! -e "${H}/Library/LaunchAgents/com.kenodressel.meeting-transcribe.plist" ] \
  || fail "install.sh --uninstall left something behind"
[ -d "${H}/Library/Application Support/palaver/models/fluidaudio" ] || fail "--uninstall removed the models"
ok "install.sh --uninstall removes the app, runtime, command and login item; the models stay"
