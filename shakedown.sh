#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# shakedown.sh: run the full Tesserae client shakedown.
#
#   Tier 1 - deterministic API/unit tests against a fake server (pytest)
#   Tier 2 - headless end-to-end smoke: one real client cycle per display
#            type against the real Tesserae server, framebuffer saved as PNG
#
# Usage:
#   ./shakedown.sh                            # tier 1 + smoke of "native"
#   SHAKEDOWN_DISPLAYS=all ./shakedown.sh     # smoke every display type
#   SHAKEDOWN_DISPLAYS=native,sharp400 ./shakedown.sh
#   TESSERAE_CLIENT_DIR=/path/to/client ./shakedown.sh
#   SHAKEDOWN_SKIP_SMOKE=1 ./shakedown.sh     # tier 1 only
#
# Results land in report/<timestamp>/ (report.md, logs, PNGs).
# ----------------------------------------------------------------------------
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="${TESSERAE_CLIENT_DIR:-$here/../tesserae-device-circuitpython}"
CLIENT_VENV="${TESSERAE_CLIENT_VENV:-$CLIENT_DIR/venv.tesserae.cp-client}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$here/report/$STAMP"
mkdir -p "$REPORT"

if [ ! -d "$CLIENT_DIR/src" ]; then
  if [ -d "../tesserae-device-circuitpython" ]; then
    # use current directory as fallback
    CLIENT_DIR="."
  else
    echo "error: client checkout not found at $CLIENT_DIR" >&2
    echo "set TESSERAE_CLIENT_DIR" >&2
    exit 2
  fi
fi

ALL_DISPLAYS="native what ii4_old ii4 ii5.7_old ii5.7 ii7.3_old iframe5.7 badger2040w sunton-2424 sharp400"
DISPLAYS="${SHAKEDOWN_DISPLAYS:-native}"
if [ "$DISPLAYS" = "all" ]; then
  DISPLAYS="$ALL_DISPLAYS"
else
  DISPLAYS="${DISPLAYS//,/ }"
fi

# --- tier 1 -----------------------------------------------------------------
echo "== Tier 1: API + unit tests (fake server) =="
venv="$here/venv.shakedown"
if [ ! -x "$venv/bin/python3" ]; then
  echo "creating shakedown venv ..."
  python3 -m venv "$venv"
  "$venv/bin/pip" install -q -r "$here/requirements.txt"
fi
TESSERAE_CLIENT_DIR="$CLIENT_DIR" "$venv/bin/python3" -m pytest "$here/tests" -v \
  2>&1 | tee "$REPORT/tier1-pytest.log"
tier1_rc=${PIPESTATUS[0]}

# --- tier 2 -----------------------------------------------------------------
tier2_rc=0
if [ -n "${SHAKEDOWN_SKIP_SMOKE:-}" ]; then
  echo "== Tier 2: skipped (SHAKEDOWN_SKIP_SMOKE) =="
elif [ ! -x "$CLIENT_VENV/bin/python3" ]; then
  echo "== Tier 2: skipped (client venv not found at $CLIENT_VENV) =="
  tier2_rc=1
else
  echo "== Tier 2: headless smoke against the real server =="
  for d in $DISPLAYS; do
    printf -- "-- %-12s " "$d"
    TESSERAE_DISPLAY="$d" \
      "$CLIENT_VENV/bin/python3" "$here/smoke/run_once.py" "$REPORT" "$CLIENT_DIR/src" \
      > "$REPORT/smoke-$d.log" 2>&1
    rc=$?
    if [ -f "$REPORT/$d.json" ]; then
      outcome="$("$venv/bin/python3" -c \
        "import json,sys; o=json.load(open(sys.argv[1])); print(o['outcome'], '-', o['detail'])" \
        "$REPORT/$d.json")"
    else
      outcome="FAIL - no outcome file (rc=$rc)"
    fi
    echo "$outcome"
    case "$outcome" in FAIL*) tier2_rc=1;; esac
  done
fi

# --- report -----------------------------------------------------------------
"$venv/bin/python3" - "$REPORT" "$tier1_rc" <<'EOF'
import glob, json, os, sys
report, tier1_rc = sys.argv[1], int(sys.argv[2])
lines = ["# Tesserae client shakedown", "",
         f"run: `{os.path.basename(report)}`", "",
         "## Tier 1 — API + unit tests (fake server)",
         "", f"result: **{'PASS' if tier1_rc == 0 else 'FAIL'}** "
             f"(details: `tier1-pytest.log`)", "",
         "## Tier 2 — headless smoke (real server)", ""]
rows = sorted(glob.glob(os.path.join(report, "*.json")))
if rows:
    lines += ["| display | outcome | detail | screenshot |",
              "|---|---|---|---|"]
    for path in rows:
        o = json.load(open(path))
        png = os.path.basename(o.get("png", "")) if o.get("png") else "—"
        if png != "—":
            png = f"![{o['display']}]({png})"
        lines.append(f"| {o['display']} | {o['outcome']} | {o['detail']} | {png} |")
else:
    lines.append("_no smoke runs_")
open(os.path.join(report, "report.md"), "w").write("\n".join(lines) + "\n")
print(f"report: {os.path.join(report, 'report.md')}")
EOF

echo
[ "$tier1_rc" -eq 0 ] && echo "tier 1: PASS" || echo "tier 1: FAIL"
[ "$tier2_rc" -eq 0 ] && echo "tier 2: PASS" || echo "tier 2: FAIL (or skipped with error)"
exit $(( tier1_rc || tier2_rc ))
