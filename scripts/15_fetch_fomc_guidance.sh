#!/usr/bin/env bash
# scripts/15_fetch_fomc_guidance.sh — F5c: Forward Guidance Direction
# Fetches FedWatch implied rates, FOMC language diff, COT positioning
# stdout=JSON machine output, stderr=human logs

set -euo pipefail
source "$(dirname "$0")/../lib/esad_common.sh"

TTL_FEDWATCH_HOURS=24
TTL_COT_DAYS=7
FORCE_DATE="${1:-$TODAY_ISO}"
OUTPUT="${CACHE_DIR}/fomc_guidance_${TODAY}.json"

esad_log "F5c: Fetching FOMC Forward Guidance data for ${FORCE_DATE}"
esad_init_check

# ── Step 1: CME FedWatch implied rates ──
fetch_fedwatch() {
    local cache_file="${CACHE_DIR}/fedwatch_implied_${TODAY}.json"
    if is_cache_fresh "$cache_file" $((TTL_FEDWATCH_HOURS * 60)); then
        esad_dbg "Using cached FedWatch data"
        cat "$cache_file"
        return 0
    fi
    esad_log "Fetching CME FedWatch implied rates"
    local url="https://www.cmegroup.com/cme-api/v1/fedwatchtool/data"
    local http_code
    http_code=$(curl -s -o "$cache_file" -w "%{http_code}" \
        -H "Accept: application/json" "$url" 2>/dev/null) || true
    if [ "$http_code" = "200" ] && [ -s "$cache_file" ]; then
        cat "$cache_file"
    else
        esad_warn "FedWatch API failed (HTTP ${http_code:-none}), using yfinance fallback"
        python3 << 'PYEOF' > "$cache_file" 2>/dev/null
import json, sys
try:
    import yfinance as yf
    ff = yf.Ticker('ZQ=F')
    hist = ff.history(period='5d')
    if len(hist) >= 2:
        latest = float(hist['Close'].iloc[-1])
        prev = float(hist['Close'].iloc[-2])
        implied_rate = 100 - latest
        rate_change_bps = (implied_rate - (100 - prev)) * 100
        print(json.dumps({'implied_rate_pct': round(implied_rate, 2), 'rate_change_bps': round(rate_change_bps, 1), 'source': 'yfinance_ff_fallback'}))
    else:
        print(json.dumps({'implied_rate_pct': 0, 'source': 'yfinance_no_data'}))
except Exception as e:
    print(json.dumps({'implied_rate_pct': 0, 'source': 'yfinance_error'}))
PYEOF
        cat "$cache_file"
    fi
}

# ── Step 2: FOMC language diff (no LLM — shell keyword grep) ──
detect_language_shift() {
    local current_stmt="${CACHE_DIR}/fomc_statement_current.txt"
    local prev_stmt="${CACHE_DIR}/fomc_statement_previous.txt"
    local hawkish="confident on.track further tightening restrictive elevated persistent"
    local dovish="patient data.dependent accommodative balanced transitory easing supportive"
    local hawkish_count=0 dovish_count=0
    if [ -f "$current_stmt" ] && [ -f "$prev_stmt" ]; then
        for kw in $hawkish; do
            cur_n=$(grep -ci "$kw" "$current_stmt" 2>/dev/null || echo 0)
            prev_n=$(grep -ci "$kw" "$prev_stmt" 2>/dev/null || echo 0)
            [ "$cur_n" -gt "$prev_n" ] && hawkish_count=$((hawkish_count + 1))
        done
        for kw in $dovish; do
            cur_n=$(grep -ci "$kw" "$current_stmt" 2>/dev/null || echo 0)
            prev_n=$(grep -ci "$kw" "$prev_stmt" 2>/dev/null || echo 0)
            [ "$cur_n" -gt "$prev_n" ] && dovish_count=$((dovish_count + 1))
        done
    fi
    echo "${hawkish_count}:${dovish_count}"
}

# ── Step 3: COT bond positioning (proxy via TLT volume) ──
fetch_cot() {
    local cache_file="${CACHE_DIR}/cftc_cot_bonds_${TODAY}.json"
    if is_cache_fresh "$cache_file" $((TTL_COT_DAYS * 1440)); then
        esad_dbg "Using cached COT data"
        cat "$cache_file"
        return 0
    fi
    esad_log "Fetching COT bond positioning proxy"
    python3 << 'PYEOF' > "$cache_file" 2>/dev/null
import json, sys
try:
    import yfinance as yf
    tlt = yf.Ticker('TLT')
    hist = tlt.history(period='3mo')
    if len(hist) >= 60:
        recent_vol = float(hist['Volume'].iloc[-5:].mean())
        avg_vol = float(hist['Volume'].iloc[-60:].mean())
        vol_ratio = recent_vol / avg_vol if avg_vol > 0 else 1.0
        recent_ret = (float(hist['Close'].iloc[-1]) / float(hist['Close'].iloc[-5])) - 1
        positioning, zscore = 'neutral', 0.0
        if vol_ratio > 1.5 and recent_ret > 0.02:
            positioning, zscore = 'long_extreme', 2.0
        elif vol_ratio > 1.5 and recent_ret < -0.02:
            positioning, zscore = 'short_extreme', -2.0
        elif vol_ratio > 1.2:
            zscore = 1.0 if recent_ret > 0 else -1.0
            positioning = 'moderate'
        print(json.dumps({'positioning': positioning, 'zscore': zscore, 'vol_ratio': round(vol_ratio, 2), 'source': 'yfinance_tlt_proxy'}))
    else:
        print(json.dumps({'positioning': 'neutral', 'zscore': 0, 'source': 'insufficient_data'}))
except Exception as e:
    print(json.dumps({'positioning': 'neutral', 'zscore': 0, 'source': 'yfinance_error'}))
PYEOF
    cat "$cache_file"
}

# ── Step 4: Compute confidence (Python for float math) ──
compute_f5c() {
    local fedwatch_data="$1"
    local lang_shift="$2"
    local cot_data="$3"
    python3 << PYEOF
import json, sys

fedwatch = json.loads('''$( echo "$fedwatch_data" | python3 -c "import sys,json; print(json.dumps(json.loads(sys.stdin.read())))" 2>/dev/null || echo '{}' )''')
cot = json.loads('''$( echo "$cot_data" | python3 -c "import sys,json; print(json.dumps(json.loads(sys.stdin.read())))" 2>/dev/null || echo '{}' )''')
lang_parts = '$lang_shift'.split(':')
hawkish_n = int(lang_parts[0]) if len(lang_parts) > 0 and lang_parts[0].isdigit() else 0
dovish_n = int(lang_parts[1]) if len(lang_parts) > 1 and lang_parts[1].isdigit() else 0

shift_direction, guidance_gap_bps, direction = 'neutral', 0, 'NEUTRAL'
implied = fedwatch.get('implied_rate_pct', 0)
rate_change = fedwatch.get('rate_change_bps', 0)

if rate_change > 10:
    shift_direction, guidance_gap_bps = 'hawkish', rate_change
elif rate_change < -10:
    shift_direction, guidance_gap_bps = 'dovish', abs(rate_change)

if hawkish_n > dovish_n + 1:
    shift_direction = 'hawkish'
elif dovish_n > hawkish_n + 1:
    shift_direction = 'dovish'

if shift_direction == 'neutral':
    print(json.dumps({'date': '$TODAY_ISO', 'force_code': 'F5c', 'force_name': 'forward_guidance_direction',
        'shift_direction': 'neutral', 'guidance_gap_bps': 0,
        'language_shift': f'hawkish_added={hawkish_n},dovish_added={dovish_n}',
        'implied_rate_pct': implied, 'cot_zscore': cot.get('zscore', 0),
        'direction': 'NEUTRAL', 'confidence': 0.0, 'source_tag': 'fomc_guidance:$TODAY'}))
    sys.exit(0)

confidence = 0.40
direction = 'BEARISH' if shift_direction == 'hawkish' else 'BULLISH'
if guidance_gap_bps > 50: confidence += 0.10
elif guidance_gap_bps > 25: confidence += 0.08
if hawkish_n > 1 or dovish_n > 1: confidence += 0.05
if abs(rate_change) > 25: confidence += 0.07
cot_z = cot.get('zscore', 0)
if abs(cot_z) > 1.5: confidence += 0.05
confidence = min(confidence, 0.65)

print(json.dumps({'date': '$TODAY_ISO', 'force_code': 'F5c', 'force_name': 'forward_guidance_direction',
    'shift_direction': shift_direction, 'guidance_gap_bps': round(guidance_gap_bps, 1),
    'language_shift': f'hawkish_added={hawkish_n},dovish_added={dovish_n}',
    'implied_rate_pct': implied, 'cot_zscore': cot_z,
    'direction': direction, 'confidence': round(confidence, 3),
    'source_tag': 'fomc_guidance:$TODAY'}))
PYEOF
}

# ── Main ──
fedwatch_data=$(fetch_fedwatch)
lang_shift=$(detect_language_shift)
cot_data=$(fetch_cot)
result=$(compute_f5c "$fedwatch_data" "$lang_shift" "$cot_data")
echo "$result" > "$OUTPUT"
esad_log "F5c output: $(echo "$result" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(f"dir={d[\"direction\"]} shift={d[\"shift_direction\"]} conf={d[\"confidence\"]}")' 2>/dev/null || echo 'parse error')"
echo "$result"
