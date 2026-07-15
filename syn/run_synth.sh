#!/usr/bin/env bash
# ============================================================
#  Run Yosys synthesis for the scrambler design (WSL / Linux)
#
#  Usage:
#     ./run_synth.sh                    # run synth_generic.ys
#     ./run_synth.sh my_other.ys        # run a different script
# ============================================================

set -euo pipefail

OSS_CAD_ROOT="${OSS_CAD_ROOT:-/mnt/c/Yosys/oss-cad-suite}"
YOSYS="$OSS_CAD_ROOT/bin/yosys"

# Work from the directory this script lives in, so the relative
# ../RTL/ paths inside the .ys script always resolve.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

YS_SCRIPT="${1:-synth_generic.ys}"

if [[ ! -x "$YOSYS" ]]; then
    echo "ERROR: yosys not found at $YOSYS" >&2
    echo "       Override with: OSS_CAD_ROOT=/path/to/oss-cad-suite $0" >&2
    exit 1
fi

if [[ ! -f "$YS_SCRIPT" ]]; then
    echo "ERROR: script not found: $SCRIPT_DIR/$YS_SCRIPT" >&2
    exit 1
fi

mkdir -p reports netlist

# Name the log after the script, so synth and equiv runs don't clobber
# each other: synth_generic.ys -> reports/synth_generic.log
LOG="reports/$(basename "$YS_SCRIPT" .ys).log"

echo "=========================================================="
echo " Yosys   : $("$YOSYS" -V)"
echo " Script  : $YS_SCRIPT"
echo " Log     : $SCRIPT_DIR/$LOG"
echo "=========================================================="

# -q keeps the full transcript in $LOG but leaves the console clean.
if ! "$YOSYS" -q -l "$LOG" "$YS_SCRIPT"; then
    echo ""
    echo "!!! FAILED - see $LOG" >&2
    exit 1
fi

# Yosys exits 0 even when the log carries warnings, so surface them here.
echo ""
echo "---------------------- WARNINGS --------------------------"
if grep -q '^Warning:' "$LOG"; then
    grep '^Warning:' "$LOG" | sort -u
else
    echo "(none)"
fi

echo ""
echo "----------------------- SUMMARY --------------------------"

if grep -q 'EQUIV_STATUS' "$LOG"; then
    # Equivalence-check flow.
    grep -E 'are proven and|Equivalence successfully proven' "$LOG" | sed 's/^ *//'
    echo ""
    echo "EQUIVALENCE CHECK OK  (gold = RTL, gate = synthesised netlist)"
    echo "  $LOG"
    echo "  reports/equiv_status.txt"
else
    # Synthesis flow: cell/FF totals come from the post-flatten stat report.
    if [[ -f reports/stat_flat.txt ]]; then
        printf "Total cells : %s\n" \
            "$(awk '/^ *[0-9]+ cells$/ {print $1}' reports/stat_flat.txt | tail -1)"
        printf "Flip-flops  : %s\n" \
            "$(awk '/\$_(DFF|SDFF|ADFF)/ {sum += $1} END {print sum+0}' reports/stat_flat.txt)"
    fi
    if [[ -f reports/ltp.txt ]]; then
        grep -m1 'Longest topological path' reports/ltp.txt || true
    fi
    echo ""
    echo "SYNTHESIS OK"
    echo "  $LOG"
    echo "  reports/  -> stat_hier.txt, stat_flat.txt, ltp.txt"
    echo "  netlist/  -> scrambler_apb_netlist.v, scrambler_apb.json"
fi
