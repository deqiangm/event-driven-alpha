#!/usr/bin/env bash
# scripts/13_fetch_vix_term_structure.sh — F9: VIX Roll Yield Window
# Fetches VIX spot, VIX futures term structure, detects regime shift
# stdout=JSON machine output, stderr=human logs

set -euo pipefail
source "$(dirname "$0")/../lib/esad_common.sh"

FORCE_DATE="${1:-$TODAY_ISO}"
OUTPUT="${CACHE_DIR}/vix_term_structure_${TODAY}.json"
REGIME_HISTORY="${CACHE_DIR}/vix_regime_history.json"

esad_log "F9: Fetching VIX term structure for ${FORCE_DATE}"
esad_init_check

# ── Step 1: Fetch VIX spot ──
fetch_vix_spot() {
    python3 << 'PYEOF' 2>/dev/null
import json, sys
try:
    import yfinance as yf
    vix = yf.Ticker('^VIX')
    hist = vix.history(period='1mo')
    if len(hist) >= 5:
        latest = float(hist['Close'].iloc[-1])
        d5_ago = float(hist['Close'].iloc[-6]) if len(hist) >= 6 else latest
        ma20 = float(hist['Close'].mean()) if len(hist) >= 10 else latest
        change_5d = ((latest / d5_ago) - 1) * 100
        print(json.dumps({
            'vix_spot': round(latest, 2), 'vix_5d_change_pct': round(change_5d, 1),
            'vix_20d_ma': round(ma20, 2), 'source': 'yfinance'
        }))
    else:
        print(json.dumps({'vix_spot': 0, 'vix_5d_change_pct': 0, 'vix_20d_ma': 0, 'source': 'insufficient_data'}))
except Exception as e:
    print(json.dumps({'vix_spot': 0, 'vix_5d_change_pct': 0, 'vix_20d_ma': 0, 'source': 'error'}))
PYEOF
}

# ── Step 2: Fetch VIX futures term structure ──
# CBOE provides delayed settlement prices free
fetch_vix_futures() {
    local cache_file="${CACHE_DIR}/vix_futures_${TODAY}.json"
    if is_cache_fresh "$cache_file" 1440; then
        esad_dbg "Using cached VIX futures data"
        cat "$cache_file"
        return 0
    fi

    esad_log "Fetching CBOE VIX futures settlement"
    local url="https://www.cboe.com/us/futures/market_statistics/settlement/"
    local http_code
    http_code=$(curl -s -o "${cache_file}.html" -w "%{http_code}" "$url" 2>/dev/null) || true

    if [ "$http_code" = "200" ] && [ -s "${cache_file}.html" ]; then
        # Parse HTML table for M1-M4 settlement prices
        python3 << 'PYEOF' 2>/dev/null
import json, re, sys

try:
    with open('${cache_file}.html', 'r') as f:
        html = f.read()

    # Find VIX futures settlement table rows
    # CBOE format typically has contract month and settlement price
    pattern = r'VX\w*\s+(\w+\s+\d{4})[^0-9]*?(\d+\.\d+)'
    matches = re.findall(pattern, html)

    if len(matches) >= 2:
        m1_price = float(matches[0][1])
        m2_price = float(matches[1][1]) if len(matches) > 1 else m1_price
        m3_price = float(matches[2][1]) if len(matches) > 2 else m2_price

        term_state = 'backwardation' if m1_price > m2_price else 'contango'
        m1_m2_spread = round(m1_price - m2_price, 2)
        m2_m3_spread = round(m2_price - m3_price, 2)

        print(json.dumps({
            'm1_price': m1_price, 'm2_price': m2_price, 'm3_price': m3_price,
            'term_state': term_state, 'm1_m2_spread': m1_m2_spread,
            'm2_m3_spread': m2_m3_spread, 'source': 'cboe_html'
        }))
    else:
        print(json.dumps({'source': 'cboe_parse_failed', 'm1_price': 0, 'm2_price': 0, 'm3_price': 0, 'term_state': 'unknown', 'm1_m2_spread': 0, 'm2_m3_spread': 0}))
except Exception as e:
    print(json.dumps({'source': 'error', 'error': str(e), 'm1_price': 0, 'm2_price': 0, 'm3_price': 0, 'term_state': 'unknown', 'm1_m2_spread': 0, 'm2_m3_spread': 0}))
PYEOF
    else
        esad_warn "CBOE fetch failed (HTTP ${http_code:-none}), using yfinance VIX9D/VIX3M proxy"
        # Fallback: use VIX9D (9-day) and VIX3M (3-month) as M1/M2 proxy
        python3 << 'PYEOF' 2>/dev/null
import json, sys
try:
    import yfinance as yf
    vix9d = yf.Ticker('^VIX9D')
    vix3m = yf.Ticker('^VIX3M')
    h1 = vix9d.history(period='5d')
    h2 = vix3m.history(period='5d')
    if len(h1) >= 1 and len(h2) >= 1:
        m1 = float(h1['Close'].iloc[-1])
        m2 = float(h2['Close'].iloc[-1])
        state = 'backwardation' if m1 > m2 else 'contango'
        print(json.dumps({'m1_price': round(m1, 2), 'm2_price': round(m2, 2), 'm3_price': round(m2, 2),
            'term_state': state, 'm1_m2_spread': round(m1 - m2, 2), 'm2_m3_spread': 0,
            'source': 'yfinance_vix9d_vix3m_proxy'}))
    else:
        print(json.dumps({'m1_price': 0, 'm2_price': 0, 'm3_price': 0, 'term_state': 'unknown',
            'm1_m2_spread': 0, 'm2_m3_spread': 0, 'source': 'yfinance_no_data'}))
except Exception as e:
    print(json.dumps({'m1_price': 0, 'm2_price': 0, 'm3_price': 0, 'term_state': 'unknown',
        'm1_m2_spread': 0, 'm2_m3_spread': 0, 'source': 'yfinance_error'}))
PYEOF
    fi
}

# ── Step 3: Track regime history & detect shift ──
detect_regime_shift() {
    local current_state="$1"  # "contango" or "backwardation"
    local today_compact="$TODAY"

    # Read or init regime history
    local history
    if [ -f "$REGIME_HISTORY" ]; then
        history=$(python3 -c "
import json
try:
    with open('$REGIME_HISTORY') as f: data = json.load(f)
    # Keep last 60 days
    data['history'] = data.get('history', [])[-60:]
    data['history'].append({'date': '$today_compact', 'state': '$current_state'})
    print(json.dumps(data))
except: print(json.dumps({'history': [{'date': '$today_compact', 'state': '$current_state'}]}))
" 2>/dev/null)
    else
        history=$(python3 -c "print(json.dumps({'history': [{'date': '$today_compact', 'state': '$current_state'}]}))" 2>/dev/null)
    fi
    echo "$history" > "$REGIME_HISTORY"

    # Compute shift
    python3 -c "
import json, sys
data = json.loads('''$( echo "$history" | python3 -c "import sys,json; print(json.dumps(json.loads(sys.stdin.read())))" 2>/dev/null || echo '{"history":[]}' )''')
hist = data.get('history', [])

shift_detected = False
shift_direction = 'none'
backwardation_days = 0
contango_days = 0

if len(hist) >= 2:
    today_state = hist[-1]['state']
    yesterday_state = hist[-2]['state']
    if today_state != yesterday_state:
        shift_detected = True
        if today_state == 'backwardation' and yesterday_state == 'contango':
            shift_direction = 'c_to_b'
        elif today_state == 'contango' and yesterday_state == 'backwardation':
            shift_direction = 'b_to_c'

    # Count consecutive days
    for i in range(len(hist)-1, -1, -1):
        if hist[i]['state'] == 'backwardation':
            backwardation_days += 1
        else:
            break
    if backwardation_days == 0:
        for i in range(len(hist)-1, -1, -1):
            if hist[i]['state'] == 'contango':
                contango_days += 1
            else:
                break

print(json.dumps({
    'shift_detected': shift_detected, 'shift_direction': shift_direction,
    'backwardation_days': backwardation_days, 'contango_days': contango_days
}))
" 2>/dev/null
}

# ── Step 4: Compute confidence ──
compute_f9() {
    local vix_spot_data="$1"
    local futures_data="$2"
    local regime_data="$3"
    python3 << PYEOF
import json, sys

vix = json.loads('$( echo "$vix_spot_data" | python3 -c "import sys,json; print(json.dumps(json.loads(sys.stdin.read())))" 2>/dev/null || echo '{"vix_spot":0}' )')
fut = json.loads('$( echo "$futures_data" | python3 -c "import sys,json; print(json.dumps(json.loads(sys.stdin.read())))" 2>/dev/null || echo '{"term_state":"unknown"}' )')
reg = json.loads('$( echo "$regime_data" | python3 -c "import sys,json; print(json.dumps(json.loads(sys.stdin.read())))" 2>/dev/null || echo '{"shift_detected":false}' )')

vix_spot = vix.get('vix_spot', 0)
vix_5d_pct = vix.get('vix_5d_change_pct', 0)
term_state = fut.get('term_state', 'unknown')
m1_m2 = fut.get('m1_m2_spread', 0)
m2_m3 = fut.get('m2_m3_spread', 0)

shift_detected = reg.get('shift_detected', False)
shift_dir = reg.get('shift_direction', 'none')
back_days = reg.get('backwardation_days', 0)
cont_days = reg.get('contango_days', 0)

direction, confidence, force_variant = 'NEUTRAL', 0.0, 'none'

if shift_detected and shift_dir == 'c_to_b' and vix_spot > 20:
    # Contango → Backwardation shift: BEARISH equities
    direction = 'BEARISH'
    force_variant = 'backwardation_shift'
    confidence = 0.50
    if vix_spot > 30: confidence += 0.10
    if m1_m2 > 3.0: confidence += 0.08
    confidence += 0.07  # 1-day shift (maximum surprise)
    if vix_5d_pct > 30: confidence += 0.05
    if vix_spot > 50: confidence -= 0.08  # mean-revert risk
elif shift_detected and shift_dir == 'b_to_c' and back_days >= 3:
    # Backwardation → Contango restore: BULLISH equities
    direction = 'BULLISH'
    force_variant = 'contango_restore'
    confidence = 0.45
    if back_days >= 7: confidence += 0.10
    if vix_5d_pct < -5: confidence += 0.08  # rapid normalization
    if vix_spot < 25: confidence += 0.07  # equity recovery
elif term_state == 'backwardation' and back_days >= 5 and m1_m2 > 2.0:
    # Persistent deep backwardation
    direction = 'BEARISH'
    force_variant = 'deep_backwardation'
    confidence = 0.55
elif term_state == 'contango' and cont_days >= 10 and abs(m1_m2) > 1.5 and m1_m2 < 0:
    # Steep contango theta bleed
    direction = 'BULLISH'
    force_variant = 'contango_bleed'
    confidence = 0.50
elif term_state == 'contango' and not shift_detected:
    # Normal contango — weak carry trade signal
    direction = 'BULLISH'
    force_variant = 'contango_steady'
    confidence = 0.40
else:
    confidence = 0.0

confidence = min(confidence, 0.75)
if confidence < 0.35:
    confidence, direction, force_variant = 0.0, 'NEUTRAL', 'no_regime_window'

result = {
    'date': '$TODAY_ISO', 'force_code': 'F9', 'force_name': 'vix_roll_yield_window',
    'vix_spot': vix_spot, 'vix_5d_change_pct': vix_5d_pct,
    'term_state': term_state, 'm1_m2_spread': m1_m2, 'm2_m3_spread': m2_m3,
    'shift_detected': shift_detected, 'shift_direction': shift_dir,
    'backwardation_days': back_days, 'contango_days': cont_days,
    'force_variant': force_variant,
    'direction': direction, 'confidence': round(confidence, 3),
    'source_tag': 'vix_regime:$TODAY'
}
print(json.dumps(result))
PYEOF
}

# ── Main ──
vix_spot_data=$(fetch_vix_spot)
futures_data=$(fetch_vix_futures)

# Detect shift & update regime history
current_term=$(echo "$futures_data" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('term_state','unknown'))" 2>/dev/null || echo "unknown")
regime_data=$(detect_regime_shift "$current_term")

result=$(compute_f9 "$vix_spot_data" "$futures_data" "$regime_data")
echo "$result" > "$OUTPUT"
esad_log "F9 output: $(echo "$result" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(f"term={d[\"term_state\"]} variant={d[\"force_variant\"]} dir={d[\"direction\"]} conf={d[\"confidence\"]}")' 2>/dev/null || echo 'parse error')"
echo "$result"
