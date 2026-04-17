#!/bin/bash
# Temperature Watcher for Benchmark — loggt + bricht bei Überhitzung ab
# Start: bash temp-watcher.sh <csv-output> <trigger-file>
# Stop (graceful): touch $trigger-file.stop
# Abort-Schwellen:
#   CPU Tctl: 90°C (Strix Halo Default Tjmax ~95°C, 5°C Puffer)
#   GPU edge: 95°C
#   GPU junction: 100°C (falls verfügbar)
# Bei Abort: Watcher schreibt STOP-Marker-Datei, Benchmark-Script liest diese.

set -euo pipefail

CSV="${1:-/tmp/temps-$(date +%Y%m%d_%H%M%S).csv}"
STOP_MARKER="${2:-/tmp/benchmark-abort.marker}"
INTERVAL="${TEMP_INTERVAL:-3}"
CPU_MAX="${CPU_MAX:-90}"
GPU_EDGE_MAX="${GPU_EDGE_MAX:-95}"
GPU_JUNCTION_MAX="${GPU_JUNCTION_MAX:-100}"

# Header
echo "timestamp,cpu_tctl,gpu_edge,gpu_junction,gpu_mem,gpu_power_w,cpu_power_w,ram_used_gi,status" > "$CSV"

# Ensure stop marker does not exist at start
rm -f "$STOP_MARKER"

read_gpu_json() {
    rocm-smi --showtemp --showpower --showmemuse --json 2>/dev/null || echo "{}"
}

read_cpu_tctl() {
    sensors 2>/dev/null | awk '/Tctl:/ { gsub("[+°C]","",$2); print $2; exit }'
}

read_cpu_pkg_power() {
    # k10temp doesn't expose PPT on all boards; amdgpu does PPT
    sensors 2>/dev/null | awk '/^PPT:/ { print $2; exit }'
}

echo "[temp-watcher] start — csv=$CSV, CPU<${CPU_MAX}°C, GPU edge<${GPU_EDGE_MAX}°C, GPU junction<${GPU_JUNCTION_MAX}°C, interval=${INTERVAL}s"
echo "[temp-watcher] stop-marker: $STOP_MARKER (wird geschrieben bei Überhitzung)"

TICK=0
MAX_CPU=0; MAX_GPU=0
while true; do
    TS=$(date -Iseconds)

    # CPU
    CPU=$(read_cpu_tctl || echo "")
    [ -z "$CPU" ] && CPU="0"
    CPU_I=${CPU%.*}

    # GPU via rocm-smi
    GPU_JSON=$(read_gpu_json)
    GPU_EDGE=$(echo "$GPU_JSON" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin).get('card0') or {}
    # try multiple key names
    for k in ('Temperature (Sensor edge) (C)','temperature_edge','edge'):
        if k in d: print(d[k]); break
    else: print('0')
except: print('0')
" 2>/dev/null || echo "0")
    GPU_JUNCTION=$(echo "$GPU_JSON" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin).get('card0') or {}
    for k in ('Temperature (Sensor junction) (C)','temperature_junction','junction'):
        if k in d: print(d[k]); break
    else: print('0')
except: print('0')
" 2>/dev/null || echo "0")
    GPU_MEM=$(echo "$GPU_JSON" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin).get('card0') or {}
    for k in ('Temperature (Sensor memory) (C)','temperature_mem','mem'):
        if k in d: print(d[k]); break
    else: print('0')
except: print('0')
" 2>/dev/null || echo "0")
    GPU_POWER=$(echo "$GPU_JSON" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin).get('card0') or {}
    for k in ('Average Graphics Package Power (W)','Current Socket Graphics Package Power (W)','power'):
        if k in d: print(d[k]); break
    else: print('0')
except: print('0')
" 2>/dev/null || echo "0")

    CPU_POWER=$(read_cpu_pkg_power || echo "")
    [ -z "$CPU_POWER" ] && CPU_POWER="0"

    RAM=$(free -g | awk '/Speicher:|Mem:/ {print $3; exit}')

    GPU_EDGE_I=${GPU_EDGE%.*}
    GPU_JUNCTION_I=${GPU_JUNCTION%.*}
    [ "$GPU_EDGE_I" = "" ] && GPU_EDGE_I=0
    [ "$GPU_JUNCTION_I" = "" ] && GPU_JUNCTION_I=0

    STATUS="ok"
    if [ "$CPU_I" -gt "$CPU_MAX" ]; then STATUS="ABORT_CPU_${CPU_I}C"; fi
    if [ "$GPU_EDGE_I" -gt "$GPU_EDGE_MAX" ]; then STATUS="ABORT_GPU_EDGE_${GPU_EDGE_I}C"; fi
    if [ "$GPU_JUNCTION_I" -gt "$GPU_JUNCTION_MAX" ]; then STATUS="ABORT_GPU_JUNCTION_${GPU_JUNCTION_I}C"; fi

    [ "$CPU_I" -gt "$MAX_CPU" ] && MAX_CPU="$CPU_I"
    [ "$GPU_EDGE_I" -gt "$MAX_GPU" ] && MAX_GPU="$GPU_EDGE_I"

    echo "${TS},${CPU},${GPU_EDGE},${GPU_JUNCTION},${GPU_MEM},${GPU_POWER},${CPU_POWER},${RAM},${STATUS}" >> "$CSV"

    # Periodic stdout report (every 10 ticks ~ every 30s)
    TICK=$((TICK+1))
    if [ $((TICK % 10)) -eq 0 ]; then
        echo "[temp-watcher] tick#${TICK} CPU=${CPU}°C GPU(edge)=${GPU_EDGE}°C junction=${GPU_JUNCTION}°C mem=${GPU_MEM}°C pwr=${GPU_POWER}W RAM=${RAM}Gi status=${STATUS}  (peak CPU=${MAX_CPU}°C GPU=${MAX_GPU}°C)"
    fi

    if [[ "$STATUS" == ABORT_* ]]; then
        echo "[temp-watcher] 🚨 ABORT: $STATUS  →  schreibe stop-marker"
        echo "$STATUS at $TS (CPU=${CPU} GPU_EDGE=${GPU_EDGE} GPU_JUNCTION=${GPU_JUNCTION})" > "$STOP_MARKER"
        # Kill llama-cpp backends to cool down immediately
        docker exec agntsio-localai-1 pkill -TERM -f llama-cpp 2>/dev/null || true
        echo "[temp-watcher] llama-cpp Backends getötet, watcher läuft weiter (loggt weiter bis extern gestoppt)"
    fi

    # Soft stop via marker file (so parent script can signal done)
    if [ -f "${STOP_MARKER}.stop" ]; then
        echo "[temp-watcher] Benchmark fertig (stop-marker gesetzt) — peak CPU=${MAX_CPU}°C GPU=${MAX_GPU}°C"
        rm -f "${STOP_MARKER}.stop"
        break
    fi

    sleep "$INTERVAL"
done
