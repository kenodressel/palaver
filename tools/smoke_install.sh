#!/bin/sh
# `make smoke-install`: install the release assets in DIST into a throwaway
# home folder, exactly as testers run install.sh, and check the result:
#   - install.sh and everything the installed Palaver runs here writes
#     nothing outside that home (but Foundation's TemporaryItems staging
#     folder) and reaches no network (sandbox-exec), and no
#     Python runs (python/python3 on PATH only write down that they were run);
#   - no runtime is installed: Palaver.app holds no Python interpreter, no .py
#     file, no palaver-python, only the one-release MCP shim bin/python (a shell
#     script), and no path of this Mac;
#   - the app's executable is the Swift app (Mach-O, linked against Swift; never
#     started here), and every program in Contents/MacOS and the palaver command
#     are signed as 0.5's were (one identity, no hardened runtime yet);
#   - the window's server palaver-server answers /api/ping with its key (started
#     by hand on a free port, as no app runs here) and serves the window's page
#     from Contents/Resources/web, palaver-worker answers its queries and finds
#     the domain's resources (zipf.bin), palaver-lm runs, the palaver command
#     runs and the MCP shim starts `palaver mcp`;
#   - an update (version bumped, app rebuilt) through install.sh downloads only
#     the app, and one through the app's Swift updater (driven by
#     palaver-update-driver, as the app's menu does) too;
#   - 0.3.14's own swap.sh (frozen in that release) installs the new bundle,
#     and puts the version before back when started-ok does not come;
#   - the published 0.3.14 and 0.5.0rc6 apps update with their own updater to a
#     build whose runtime.json and manifest name the placeholder runtime of 0.6:
#     only the app and the placeholder are downloaded;
#   - install.sh --uninstall removes the app, an old runtime, the command and the
#     login item, and keeps the models.
# Not here, as they need the app running (docs/swift-app-manual-check.md):
# `palaver app ping` on app.sock, the window's server started by the app.
#
#   sh tools/smoke_install.sh DIST [PYTHON]
#
# PYTHON (the build's, default `uv run python`) only rebuilds the app at other versions and renders 0.3.14's swap
# script. The old releases' own updaters run on OLD_UPDATER_PYTHON (default: the checkout's .venv), as they ran on
# their runtime.
set -eu

DIST="$1"
PYTHON="${2:-uv run python}"
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
OLD_UPDATER_PYTHON="${PALAVER_OLD_UPDATER_PYTHON:-${REPO}/.venv/bin/python3}"
T="$(mktemp -d)"
T="$(cd "${T}" && pwd -P)"
trap 'pkill -KILL -f "${T}/home/Applications/" 2>/dev/null || true; chmod -R u+w "${T}" 2>/dev/null; rm -rf "${T}"' EXIT
H="${T}/home"
mkdir -p "${H}/tmp" "${H}/.local/bin" "${H}/no-python"
fail() { echo "✗ $*" >&2; exit 1; }
ok() { echo "✓ $*"; }

# A Python found on PATH would write down that it ran: nothing of the installed Palaver may start one.
PYTHON_RAN="${H}/python-ran.txt"
for name in python python3; do
  printf '%s\n' '#!/bin/sh' "echo \"\$0 \$*\" >> '${PYTHON_RAN}'" 'exit 127' > "${H}/no-python/${name}"
  chmod +x "${H}/no-python/${name}"
done
no_python_ran() {
  [ ! -e "${PYTHON_RAN}" ] || { cat "${PYTHON_RAN}" >&2; fail "a Python ran ($1)"; }
}

PROFILE="${T}/sandbox.sb"
# Foundation's atomic writes (the Swift updater's swap.sh) stage in the volume's TemporaryItems folder first.
ITEMS="$(getconf DARWIN_USER_TEMP_DIR)TemporaryItems"
cat > "${PROFILE}" <<SB
(version 1)
(allow default)
(deny network-outbound (remote ip))
(deny file-write* (subpath "/"))
(allow file-write* (subpath "${H}") (subpath "/dev") (subpath "${ITEMS}") (subpath "/private${ITEMS}"))
SB

# A command as a tester's Mac runs it: this home only, no network, no Python on PATH.
in_home() {
  cd "${H}" && env -i HOME="${H}" TMPDIR="${H}/tmp/" \
    PATH="${H}/no-python:${H}/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin" HF_HUB_OFFLINE=1 LANG=en_US.UTF-8 "$@"
}
sandboxed() { in_home sandbox-exec -f "${PROFILE}" "$@"; }

APP="${H}/Applications/Palaver.app"
SUPPORT="${H}/Library/Application Support/palaver"
engine_hello() {
  [ "$(printf '%s\n' '{"id":1,"cmd":"hello"}' | sandboxed "${APP}/Contents/MacOS/palaver-engine" --version x 2>/dev/null \
    | grep -c '"ok" *: *true')" = 1 ] || fail "palaver-engine does not answer hello ($1)"
}
RID="$(plutil -extract runtime.id raw -o - "${DIST}/manifest.json")"
VERSION="$(plutil -extract version raw -o - "${DIST}/manifest.json")"
[ "${RID}" = "no-python-1" ] || fail "the manifest names runtime ${RID}, not the placeholder no-python-1"

# --- install --------------------------------------------------------------------------------------
sandboxed env PALAVER_ASSETS_DIR="${DIST}" sh "${DIST}/install.sh" --autostart --cli >"${T}/install.log" 2>&1 \
  || { cat "${T}/install.log"; fail "install.sh failed"; }
[ ! -e "${SUPPORT}/runtime" ] || fail "install.sh installed a runtime"
[ -L "${H}/.local/bin/palaver" ] || fail "the palaver command is not linked"
[ -f "${H}/Library/LaunchAgents/com.kenodressel.meeting-transcribe.plist" ] || fail "autostart agent missing"
codesign --verify --strict "${APP}" || fail "Palaver.app's signature does not verify"
MACOS="${APP}/Contents/MacOS"
RES="${APP}/Contents/Resources"
# The Swift app is only looked at, never started: it would ask for the microphone and system audio.
[ "$(plutil -extract CFBundleExecutable raw -o - "${APP}/Contents/Info.plist")" = "Palaver" ] \
  || fail "the bundle's executable is not Palaver"
! plutil -extract PalaverRuntimeID raw -o - "${APP}/Contents/Info.plist" >/dev/null 2>&1 || fail "Info.plist still names a runtime"
file "${MACOS}/Palaver" | grep -q "Mach-O 64-bit executable arm64" || fail "Contents/MacOS/Palaver is not an arm64 program"
otool -L "${MACOS}/Palaver" | grep -q "/usr/lib/swift/libswiftCore.dylib" || fail "Contents/MacOS/Palaver is not the Swift app"
[ "$(ls "${MACOS}" | tr '\n' ' ')" = "Palaver palaver-engine palaver-lm palaver-server palaver-worker " ] \
  || fail "Contents/MacOS holds $(ls "${MACOS}" | tr '\n' ' ')"
[ "$(ls "${RES}/bin" | tr '\n' ' ')" = "palaver python " ] || fail "Contents/Resources/bin holds $(ls "${RES}/bin" | tr '\n' ' ')"
[ -f "${RES}/menubar.png" ] || fail "the menu bar icon is missing"
[ -f "${RES}/web/index.html" ] && [ -f "${RES}/web/app.js" ] || fail "the window's page files are not in Contents/Resources/web"
# No Python: no interpreter, no Python code, nothing named like it but the MCP shim, which is a short shell script.
PYTHONISH="$(cd "${APP}" && find . \( -iname '*python*' -o -name '*.py' -o -name '*.pyc' -o -name '__pycache__' \) -print)"
[ "${PYTHONISH}" = "./Contents/Resources/bin/python" ] || fail "Python in the bundle: ${PYTHONISH}"
head -1 "${RES}/bin/python" | grep -qx '#!/bin/sh' && [ "$(wc -c < "${RES}/bin/python")" -lt 4096 ] \
  || fail "Contents/Resources/bin/python is not the shell shim"
if find "${APP}" -type f ! -path "${RES}/bin/python" -exec file {} + | grep -qi "python"; then
  fail "a file in the bundle is a Python program"
fi
engine_hello "after install"
for program in "${MACOS}/Palaver" "${MACOS}/palaver-engine" "${MACOS}/palaver-server" "${MACOS}/palaver-worker" \
    "${MACOS}/palaver-lm" "${RES}/bin/palaver"; do
  codesign --verify --strict "${program}" || fail "${program##*/}'s signature does not verify"
  # As 0.5: no hardened runtime until notarization (palaver/app_bundle.py HARDENED_RUNTIME).
  if codesign -d --verbose=2 "${program}" 2>&1 | grep "flags=" | grep -q "runtime)"; then
    fail "${program##*/} has the hardened runtime (0.6.0rc1 signs as 0.5 did)"
  fi
  file "${program}" | grep -q "Mach-O 64-bit executable arm64" || fail "${program} is not an arm64 program"
done
[ -f "${RES}/zipf.bin" ] || fail "the domain's resources (zipf.bin) are missing"
[ -f "${RES}/mlx.metallib" ] || fail "MLX's shaders (mlx.metallib) are missing"
grep -q "WebRTC" "${RES}/THIRD_PARTY_LICENSES.md" 2>/dev/null || fail "the third-party notices are missing"
# Build-machine paths (a home folder, its user name) anywhere in the bundle; the pre-built NemoTextProcessing library
# in palaver-worker carries its own CI's /Users/runner/ paths, which name nobody.
if find "${APP}" -type f -exec strings {} + 2>/dev/null | grep "/Users/" | grep -qv "/Users/runner/"; then
  fail "the app contains build-machine paths"
fi
ok "install.sh: Palaver.app ${VERSION} without Python (the Swift app, palaver-engine, palaver-server, palaver-worker, palaver-lm, bin/palaver, all signed as 0.5's; the MCP shim; web, zipf.bin, mlx.metallib and the notices), no runtime, command, login item; nothing written outside the home"

# --- the window's server, the worker, palaver-lm and the command, as the app runs them ---------------------------
# The server on a free port (the app hands it a listening socket instead), its key as the app gives it.
KEY="smoke-key-$$"
sandboxed env PALAVER_WEB_KEY="${KEY}" "${MACOS}/palaver-server" --port 0 </dev/null >"${T}/server.log" 2>&1 &
PORT=""
n=0
while [ -z "${PORT}" ] && [ "${n}" -lt 200 ]; do
  PORT="$(sed -n 's|^Open http://127\.0\.0\.1:\([0-9]*\)/.*|\1|p' "${T}/server.log" 2>/dev/null | head -1)"
  [ -n "${PORT}" ] || { n=$((n + 1)); sleep 0.1; }
done
[ -n "${PORT}" ] || { tail -5 "${T}/server.log"; fail "palaver-server did not start"; }
PING="$(curl -s --max-time 5 -H "Cookie: palaver_key_${PORT}=${KEY}" "http://127.0.0.1:${PORT}/api/ping" || true)"
NOKEY="$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/api/ping" || true)"
PAGE="$(curl -s --max-time 5 -H "Cookie: palaver_key_${PORT}=${KEY}" "http://127.0.0.1:${PORT}/" || true)"
pkill -TERM -f "${MACOS}/palaver-server" 2>/dev/null || true
echo "${PING}" | grep -q '"ok": *true' || fail "palaver-server does not answer /api/ping with its key (${PING})"
[ "${NOKEY}" != 200 ] || fail "palaver-server answers /api/ping without its key"
[ "${PAGE}" = "$(cat "${RES}/web/index.html")" ] || fail "palaver-server does not serve the window's page from Contents/Resources/web"
WORKER_LINES="$(sandboxed "${MACOS}/palaver-worker" query index-stale --json 2>"${T}/worker.log" | wc -l | tr -d ' ')"
[ "${WORKER_LINES}" = 1 ] || { tail -5 "${T}/worker.log"; fail "palaver-worker query index-stale did not print one line"; }
sandboxed "${MACOS}/palaver-worker" query resources --json 2>>"${T}/worker.log" | grep -q '"zipf": *true' \
  || { tail -5 "${T}/worker.log"; fail "palaver-worker does not find zipf.bin in the bundle"; }
# palaver-lm runs (its MLX and tokenizer libraries load) and says which Palaver it is; no model is loaded here.
LM_VERSION="$(sandboxed "${MACOS}/palaver-lm" --version 2>"${T}/lm.log" || true)"
[ "${LM_VERSION}" = "palaver-lm ${VERSION}" ] || { tail -5 "${T}/lm.log"; fail "palaver-lm --version said '${LM_VERSION}'"; }
sandboxed "${H}/.local/bin/palaver" --help >/dev/null || fail "the palaver command does not run"
sandboxed "${H}/.local/bin/palaver" daemon status >"${T}/status.log" 2>&1 || true
grep -q "daemon" "${T}/status.log" || { cat "${T}/status.log"; fail "palaver daemon status said nothing"; }
# The MCP shim: an old Claude entry's `bin/python -m palaver mcp` is `bin/palaver mcp`; anything else is refused.
MCP="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' \
  | sandboxed "${RES}/bin/python" -m palaver mcp 2>"${T}/mcp.log" | head -1 || true)"
echo "${MCP}" | grep -q '"serverInfo"' || { tail -3 "${T}/mcp.log"; fail "the MCP shim did not start palaver mcp (${MCP})"; }
if sandboxed "${RES}/bin/python" -c "print(1)" >/dev/null 2>&1; then fail "the MCP shim ran something else than palaver mcp"; fi
no_python_ran "the programs"
ok "palaver-server answers /api/ping with its key (and refuses it without) and serves the page from web/; palaver-worker answers its queries and finds zipf.bin; palaver-lm, the palaver command and the MCP shim run; no Python ran"

# --- an update through install.sh: the app only ---------------------------------------------------------
# What the app keeps in Application Support survives every update: its state with the queue (a crash
# is recovered from it), the developer's marker.
mkdir -p "${SUPPORT}"
printf '%s\n' '{"state": "stopped", "queued": ["'"${H}"'/Meetings/Recordings/2026-11-01T10-00-00"], "cut": null}' \
  > "${SUPPORT}/daemon.json"
cp "${SUPPORT}/daemon.json" "${T}/daemon.json.before"
touch "${SUPPORT}/legacy-server"
# A later version than the one built: rc1 -> rc2, else 0.6.0 -> 0.6.0.1.
later() { case "$1" in *rc[0-9]*) echo "${1%rc*}rc$(( ${1##*rc} + $2 ))" ;; *) echo "$1.$2" ;; esac; }
build_at() {  # build_at VERSION DIR [BASE_URL]: the app rebuilt as that version, the placeholder and the manifest
  mkdir -p "$2"
  (cd "${REPO}" && ${PYTHON} tools/build_release.py app --dist "$2" --version "$1" >/dev/null \
    && ${PYTHON} tools/build_release.py compat-runtime --dist "$2" >/dev/null \
    && ${PYTHON} tools/build_release.py manifest --dist "$2" --version "$1" ${3:+--base-url "$3"} >/dev/null) \
    || fail "rebuilding the app as $1 failed"
}
NEXT="$(later "${VERSION}" 1)"
D2="${T}/dist-${NEXT}"
build_at "${NEXT}" "${D2}"
rm "${D2}/palaver-runtime-${RID}.tar.gz"  # install.sh must not need it
cp "${DIST}/install.sh" "${D2}/install.sh"
sandboxed env PALAVER_ASSETS_DIR="${D2}" sh "${D2}/install.sh" >"${T}/update.log" 2>&1 \
  || { cat "${T}/update.log"; fail "updating with install.sh failed"; }
grep -q "Updated Palaver to ${NEXT}" "${T}/update.log" || { cat "${T}/update.log"; fail "install.sh did not say it updated"; }
[ ! -e "${SUPPORT}/runtime" ] || fail "install.sh installed a runtime on the update"
[ "$(plutil -extract version raw -o - "${RES}/runtime.json")" = "${NEXT}" ] || fail "the app was not updated to ${NEXT}"
sandboxed "${H}/.local/bin/palaver" --help >/dev/null || fail "the command does not run after the update"
engine_hello "after the update"
ok "update to ${NEXT} with install.sh: the app only"

# --- an update from inside the app, by its Swift updater: the app only ----------------------------------
# palaver-update-driver does what the app's Updates menu does (check, download, stage, swap.sh, commit), without
# starting the app. `open` as the new app answers it: it writes its started-ok mark, as the app does after its first
# tick (else the swap puts the old one back). The real app is never opened here.
(cd "${REPO}" && swift build --package-path native --product palaver-update-driver >"${T}/driver-build.log" 2>&1) \
  || { tail -5 "${T}/driver-build.log"; fail "building palaver-update-driver failed"; }
DRIVER="${REPO}/native/.build/debug/palaver-update-driver"
LAST="$(later "${VERSION}" 2)"
D3="${T}/dist-${LAST}"
build_at "${LAST}" "${D3}" "file://${D3}"
OPENER="${H}/open-app"
printf '%s\n' '#!/bin/sh' \
  "plutil -extract version raw -o - \"\$1/Contents/Resources/runtime.json\" > \"${SUPPORT}/started-ok\"" > "${OPENER}"
chmod +x "${OPENER}"
APP_SIZE="$(plutil -extract app.size raw -o - "${D3}/manifest.json")"
sandboxed env PALAVER_MANIFEST_URL="file://${D3}/manifest.json" "${DRIVER}" --home "${H}" --bundle "${APP}" \
  --open "${OPENER}" --start-timeout 30 >"${T}/driver.json" 2>"${T}/driver.log" \
  || { cat "${T}/driver.log"; fail "the Swift updater did not take ${LAST}"; }
[ "$(plutil -extract version raw -o - "${T}/driver.json")" = "${LAST}" ] || fail "the Swift updater offered another version"
[ "$(plutil -extract download_bytes raw -o - "${T}/driver.json")" = "${APP_SIZE}" ] || fail "the Swift updater downloads more than the app"
[ "$(plutil -extract runtime raw -o - "${T}/driver.json")" = "false" ] || fail "the Swift updater wants a runtime"
SWAP="$(plutil -extract swap raw -o - "${T}/driver.json")"
# The swap runs once the app has quit, as from the app.
sandboxed /bin/sh "${SWAP}" || fail "the Swift updater's swap script failed"
[ ! -e "${SUPPORT}/previous-app" ] || fail "the version before was not dropped"
[ "$(plutil -extract version raw -o - "${RES}/runtime.json")" = "${LAST}" ] || fail "the Swift updater did not install ${LAST}"
[ ! -e "${SUPPORT}/runtime" ] || fail "the Swift updater installed a runtime"
codesign --verify --strict "${APP}" || fail "the updated app's signature does not verify"
cmp -s "${SUPPORT}/daemon.json" "${T}/daemon.json.before" || fail "an update changed daemon.json"
[ -f "${SUPPORT}/legacy-server" ] || fail "an update removed the legacy-server marker"
rm -f "${SUPPORT}/legacy-server"
no_python_ran "the updates"
ok "update to ${LAST} by the app's Swift updater: the app only, swapped after quitting, daemon.json and the markers kept"

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

# --- updates from 0.3.14 and 0.5.0rc6 through their own updater, to a release built as 0.6 ships ----------------
# Every release up to 0.5.0rcN updates in-app with its own Python updater, frozen in it (two variants: 0.1.0-0.3.14
# and 0.5.0rc1-rc6). Here the published 0.3.14 and 0.5.0rc6 app archives (their Contents/Resources/python holds
# that updater) run it, on OLD_UPDATER_PYTHON as those apps ran it on their runtime, against this release (its
# runtime.json and manifest name the placeholder runtime). It must download only the app and the few-hundred-byte
# placeholder (never the old 500 MB runtime), accept the new app and swap it in with its own swap.sh; the new app's
# started-ok keeps it. The old runtime stays for the new app's cleanup (RuntimeCleanup, after its first good start:
# Swift tests). PALAVER_OLD_RELEASES: a folder with those archives; else they are downloaded from GitHub into
# DIST/old-releases once, checked against their published sha256.
[ -x "${OLD_UPDATER_PYTHON}" ] || fail "no Python for the old releases' updaters (${OLD_UPDATER_PYTHON}; set PALAVER_OLD_UPDATER_PYTHON)"
OLD_RELEASES="${PALAVER_OLD_RELEASES:-${DIST}/old-releases}"
old_release() {  # old_release VERSION SHA256: the published app archive of that release
  zip="${OLD_RELEASES}/palaver-app-$1.zip"
  if [ ! -f "${zip}" ]; then
    mkdir -p "${OLD_RELEASES}"
    curl -fsSL --max-time 300 -o "${zip}.part" "https://github.com/kenodressel/palaver/releases/download/v$1/palaver-app-$1.zip" \
      && mv "${zip}.part" "${zip}" || fail "could not download Palaver $1's app"
  fi
  [ "$(shasum -a 256 "${zip}" | cut -c1-64)" = "$2" ] || fail "palaver-app-$1.zip is not the published one"
}
COMPAT="$(later "${VERSION}" 3)"
D4="${T}/dist-${COMPAT}"
build_at "${COMPAT}" "${D4}" "file://${D4}"
COMPAT_RID="$(plutil -extract runtime.id raw -o - "${D4}/manifest.json")"
[ "$(plutil -extract runtime.size raw -o - "${D4}/manifest.json")" -lt 1024 ] || fail "the placeholder runtime is not tiny"
APP_SIZE="$(plutil -extract app.size raw -o - "${D4}/manifest.json")"
old_update() {  # old_update VERSION SHA256 RUNTIME_ID: that release installed, then updated by its own updater
  old_release "$1" "$2"
  rm -rf "${APP}" "${SUPPORT}/runtime/${COMPAT_RID}" "${SUPPORT}/runtime/.previous" "${SUPPORT}/previous-app" \
    "${SUPPORT}/updates" "${SUPPORT}/started-ok" "${SUPPORT}/update.json"
  ditto -xk "${OLD_RELEASES}/palaver-app-$1.zip" "${H}/Applications" || fail "unpacking Palaver $1 failed"
  [ "$(plutil -extract runtime raw -o - "${APP}/Contents/Resources/runtime.json")" = "$3" ] || fail "Palaver $1 names another runtime"
  if [ ! -d "${SUPPORT}/runtime/$3" ]; then  # its runtime, as far as its updater looks: bin/python3
    mkdir -p "${SUPPORT}/runtime/$3/bin"
    printf '%s\n' '#!/bin/sh' 'exit 1' > "${SUPPORT}/runtime/$3/bin/python3"
    chmod +x "${SUPPORT}/runtime/$3/bin/python3"
  fi
  old_inode="$(stat -f %i "${SUPPORT}/runtime/$3")"
  sandboxed env PALAVER_APP="${APP}" PALAVER_MANIFEST_URL="file://${D4}/manifest.json" PYTHONDONTWRITEBYTECODE=1 \
    "${OLD_UPDATER_PYTHON}" -I -c "
import sys
sys.path.insert(0, '${APP}/Contents/Resources/python')
import json
from palaver import downloader, release, updater
assert updater.__file__.startswith('${APP}/'), updater.__file__
spawned = []
installer = updater.Installer(open_command='${OPENER}', spawn=spawned.append)
u = updater.Updater(installed=updater.installed_now, fetch_manifest=downloader.fetch_manifest,
                    stage=installer.stage, apply=installer.apply, macos=updater.macos_version())
status = u.check()
assert status['state'] == 'available' and status['current'] == '$1', status
assert status['available']['version'] == '${COMPAT}' and status['available']['runtime'] is True, status
assert status['available']['download_bytes'] - ${APP_SIZE} < 1024, status  # the app and the placeholder, nothing more
assert u.request()
assert u.download()['state'] == 'ready', u.status()
assert u.tick() is True
open('${H}/swap-argv.json', 'w').write(json.dumps(spawned[0]))
" || fail "Palaver $1's updater did not take ${COMPAT}"
  sandboxed /bin/sh "$(plutil -extract 1 raw -o - "${H}/swap-argv.json")" || fail "Palaver $1's swap script failed"
  [ "$(plutil -extract version raw -o - "${APP}/Contents/Resources/runtime.json")" = "${COMPAT}" ] \
    || fail "Palaver $1's updater did not install ${COMPAT}"
  [ ! -e "${APP}/Contents/Resources/python" ] || fail "Palaver $1's update left Python in the app"
  [ ! -e "${SUPPORT}/previous-app" ] || fail "Palaver $1's swap kept the version before"
  [ -x "${SUPPORT}/runtime/${COMPAT_RID}/bin/python3" ] || fail "Palaver $1's updater did not unpack the placeholder"
  [ "$(cat "${SUPPORT}/runtime/.previous")" = "$3" ] || fail "Palaver $1's updater did not remember its runtime"
  [ "$(stat -f %i "${SUPPORT}/runtime/$3")" = "${old_inode}" ] || fail "Palaver $1's updater replaced its runtime"
  codesign --verify --strict "${APP}" || fail "the app Palaver $1's updater installed does not verify"
  cmp -s "${SUPPORT}/daemon.json" "${T}/daemon.json.before" || fail "Palaver $1's update changed daemon.json"
}
old_update 0.3.14 1e9cc54d6d86ba99462cd42c744a26bcd32d7cdee1ea769695df349e14fd0d87 3.13.18-arm64-227bfef1b0cc
old_update 0.5.0rc6 79356a72e143097530a3048e61e9193a05402474df3f4b75b076cd339f11daa3 3.13.18-arm64-155fa76f8b4e
ok "updates from 0.3.14 and 0.5.0rc6 with their own updater to ${COMPAT}: the app and the ${COMPAT_RID} placeholder only, swapped in and kept"

# --- uninstall ------------------------------------------------------------------------------------------
mkdir -p "${SUPPORT}/models/fluidaudio"  # the engine's models: --uninstall keeps them
[ -d "${SUPPORT}/runtime" ] || fail "the old releases left no runtime to remove"
sandboxed sh "${DIST}/install.sh" --uninstall >/dev/null || fail "install.sh --uninstall failed"
[ ! -e "${APP}" ] && [ ! -e "${SUPPORT}/runtime" ] \
  && [ ! -e "${H}/.local/bin/palaver" ] && [ ! -e "${H}/Library/LaunchAgents/com.kenodressel.meeting-transcribe.plist" ] \
  || fail "install.sh --uninstall left something behind"
[ -d "${SUPPORT}/models/fluidaudio" ] || fail "--uninstall removed the models"
no_python_ran "the uninstall"
ok "install.sh --uninstall removes the app, the old runtime, command and login item; the models stay"
