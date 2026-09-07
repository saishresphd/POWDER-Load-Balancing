#!/usr/bin/env bash
# collect_perf_ipc.sh — Per-core perf stat IPC / cycles / instructions / cache-miss collector
# Designed for CPU power-saving research on POWDER srsRAN load-balancing experiments.
#
# Output: /tmp/ran_collect/perf_ipc_<hostname>.csv
# Columns:
#   timestamp_ms, phase, cpu_id, instructions, cycles, ipc,
#   cache_misses, cache_refs, cache_miss_rate_pct,
#   branch_misses, branch_instr, branch_miss_rate_pct,
#   cpu_migrations, context_switches,
#   task_clock_ms, cpu_util_pct
#
# Usage:
#   ./collect_perf_ipc.sh [interval_sec] [output_dir] [phase_file]
#   Default: interval=2, output=/tmp/ran_collect, phase_file=/tmp/ran_collect/phase.txt
#
# Requirements:
#   - perf (linux-tools-$(uname -r) or perf-tools-unstable)
#   - Must be run as root OR have /proc/sys/kernel/perf_event_paranoid <= 1
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

INTERVAL=${1:-2}
OUT_DIR=${2:-/tmp/ran_collect}
PHASE_FILE=${3:-/tmp/ran_collect/phase.txt}
HOSTNAME=$(hostname -s)
OUT_CSV="${OUT_DIR}/perf_ipc_${HOSTNAME}.csv"
PID_FILE="${OUT_DIR}/perf_ipc.pid"

mkdir -p "$OUT_DIR"

# ── Sanity checks ─────────────────────────────────────────────────────────────
if ! command -v perf &>/dev/null; then
    echo "[perf_ipc] ERROR: 'perf' not found. Install linux-tools-$(uname -r)" >&2
    exit 1
fi

PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "99")
if [[ "$PARANOID" -gt 1 && "$EUID" -ne 0 ]]; then
    echo "[perf_ipc] WARNING: perf_event_paranoid=$PARANOID; run as root or set to <=1" >&2
    echo "[perf_ipc] Attempting to lower paranoid level..." >&2
    if ! sysctl -w kernel.perf_event_paranoid=1 &>/dev/null; then
        echo "[perf_ipc] Cannot lower perf_event_paranoid — per-core IPC will be skipped" >&2
        exit 1
    fi
fi

NUM_CPUS=$(nproc)

# ── Write CSV header ──────────────────────────────────────────────────────────
if [[ ! -f "$OUT_CSV" ]]; then
    echo "timestamp_ms,phase,cpu_id,instructions,cycles,ipc,cache_misses,cache_refs,cache_miss_rate_pct,branch_misses,branch_instr,branch_miss_rate_pct,cpu_migrations,context_switches,task_clock_ms,cpu_util_pct" > "$OUT_CSV"
fi

echo "[perf_ipc] Starting on $HOSTNAME — $NUM_CPUS cores — interval=${INTERVAL}s → $OUT_CSV"
echo $$ > "$PID_FILE"

# ── Helper: read current phase ────────────────────────────────────────────────
get_phase() {
    if [[ -f "$PHASE_FILE" ]]; then
        cat "$PHASE_FILE" | tr -d '[:space:]'
    else
        echo "unknown"
    fi
}

# ── Helper: safe division ─────────────────────────────────────────────────────
safe_div() {
    local num=$1 den=$2
    if [[ -z "$den" || "$den" == "0" || "$den" == "<not" ]]; then
        echo "0"
    else
        python3 -c "print(round(float('${num}') / float('${den}'), 6))" 2>/dev/null || echo "0"
    fi
}

# ── Per-core perf stat collection loop ───────────────────────────────────────
collect_per_core() {
    local ts_ms phase
    ts_ms=$(python3 -c "import time; print(int(time.time()*1000))")
    phase=$(get_phase)

    for cpu_id in $(seq 0 $((NUM_CPUS - 1))); do
        # Run perf stat for one interval on this specific CPU
        # We use --cpu to pin to exact core, --no-aggr for per-cpu output
        local perf_out
        perf_out=$(perf stat \
            --cpu "$cpu_id" \
            --no-aggr \
            -e instructions,cycles,cache-misses,cache-references,branch-misses,branch-instructions,cpu-migrations,context-switches,task-clock \
            --interval-print "$((INTERVAL * 1000))" \
            --interval-count 1 \
            -- sleep "$INTERVAL" 2>&1 || true)

        # Parse perf output lines — format varies by kernel version
        # Typical line: "    CPU0   1,234,567      instructions"
        local instr cycles cache_miss cache_ref br_miss br_instr cpu_mig ctx_sw task_clk
        instr=$(echo    "$perf_out" | awk '/instructions/    {gsub(",","",$NF); v=$NF} /instructions/{gsub(",",""); for(i=1;i<=NF;i++) if($i~/^[0-9,]+$/) {gsub(",","",$i); v=$i; break}} END{print v+0}')
        cycles=$(echo   "$perf_out" | awk '/cycles/          {for(i=1;i<=NF;i++) if($i~/^[0-9,]+$/) {gsub(",","",$i); v=$i; break}} END{print v+0}')
        cache_miss=$(echo "$perf_out" | awk '/cache-misses/  {for(i=1;i<=NF;i++) if($i~/^[0-9,]+$/) {gsub(",","",$i); v=$i; break}} END{print v+0}')
        cache_ref=$(echo  "$perf_out" | awk '/cache-references/{for(i=1;i<=NF;i++) if($i~/^[0-9,]+$/) {gsub(",","",$i); v=$i; break}} END{print v+0}')
        br_miss=$(echo  "$perf_out" | awk '/branch-misses/  {for(i=1;i<=NF;i++) if($i~/^[0-9,]+$/) {gsub(",","",$i); v=$i; break}} END{print v+0}')
        br_instr=$(echo "$perf_out" | awk '/branch-instructions/{for(i=1;i<=NF;i++) if($i~/^[0-9,]+$/) {gsub(",","",$i); v=$i; break}} END{print v+0}')
        cpu_mig=$(echo  "$perf_out" | awk '/cpu-migrations/  {for(i=1;i<=NF;i++) if($i~/^[0-9,]+$/) {gsub(",","",$i); v=$i; break}} END{print v+0}')
        ctx_sw=$(echo   "$perf_out" | awk '/context-switches/{for(i=1;i<=NF;i++) if($i~/^[0-9,]+$/) {gsub(",","",$i); v=$i; break}} END{print v+0}')
        task_clk=$(echo "$perf_out" | awk '/task-clock/      {for(i=1;i<=NF;i++) if($i~/^[0-9.]+$/) {v=$i; break}} END{print v+0}')

        # Derived ratios
        local ipc cache_miss_pct br_miss_pct cpu_util_pct
        ipc=$(safe_div "$instr" "$cycles")
        cache_miss_pct=$(python3 -c "r=${cache_ref:-0}; m=${cache_miss:-0}; print(round(m/r*100,2) if r>0 else 0)" 2>/dev/null || echo "0")
        br_miss_pct=$(python3 -c   "b=${br_instr:-0}; m=${br_miss:-0};  print(round(m/b*100,2) if b>0 else 0)" 2>/dev/null || echo "0")
        # cpu_util = task_clock_ms / (interval_ms * 1) × 100
        cpu_util_pct=$(python3 -c "t=${task_clk:-0}; i=${INTERVAL}*1000; print(round(t/i*100,2) if i>0 else 0)" 2>/dev/null || echo "0")

        echo "${ts_ms},${phase},${cpu_id},${instr:-0},${cycles:-0},${ipc},${cache_miss:-0},${cache_ref:-0},${cache_miss_pct},${br_miss:-0},${br_instr:-0},${br_miss_pct},${cpu_mig:-0},${ctx_sw:-0},${task_clk:-0},${cpu_util_pct}" \
            >> "$OUT_CSV"
    done
}

# ── Alternative: fast bulk perf stat (system-wide, aggregate) ─────────────────
# This is faster and used when per-core granularity isn't available.
collect_system_wide() {
    local ts_ms phase
    ts_ms=$(python3 -c "import time; print(int(time.time()*1000))")
    phase=$(get_phase)

    local perf_out
    perf_out=$(perf stat \
        -a \
        --no-aggr \
        -e instructions,cycles,cache-misses,cache-references,branch-misses,branch-instructions,cpu-migrations,context-switches,task-clock \
        -- sleep "$INTERVAL" 2>&1 || true)

    # Parse each CPU line from --no-aggr output
    # Format: "  CPU<N>           <value>      <event>"
    while IFS= read -r line; do
        local cpu_id instr cycles cache_miss cache_ref br_miss br_instr cpu_mig ctx_sw task_clk
        cpu_id=$(echo "$line" | awk '{if($1~/^CPU[0-9]+/) print substr($1,4); else print ""}')
        [[ -z "$cpu_id" ]] && continue

        local event_name value
        value=$(echo "$line" | awk '{for(i=2;i<=NF;i++) if($i~/^[0-9,]+$/) {gsub(",","",$i); print $i; exit}}')
        event_name=$(echo "$line" | awk '{print $NF}')

        case "$event_name" in
            instructions)        eval "instr_${cpu_id}=${value:-0}" ;;
            cycles)              eval "cyc_${cpu_id}=${value:-0}" ;;
            cache-misses)        eval "cmiss_${cpu_id}=${value:-0}" ;;
            cache-references)    eval "cref_${cpu_id}=${value:-0}" ;;
            branch-misses)       eval "bmiss_${cpu_id}=${value:-0}" ;;
            branch-instructions) eval "binstr_${cpu_id}=${value:-0}" ;;
            cpu-migrations)      eval "cmig_${cpu_id}=${value:-0}" ;;
            context-switches)    eval "ctxsw_${cpu_id}=${value:-0}" ;;
            task-clock)          eval "tclk_${cpu_id}=${value:-0}" ;;
        esac
    done <<< "$perf_out"

    # Emit one row per CPU
    for cpu_id in $(seq 0 $((NUM_CPUS - 1))); do
        local i c cm cr bm bi mg cs tc ipc cmp brp cup
        eval "i=\${instr_${cpu_id}:-0}"
        eval "c=\${cyc_${cpu_id}:-0}"
        eval "cm=\${cmiss_${cpu_id}:-0}"
        eval "cr=\${cref_${cpu_id}:-0}"
        eval "bm=\${bmiss_${cpu_id}:-0}"
        eval "bi=\${binstr_${cpu_id}:-0}"
        eval "mg=\${cmig_${cpu_id}:-0}"
        eval "cs=\${ctxsw_${cpu_id}:-0}"
        eval "tc=\${tclk_${cpu_id}:-0}"
        ipc=$(safe_div "$i" "$c")
        cmp=$(python3 -c "print(round($cm/$cr*100,2) if $cr>0 else 0)" 2>/dev/null || echo "0")
        brp=$(python3 -c "print(round($bm/$bi*100,2) if $bi>0 else 0)" 2>/dev/null || echo "0")
        cup=$(python3 -c "print(round($tc/${INTERVAL}/1000*100,2) if ${INTERVAL}>0 else 0)" 2>/dev/null || echo "0")
        echo "${ts_ms},${phase},${cpu_id},${i},${c},${ipc},${cm},${cr},${cmp},${bm},${bi},${brp},${mg},${cs},${tc},${cup}" \
            >> "$OUT_CSV"
    done
}

# ── Decide collection mode ─────────────────────────────────────────────────────
# Per-core mode with --cpu is cleaner; fall back to system-wide --no-aggr
TEST_PERF=$(perf stat --cpu 0 -e cycles -- sleep 0.1 2>&1 || true)
if echo "$TEST_PERF" | grep -q "not supported\|Invalid\|Permission denied"; then
    USE_SYSTEM_WIDE=1
    echo "[perf_ipc] Falling back to system-wide --no-aggr mode"
else
    USE_SYSTEM_WIDE=0
    echo "[perf_ipc] Using per-core --cpu mode"
fi

# ── Summary stats helper (written to separate file at end) ────────────────────
write_summary() {
    local summary_file="${OUT_DIR}/perf_ipc_summary_${HOSTNAME}.txt"
    {
        echo "=== PERF IPC SUMMARY: $HOSTNAME ==="
        echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "Interval: ${INTERVAL}s | Cores: ${NUM_CPUS}"
        echo "Output: $OUT_CSV"
        echo ""
        echo "--- Per-phase mean IPC (all cores) ---"
        python3 - "$OUT_CSV" << 'PYEOF'
import sys, csv
from collections import defaultdict

path = sys.argv[1]
phase_ipc   = defaultdict(list)
phase_cputil = defaultdict(list)
phase_cmiss  = defaultdict(list)

try:
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            ph = row.get('phase','?')
            try:
                ipc = float(row.get('ipc',0))
                cup = float(row.get('cpu_util_pct',0))
                cmp = float(row.get('cache_miss_rate_pct',0))
                if ipc > 0:
                    phase_ipc[ph].append(ipc)
                if cup >= 0:
                    phase_cputil[ph].append(cup)
                if cmp >= 0:
                    phase_cmiss[ph].append(cmp)
            except (ValueError, TypeError):
                pass

    for ph in sorted(phase_ipc.keys()):
        ipcs  = phase_ipc[ph]
        cups  = phase_cputil[ph]
        cmps  = phase_cmiss[ph]
        avg_ipc  = sum(ipcs)/len(ipcs)  if ipcs  else 0
        avg_cup  = sum(cups)/len(cups)  if cups  else 0
        avg_cmp  = sum(cmps)/len(cmps)  if cmps  else 0
        print(f"  {ph:<30} IPC={avg_ipc:.3f}  CPU_util={avg_cup:.1f}%  cache_miss={avg_cmp:.2f}%  (n={len(ipcs)})")
except Exception as e:
    print(f"  [summary error: {e}]")
PYEOF
        echo ""
        echo "--- Key finding indicators ---"
        python3 - "$OUT_CSV" "${PHASE_FILE}" << 'PYEOF2'
import sys, csv
from collections import defaultdict

path      = sys.argv[1]
phase_file = sys.argv[2] if len(sys.argv) > 2 else ""

phases_order = ["baseline", "ue51_attach", "ramp", "hold_500mbps", "lb_trigger", "lb_reconnect", "post_lb"]
phase_ipc   = defaultdict(list)
phase_cup   = defaultdict(list)
phase_cmiss = defaultdict(list)

try:
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            ph  = row.get('phase','unknown').lower().strip()
            try:
                ipc  = float(row.get('ipc',0))
                cup  = float(row.get('cpu_util_pct',0))
                cmp  = float(row.get('cache_miss_rate_pct',0))
                phase_ipc[ph].append(ipc)
                phase_cup[ph].append(cup)
                phase_cmiss[ph].append(cmp)
            except (ValueError, TypeError):
                pass

    def avg(lst): return sum(lst)/len(lst) if lst else 0

    baseline_ipc   = avg(phase_ipc.get('baseline',[]))
    post_lb_ipc    = avg(phase_ipc.get('post_lb',[]))
    baseline_cup   = avg(phase_cup.get('baseline',[]))
    post_lb_cup    = avg(phase_cup.get('post_lb',[]))
    lb_cup         = avg(phase_cup.get('lb_trigger',[]))

    delta_ipc = post_lb_ipc - baseline_ipc
    delta_cup = post_lb_cup - baseline_cup

    print(f"  CPU_UTIL baseline→post_lb: {baseline_cup:.1f}% → {post_lb_cup:.1f}% (Δ={delta_cup:+.1f}%)")
    print(f"  IPC      baseline→post_lb: {baseline_ipc:.3f} → {post_lb_ipc:.3f} (Δ={delta_ipc:+.3f})")
    print(f"  CPU_UTIL during lb_trigger:  {lb_cup:.1f}%")
    if baseline_cup > 0:
        savings_pct = (baseline_cup - post_lb_cup) / baseline_cup * 100
        print(f"  CPU_UTIL savings after LB:   {savings_pct:.1f}%")
    hold = avg(phase_cup.get('hold_500mbps',[]))
    print(f"  CPU_UTIL at 500 Mbps hold:   {hold:.1f}%")
except Exception as e:
    print(f"  [key findings error: {e}]")
PYEOF2
    } > "$summary_file" 2>&1

    echo "[perf_ipc] Summary written → $summary_file"
    cat "$summary_file"
}

# ── Trap for clean shutdown ───────────────────────────────────────────────────
cleanup() {
    echo "[perf_ipc] Stopping — writing summary..."
    write_summary
    rm -f "$PID_FILE"
    echo "[perf_ipc] Done. Output: $OUT_CSV"
    exit 0
}
trap cleanup SIGTERM SIGINT EXIT

# ── Main collection loop ──────────────────────────────────────────────────────
echo "[perf_ipc] Collection loop started (PID=$$). CSV: $OUT_CSV"
echo "[perf_ipc] Send SIGTERM or SIGINT to stop gracefully."

LOOP_COUNT=0
while true; do
    if [[ "$USE_SYSTEM_WIDE" -eq 1 ]]; then
        collect_system_wide
    else
        # Per-core sequential: one sample per core per interval
        # This is slower — collect each core independently
        ts_ms=$(python3 -c "import time; print(int(time.time()*1000))")
        phase=$(get_phase)
        for cpu_id in $(seq 0 $((NUM_CPUS - 1))); do
            perf_out=$(perf stat \
                --cpu "$cpu_id" \
                -e instructions,cycles,cache-misses,cache-references,branch-misses,branch-instructions,cpu-migrations,context-switches,task-clock \
                -- sleep "$INTERVAL" 2>&1 || true)

            # Extract numeric values — perf outputs "N,NNN,NNN event" with commas
            extract_val() {
                local event="$1"
                echo "$perf_out" | grep -E "^\s+[0-9,]+\s+${event}" \
                    | awk '{gsub(",","",$1); print $1+0}' \
                    | head -1
            }

            instr=$(extract_val "instructions")
            cycles=$(extract_val "cycles")
            cache_miss=$(extract_val "cache-misses")
            cache_ref=$(extract_val "cache-references")
            br_miss=$(extract_val "branch-misses")
            br_instr=$(extract_val "branch-instructions")
            cpu_mig=$(extract_val "cpu-migrations")
            ctx_sw=$(extract_val "context-switches")
            task_clk=$(echo "$perf_out" | grep "task-clock" \
                | awk '{gsub(",","",$1); print $1+0}' | head -1)

            instr=${instr:-0}
            cycles=${cycles:-0}
            cache_miss=${cache_miss:-0}
            cache_ref=${cache_ref:-0}
            br_miss=${br_miss:-0}
            br_instr=${br_instr:-0}
            cpu_mig=${cpu_mig:-0}
            ctx_sw=${ctx_sw:-0}
            task_clk=${task_clk:-0}

            ipc=$(safe_div "$instr" "$cycles")
            cache_miss_pct=$(python3 -c "print(round($cache_miss/$cache_ref*100,2) if $cache_ref>0 else 0)" 2>/dev/null || echo "0")
            br_miss_pct=$(python3 -c    "print(round($br_miss/$br_instr*100,2) if $br_instr>0 else 0)" 2>/dev/null || echo "0")
            cpu_util_pct=$(python3 -c   "print(round($task_clk/${INTERVAL}/1000*100,2) if ${INTERVAL}>0 else 0)" 2>/dev/null || echo "0")

            echo "${ts_ms},${phase},${cpu_id},${instr},${cycles},${ipc},${cache_miss},${cache_ref},${cache_miss_pct},${br_miss},${br_instr},${br_miss_pct},${cpu_mig},${ctx_sw},${task_clk},${cpu_util_pct}" \
                >> "$OUT_CSV"
        done
    fi

    LOOP_COUNT=$((LOOP_COUNT + 1))
    # Print heartbeat every 10 loops
    if (( LOOP_COUNT % 10 == 0 )); then
        echo "[perf_ipc] Loop $LOOP_COUNT | phase=$(get_phase) | rows=$(wc -l < "$OUT_CSV")"
    fi
done
