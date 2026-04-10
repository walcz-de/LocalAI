#!/bin/bash
# =============================================================================
# LocalAI Advanced Benchmark – Strix Halo
# =============================================================================
# Laedt jedes Modell einzeln, benchmarkt, entlaedt es, naechstes.
# Preloaded Modelle werden zuerst getestet.
#
# Aufruf:
#   bash benchmark.sh                        # Interaktiv
#   bash benchmark.sh --all                  # Alle Chat-Modelle
#   bash benchmark.sh 35B fast balanced      # Fuzzy Match
#   bash benchmark.sh --all --extended       # + 4096, 8192
#   bash benchmark.sh --all --csv
#   bash benchmark.sh --tokens 128,512,8192 35B
# =============================================================================

set -euo pipefail

# --- Defaults ---
URL="http://localhost:8081"
TOKEN_STEPS="128,512,1024,2048"
CSV_OUTPUT=false
CSV_FILE="benchmark_$(date +%Y%m%d_%H%M%S).csv"
SELECT_ALL=false
SELECTED_MODELS=()
NO_FILTER=false
LOAD_TIMEOUT=300   # Sekunden warten bis Modell geladen
PRELOADED=()       # wird automatisch ermittelt
LOCALAI_CONTAINER="${LOCALAI_CONTAINER:-agntsio-localai-1}"

# Nicht-Chat-Modelle sowie API-Proxy-Modelle (kein lokales GGUF)
SKIP_MODELS="jina-embeddings|jina-reranker|granite-embedding|text-embedding|whisper|tts-1|stablediffusion|silero-vad|llmlingua|moondream|DeepSeek-Coder|mistralai_"
# Exact-match skip list (models that must not be benchmarked as local LLMs)
SKIP_EXACT="gpt-4 gpt-4o gpt-4-turbo qwen3.5-agent CACHEDIR.TAG"

# --- Farben ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

usage() {
    cat <<EOF
Aufruf: bash benchmark.sh [OPTIONEN] [MODELL1 MODELL2 ...]

Optionen:
  --url URL          LocalAI URL (default: $URL)
  --container NAME   Docker container name (default: $LOCALAI_CONTAINER)
  --all              Alle Chat-Modelle
  --tokens LIST      Token-Stufen, z.B. 128,512,2048,8192
  --extended         Standard + 4096 + 8192
  --csv              CSV-Export
  --no-filter        Auch Nicht-Chat-Modelle
  --load-timeout S   Wartezeit fuer Modell-Laden (default: ${LOAD_TIMEOUT}s)
  -h, --help         Hilfe

Beispiele:
  bash benchmark.sh                           # Interaktiv
  bash benchmark.sh --all                     # Alle, Standard-Tokens
  bash benchmark.sh --all --extended --csv    # Alle, lang, CSV
  bash benchmark.sh 35B fast balanced         # Fuzzy Match
  bash benchmark.sh --tokens 128,8192 35B     # Custom Tokens
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --url) URL="$2"; shift 2 ;;
        --container) LOCALAI_CONTAINER="$2"; shift 2 ;;
        --all) SELECT_ALL=true; shift ;;
        --tokens) TOKEN_STEPS="$2"; shift 2 ;;
        --extended) TOKEN_STEPS="128,512,1024,2048,4096,8192"; shift ;;
        --csv) CSV_OUTPUT=true; shift ;;
        --no-filter) NO_FILTER=true; shift ;;
        --load-timeout) LOAD_TIMEOUT="$2"; shift 2 ;;
        -h|--help) usage ;;
        --*) echo "Unbekannte Option: $1"; exit 1 ;;
        *) SELECTED_MODELS+=("$1"); shift ;;
    esac
done

# --- Health Check ---
echo -e "${BOLD}=== Strix Halo LocalAI Benchmark ===${NC}"
echo -e "URL: ${CYAN}$URL${NC}"
echo ""

if ! curl -sf --max-time 5 "$URL/readyz" >/dev/null 2>&1; then
    if ! curl -sf --max-time 5 "$URL/v1/models" >/dev/null 2>&1; then
        echo -e "${RED}LocalAI nicht erreichbar: $URL${NC}"; exit 1
    fi
fi
echo -e "${GREEN}✅ LocalAI erreichbar${NC}"

# --- Modelle laden ---
MODELS_JSON=$(curl -sf --max-time 10 "$URL/v1/models")
ALL_MODELS=($(echo "$MODELS_JSON" | python3 -c "
import sys,json
for m in sorted([m['id'] for m in json.load(sys.stdin).get('data',[])]):
    print(m)
"))

# Filtern
CHAT_MODELS=(); SKIPPED=()
for m in "${ALL_MODELS[@]}"; do
    skip=false
    if [ "$NO_FILTER" = false ]; then
        # Substring pattern match
        echo "$m" | grep -qiE "$SKIP_MODELS" && skip=true
        # Exact match against explicit list
        for exact in $SKIP_EXACT; do
            [ "$m" = "$exact" ] && skip=true
        done
    fi
    if [ "$skip" = false ]; then
        CHAT_MODELS+=("$m")
    else
        SKIPPED+=("$m")
    fi
done

# Preloaded Modelle ermitteln (die bereits ein aktives Backend haben)
echo -e "\n${DIM}Ermittle geladene Modelle...${NC}"
for m in "${CHAT_MODELS[@]}"; do
    state=$(curl -s -X GET --max-time 5 "$URL/backend/monitor" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$m\"}" 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    err=d.get('error',{}).get('message','')
    if 'not currently loaded' in err:
        print(0)
    elif 'error' in d:
        print(2)  # geladen, aber Status-RPC nicht implementiert
    else:
        print(d.get('state',0))
except: print(0)
" 2>/dev/null || echo "0")
    if [ "$state" = "2" ] || [ "$state" = "1" ]; then
        PRELOADED+=("$m")
    fi
done

echo -e "${BOLD}Chat-Modelle (${#CHAT_MODELS[@]}):${NC}"
for i in "${!CHAT_MODELS[@]}"; do
    loaded=""
    for p in "${PRELOADED[@]}"; do
        [ "$p" = "${CHAT_MODELS[$i]}" ] && loaded=" ${GREEN}[geladen]${NC}"
    done
    echo -e "  ${CYAN}$((i+1))${NC}) ${CHAT_MODELS[$i]}${loaded}"
done
if [ ${#SKIPPED[@]} -gt 0 ]; then
    echo -e "\n  ${DIM}Uebersprungen: ${SKIPPED[*]}${NC}"
fi
echo ""

# --- Auswahl ---
BENCH_MODELS=()

if [ "$SELECT_ALL" = true ]; then
    BENCH_MODELS=("${CHAT_MODELS[@]}")
    echo -e "${YELLOW}→ Alle ${#BENCH_MODELS[@]} Chat-Modelle${NC}"
elif [ ${#SELECTED_MODELS[@]} -gt 0 ]; then
    for sel in "${SELECTED_MODELS[@]}"; do
        found=false
        for avail in "${CHAT_MODELS[@]}"; do
            if [ "$sel" = "$avail" ]; then
                BENCH_MODELS+=("$sel"); found=true; break
            fi
        done
        if [ "$found" = false ]; then
            for avail in "${CHAT_MODELS[@]}"; do
                if [[ "${avail,,}" == *"${sel,,}"* ]]; then
                    BENCH_MODELS+=("$avail")
                    echo -e "  ${YELLOW}'$sel' → $avail${NC}"
                    found=true; break
                fi
            done
        fi
        [ "$found" = false ] && echo -e "  ${RED}Nicht gefunden: $sel${NC}"
    done
else
    echo -e "${BOLD}Nummern (komma-separiert) oder 'all':${NC}"
    read -rp "> " SEL
    if [ "$SEL" = "all" ] || [ "$SEL" = "a" ]; then
        BENCH_MODELS=("${CHAT_MODELS[@]}")
    else
        IFS=',' read -ra NUMS <<< "$SEL"
        for n in "${NUMS[@]}"; do
            n=$(echo "$n" | tr -d ' ')
            [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#CHAT_MODELS[@]} ] && \
                BENCH_MODELS+=("${CHAT_MODELS[$((n-1))]}")
        done
    fi
fi

[ ${#BENCH_MODELS[@]} -eq 0 ] && { echo -e "${RED}Keine Modelle${NC}"; exit 1; }

# Sortierung: Preloaded zuerst
SORTED_MODELS=()
for m in "${BENCH_MODELS[@]}"; do
    for p in "${PRELOADED[@]}"; do
        [ "$p" = "$m" ] && SORTED_MODELS+=("$m")
    done
done
for m in "${BENCH_MODELS[@]}"; do
    is_pre=false
    for p in "${PRELOADED[@]}"; do [ "$p" = "$m" ] && is_pre=true; done
    [ "$is_pre" = false ] && SORTED_MODELS+=("$m")
done
BENCH_MODELS=("${SORTED_MODELS[@]}")

IFS=',' read -ra TOKENS <<< "$TOKEN_STEPS"

# --- Prompt ---
PROMPT='Write an extremely detailed technical reference covering: 1) Transformer attention mechanisms including multi-head, grouped query, sliding window. 2) Flash attention on CUDA, ROCm, Vulkan, Metal. 3) KV cache quantization FP16 to Q4_0. 4) MoE architectures: routing, expert selection, load balancing. 5) Memory management on unified memory architectures. 6) Inference optimization: batching, speculative decoding, tensor parallelism. 7) Weight quantization: GPTQ, AWQ, GGUF types. 8) AMD RDNA3/3.5 GPU optimizations. Be thorough with math.'

# --- CSV ---
[ "$CSV_OUTPUT" = true ] && echo "timestamp,model,max_tokens,completion_tokens,prompt_tokens,time_s,tokens_per_s" > "$CSV_FILE"

# --- Funktionen ---
shutdown_model() {
    local model="$1"
    # Graceful API shutdown (works for demand-loaded models)
    curl -sf --max-time 30 -X POST "$URL/backend/shutdown" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$model\"}" >/dev/null 2>&1 || true
    # Force-kill llama-cpp backend process – necessary for LOAD_TO_MEMORY models
    # where the API shutdown silently fails, leaving memory occupied.
    if [ -n "$LOCALAI_CONTAINER" ] && docker ps -q --filter "name=^${LOCALAI_CONTAINER}$" 2>/dev/null | grep -q .; then
        docker exec "$LOCALAI_CONTAINER" pkill -TERM -f "llama-cpp" 2>/dev/null || true
    fi
    echo -en "  ${DIM}⏳ Warte auf Speicherfreigabe...${NC} "
    sleep 20
    echo "OK"
}

load_model() {
    local model="$1"
    local retries=2

    for attempt in $(seq 1 $retries); do
        echo -n "  ⏳ Lade $model (Versuch $attempt/$retries, max ${LOAD_TIMEOUT}s)... "

        if curl -sf --max-time "$LOAD_TIMEOUT" -o /dev/null "$URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}],\"max_tokens\":3,\"temperature\":0}" 2>/dev/null; then
            echo -e "${GREEN}OK${NC}"
            return 0
        else
            echo -e "${RED}fehlgeschlagen${NC}"
            if [ "$attempt" -lt "$retries" ]; then
                echo -e "  ${DIM}Warte 10s vor Retry...${NC}"
                sleep 10
            fi
        fi
    done
    return 1
}

# Speicher komplett leeren – LOAD_TO_MEMORY Modelle werden vom API-Shutdown nicht erfasst,
# daher llama-cpp Prozess direkt beenden (einmalig am Start, danach pro Modell).
echo -e "${DIM}Bereinige Backends fuer saubere Benchmark-Baseline...${NC}"
if [ -n "$LOCALAI_CONTAINER" ] && docker ps -q --filter "name=^${LOCALAI_CONTAINER}$" 2>/dev/null | grep -q .; then
    docker exec "$LOCALAI_CONTAINER" pkill -TERM -f "llama-cpp" 2>/dev/null || true
    sleep 20
    echo -e "  ${GREEN}✓ Backends gestoppt${NC}"
else
    # Fallback: API shutdown fuer bekannte preloaded Modelle
    for m in "${PRELOADED[@]}"; do
        echo -e "  ${DIM}↓ $m${NC}"
        curl -sf --max-time 30 -X POST "$URL/backend/shutdown" \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"$m\"}" >/dev/null 2>&1 || true
    done
    sleep 15
fi
echo ""

echo ""
echo -e "${BOLD}Benchmark-Plan:${NC}"
echo -e "  Modelle:  ${#BENCH_MODELS[@]} (preloaded zuerst)"
echo -e "  Tokens:   ${TOKEN_STEPS}"
echo -e "  Tests:    $((${#BENCH_MODELS[@]} * ${#TOKENS[@]}))"
echo -e "  Strategie: Load → Bench → Shutdown → naechstes"
echo ""

# --- Hauptschleife ---
declare -A RESULTS
TOTAL=$((${#BENCH_MODELS[@]} * ${#TOKENS[@]}))
N=0
PREV_MODEL=""

for model in "${BENCH_MODELS[@]}"; do
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}📊 ${CYAN}$model${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Vorheriges Modell immer entladen (auch preloaded) – sonst OOM bei naechstem grossen Modell
    if [ -n "$PREV_MODEL" ]; then
        echo -e "  ${DIM}↓ Entlade $PREV_MODEL${NC}"
        shutdown_model "$PREV_MODEL"
    fi

    # Modell laden
    if ! load_model "$model"; then
        for tok in "${TOKENS[@]}"; do
            N=$((N + 1))
            RESULTS["${model}|${tok}"]="FEHLER"
        done
        PREV_MODEL="$model"
        continue
    fi

    # Warmup (2. Request, Modell ist jetzt warm)
    curl -sf --max-time 60 -o /dev/null "$URL/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello, how are you?\"}],\"max_tokens\":20,\"temperature\":0}" 2>/dev/null || true

    for tok in "${TOKENS[@]}"; do
        N=$((N + 1))
        echo -n "  [$N/$TOTAL] max_tokens=$tok ... "

        timeout_s=$(( tok / 5 + 60 ))

        resp=$(curl -sf --max-time "$timeout_s" -w "\n__TIME__:%{time_total}" "$URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"$PROMPT\"}],\"max_tokens\":$tok,\"temperature\":0}" 2>/dev/null) || {
            echo -e "${RED}Timeout${NC}"
            RESULTS["${model}|${tok}"]="TIMEOUT"
            continue
        }

        t=$(echo "$resp" | grep "__TIME__:" | cut -d: -f2)
        json=$(echo "$resp" | grep -v "__TIME__:")
        ct=$(echo "$json" | python3 -c "import sys,json;print(json.load(sys.stdin)['usage']['completion_tokens'])" 2>/dev/null || echo "0")
        pt=$(echo "$json" | python3 -c "import sys,json;print(json.load(sys.stdin)['usage']['prompt_tokens'])" 2>/dev/null || echo "0")

        if [ "$ct" != "0" ] && [ -n "$t" ]; then
            tps=$(python3 -c "print(f'{int($ct)/$t:.1f}')")

            [ "$CSV_OUTPUT" = true ] && echo "$(date -Iseconds),$model,$tok,$ct,$pt,$t,$tps" >> "$CSV_FILE"

            color=$RED
            tps_int=$(python3 -c "print(int(float('$tps')))")
            [ "$tps_int" -ge 25 ] && color=$YELLOW
            [ "$tps_int" -ge 40 ] && color=$GREEN

            echo -e "${ct} tok in ${t}s = ${color}${BOLD}${tps} t/s${NC}"
            RESULTS["${model}|${tok}"]="$tps"
        else
            echo -e "${DIM}0 Tokens (${t}s)${NC}"
            RESULTS["${model}|${tok}"]="0"
        fi
    done

    PREV_MODEL="$model"
done

# Letztes Modell entladen
if [ -n "$PREV_MODEL" ]; then
    echo -e "\n  ${DIM}↓ Entlade $PREV_MODEL${NC}"
    shutdown_model "$PREV_MODEL"
fi

# --- Zusammenfassung ---
echo ""
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}📋 ERGEBNISSE (t/s via API)${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════════════════${NC}"
echo ""

# Header
printf "  ${BOLD}%-40s" "Modell"
for tok in "${TOKENS[@]}"; do
    printf "│ %8s " "${tok}"
done
echo -e "${NC}"

# Separator
printf "  "
for ((i=0; i<40; i++)); do printf "─"; done
for tok in "${TOKENS[@]}"; do
    printf "┼"; for ((i=0; i<9; i++)); do printf "─"; done
done
echo ""

# Daten
for model in "${BENCH_MODELS[@]}"; do
    name="$model"
    [ ${#name} -gt 38 ] && name="${name:0:35}..."
    printf "  %-40s" "$name"

    for tok in "${TOKENS[@]}"; do
        val="${RESULTS[${model}|${tok}]:-n/a}"
        color=$NC
        if [[ "$val" =~ ^[0-9]+\.?[0-9]*$ ]]; then
            vi=$(python3 -c "print(int(float('$val')))" 2>/dev/null || echo "0")
            [ "$vi" -ge 40 ] && color=$GREEN
            [ "$vi" -ge 25 ] && [ "$vi" -lt 40 ] && color=$YELLOW
            [ "$vi" -gt 0 ] && [ "$vi" -lt 25 ] && color=$RED
            printf "│${color} %7s ${NC}" "${val}"
        else
            printf "│${RED} %7s ${NC}" "$val"
        fi
    done
    echo ""
done

echo ""
echo -e "  ${GREEN}■ >40${NC}  ${YELLOW}■ 25-40${NC}  ${RED}■ <25 t/s${NC}  via API (reiner llama.cpp ~+20%)"
echo ""
[ "$CSV_OUTPUT" = true ] && echo -e "  📁 CSV: ${GREEN}$CSV_FILE${NC}"
echo -e "  Fertig: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
