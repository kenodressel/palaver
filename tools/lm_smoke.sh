#!/bin/sh
# lm_smoke.sh: the local model's opt-in smoke test (phase 4 batch 5). Never part of `make test`: it loads the real
# Gemma 4 12B (read in place from the Hugging Face cache; nothing is downloaded or copied), so run it only when the Mac
# is not recording (`palaver daemon status` idle) and nothing else needs the memory.
#
#   make lm && sh tools/lm_smoke.sh
#
# 1. PalaverMLXTests' opt-in suite (PALAVER_LM_SMOKE=1) under tools/memcap.sh: Gemma's chat template through
#    swift-transformers with thinking off (no weights), then one short prompt with 64 tokens at most; it prints the
#    peak footprint and tokens/s and checks the peak stays under the budget.
# 2. The release palaver-lm writing the notes of a fictional meeting (temporary config, home and recordings), under
#    memcap and /usr/bin/time -l (its "peak memory footprint"), then the notes it wrote.
#
# Both runs lower the in-process budget to SMOKE_GB (PALAVER_LM_MEMORY_GB) and memcap to CAP_GB, below the notes
# budget of 14 GB.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CAP_GB=${CAP_GB:-13}
SMOKE_GB=${SMOKE_GB:-12}
PRODUCTS="$ROOT/native/.build/xcode/Build/Products/Release"
LM=${PALAVER_LM:-$PRODUCTS/palaver-lm}
METALLIB=${PALAVER_MLX_METALLIB:-$PRODUCTS/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib}
HUB=${HF_HUB_CACHE:-$HOME/.cache/huggingface/hub}
[ -x "$LM" ] && [ -f "$METALLIB" ] || { echo "lm_smoke: build palaver-lm first (make lm)" >&2; exit 2; }

tmp=$(mktemp -d -t palaver-lm-smoke)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/config" "$tmp/home" "$tmp/Recordings/2026-10-21T16-29-29"

if [ -z "${NOTES_ONLY:-}" ]; then  # NOTES_ONLY=1: step 2 alone
echo "== 1. template and a short prompt (swift test, memcap $CAP_GB GB, budget $SMOKE_GB GB)"
(cd "$ROOT/native" && swift build --build-tests >/dev/null)
XDG_CONFIG_HOME="$tmp/config" PALAVER_HOME="$tmp/home" PALAVER_LM_SMOKE=1 PALAVER_LM_SMOKE_HUB="$HUB" \
    PALAVER_MLX_METALLIB="$METALLIB" PALAVER_LM_MEMORY_GB="$SMOKE_GB" \
    sh "$ROOT/tools/memcap.sh" "$CAP_GB" swift test --skip-build --package-path "$ROOT/native" \
    --filter LocalModelSmokeTests 2>&1 | grep -E "SMOKE|TEMPLATE|✔|✘|memcap" || true
fi

echo "== 2. notes of a fictional meeting (release palaver-lm, memcap $CAP_GB GB, budget $SMOKE_GB GB)"
meeting="$tmp/Recordings/2026-10-21T16-29-29"
printf '[recording]\noutput_dir = "%s"\n[user]\nname = "Timo Strauß"\n' "$tmp/Recordings" > "$tmp/config.toml"
printf '{"start_time": "2026-10-21T16:29:29+02:00"}\n' > "$meeting/meta.json"
cat > "$meeting/transcript.json" <<'EOF'
[
 {"speaker": "Timo Strauß", "start": 3.0, "end": 8.0, "text": "Hallo zusammen, heute geht es um das Angebot für Contoso und den Zeitplan mit Northwind."},
 {"speaker": "SPEAKER_01", "start": 9.0, "end": 15.0, "text": "Hallo, ich bin Valerie von Contoso. Wir brauchen das Angebot bis Freitag, sonst verschiebt sich unser Budget."},
 {"speaker": "Timo Strauß", "start": 16.0, "end": 24.0, "text": "Verstehe. Northwind liefert die Hardware erst Mitte November, deshalb schlage ich zwei Phasen vor."},
 {"speaker": "SPEAKER_01", "start": 25.0, "end": 33.0, "text": "Zwei Phasen sind in Ordnung, wenn die erste Phase vor Weihnachten fertig ist."},
 {"speaker": "Timo Strauß", "start": 34.0, "end": 41.0, "text": "Dann schicke ich dir das Angebot mit zwei Phasen bis Freitag, und du klärst intern das Budget."},
 {"speaker": "SPEAKER_01", "start": 42.0, "end": 49.0, "text": "Ja, das mache ich. Entschieden ist also: zwei Phasen, erste Phase bis zum zwanzigsten Dezember."},
 {"speaker": "Timo Strauß", "start": 50.0, "end": 55.0, "text": "Genau. Wir sprechen nächste Woche Dienstag noch einmal über den Preis."}
]
EOF
XDG_CONFIG_HOME="$tmp/config" PALAVER_HOME="$tmp/home" HF_HUB_CACHE="$HUB" PALAVER_LM_MEMORY_GB="$SMOKE_GB" \
    sh "$ROOT/tools/memcap.sh" "$CAP_GB" /usr/bin/time -l "$LM" --config "$tmp/config.toml" --no-notify \
    notes "$meeting" 2>&1 | grep -E "Writing|Wrote|Skipping|Project|error|warning|real|peak memory footprint|maximum resident|memcap" || true
echo "-- notes.json"
cat "$meeting/notes.json"
echo
echo "-- session.log"
grep -o '"event": "[a-z_]*"\|"seconds": [0-9.]*' "$meeting/session.log" | paste -sd ' ' - || true
