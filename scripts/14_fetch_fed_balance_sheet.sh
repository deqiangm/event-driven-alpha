#!/usr/bin/env bash
# scripts/14_fetch_fed_balance_sheet.sh — F5b: Fed Balance Sheet QT/QE Switch
# Fetches FRED WALCL, Treasury yields, detects balance sheet regime shifts
# stdout=JSON machine output, stderr=human logs

set -euo pipefail
source "$(dirname "$0")/../lib/esad_common.sh"

# ── Config ──
FRED_API_KEY="${FRED_API_KEY:-}"
TTL_BS_DAYS=7
TTL_YIELD_HOURS=24
FORCE_DATE="${1:-$TODAY_ISO}"
OUTPUT="${CACHE_DIR}/fed_balance_sheet_${TODAY}.json"

esad_log "F5b: Fetching Fed Balance Sheet data for ${FORCE_DATE}"
esad_init_check

# ── Step 1: Fetch FRED WALCL ──
fetch_walcl() {
    local cache_file="${CACHE_DIR}/fred_walcl_${TODAY}.json"
    if is_cache_fresh "$cache_file" $((TTL_BS_DAYS * 1440)); then
        esad_dbg "Using cached WALCL data"
        cat "$cache_file"
        return 0
    fi

    esad_log "Fetching FRED WALCL series"
    if [ -n "$FRED_API_KEY" ]; then
        local url="https://api.stlouisfed.org/fred/series/observations?series_id=WALCL&frequency=w&observation_start=2024-01-01&api_key=${FRED_API_KEY}&file_type=json"
        local http_code
        http_code=$(curl -s -o "$cache_file" -w "%{http_code}" "$url" 2>/dev/null) || true
        if [ "$http_code" = "200" ] && [ -s "$cache_file" ]; then
            cat "$cache_file"
            return 0
        fi
        esad_warn "FRED API failed (HTTP ${http_code})"
    else
        esad_warn "FRED_API_KEY not set, skipping FRED API"
    fi

    # Fallback: infer from TLT direction
    python3 << 'PYEOF'
import json, sys
try:
    import yfinance as yf
    tlt = yf.Ticker('TLT')
    hist = tlt.history(period='5d')
    if len(hist) >= 2:
        latest = float(hist['Close'].iloc[-1])
        prev = float(hist['Close'].iloc[-2])
        regime = 'easing' if latest > prev * 1.005 else ('tightening' if latest < prev * 0.995 else 'steady')
        print(json.dumps({'regime_inferred': regime, 'tlt_close': round(latest, 2), 'source': 'yfinance_fallback'}))
    else:
        print(json.dumps({'regime_inferred': 'unknown', 'source': 'yfinance_fallback_no_data'}))
except Exception as e:
    print(json.dumps({'regime_inferred': 'unknown', 'error': str(e), 'source': 'yfinance_fallback_error'}))
PYEOF
}

# ── Step 2: Fetch 10y yield ──
fetch_tnx() {
    local cache_file="${CACHE_DIR}/tnx_${TODAY}.json"
    if is_cache_fresh "$cache_file" $((TTL_YIELD_HOURS * 60)); then
        esad_dbg "Using cached TNX data"
        cat "$cache_file"
        return 0
    fi
    esad_log "Fetching ^TNX (10y yield)"
    python3 << 'PYEOF' > "$cache_file" 2>/dev/null
import json, sys
try:
    import yfinance as yf
    tnx = yf.Ticker('^TNX')
    hist = tnx.history(period='1mo')
    if len(hist) >= 5:
        latest = float(hist['Close'].iloc[-1])
        d2 = float(hist['Close'].iloc[-3]) if len(hist) >= 3 else latest
        d5 = float(hist['Close'].iloc[-6]) if len(hist) >= 6 else latest
        d20 = float(hist['Close'].iloc[0]) if len(hist) >= 20 else latest
        print(json.dumps({
            'tnx_close': round(latest, 3),
            'tnx_2d_change_bps': round((latest - d2) * 100, 1),
            'tnx_5d_change_bps': round((latest - d5) * 100, 1),
            'tnx_20d_change_bps': round((latest - d20) * 100, 1),
            'source': 'yfinance'
        }))
    else:
        print(json.dumps({'tnx_close': 0, 'source': 'yfinance_no_data'}))
except Exception as e:
    print(json.dumps({'error': str(e), 'source': 'yfinance_error'}))
PYEOF
    cat "$cache_file"
}

# ── Step 3: Compute regime & confidence (Python for float math) ──
compute_f5b() {
    local walcl_data="$1"
    local tnx_data="$2"
    python3 -c "
import json, sys

walcl_raw = sys.stdin.readline().strip()
tnx_raw = sys.stdin.readline().strip()
walcl = json.loads(walcl_raw) if walcl_raw else {}
tnx = json.loads(tnx_raw) if tnx_raw else {}

bs_regime, direction, shift_type = 'steady', 'NEUTRAL', 'none'
walcl_total, walcl_weekly_change, qt_pace_b_month = 0, 0, 0
regime_shift_detected, pricing_lag = False, False
confidence = 0.0

observations = walcl.get('observations', [])
if len(observations) >= 4:
    latest_val = float(observations[-1]['value']) if observations[-1]['value'] != '.' else 0
    prev_val = float(observations[-2]['value']) if observations[-2]['value'] != '.' else 0
    month_ago_val = float(observations[-5]['value']) if len(observations) >= 5 and observations[-5]['value'] != '.' else latest_val
    walcl_total = latest_val
    walcl_weekly_change = latest_val - prev_val
    monthly_change = latest_val - month_ago_val
    qt_pace_b_month = abs(monthly_change) if monthly_change < 0 else 0

    if monthly_change < -40000:
        bs_regime, direction, shift_type = 'tightening', 'BEARISH', 'qt_active'
        if len(observations) >= 10:
            two_prev = float(observations[-10]['value']) if observations[-10]['value'] != '.' else latest_val
            two_month_change = (two_prev - month_ago_val)
            regime_shift_detected = (two_month_change >= -40000)
            shift_type = 'qt_start' if regime_shift_detected else 'qt_ongoing'
    elif monthly_change > 40000:
        bs_regime, direction, shift_type = 'easing', 'BULLISH', 'qe_active'
        if len(observations) >= 10:
            two_prev = float(observations[-10]['value']) if observations[-10]['value'] != '.' else latest_val
            two_month_change = (two_prev - month_ago_val)
            regime_shift_detected = (two_month_change <= 40000)
            shift_type = 'qe_start' if regime_shift_detected else 'qe_ongoing'
    else:
        bs_regime, shift_type = 'steady', 'pause'
        direction = 'MILDLY_BULLISH'

inferred = walcl.get('regime_inferred', '')
if inferred and bs_regime == 'steady':
    bs_regime = inferred
    if inferred == 'easing': direction, shift_type = 'BULLISH', 'inferred_easing'
    elif inferred == 'tightening': direction, shift_type = 'BEARISH', 'inferred_tightening'

tnx_2d = tnx.get('tnx_2d_change_bps', 0)
tnx_5d = tnx.get('tnx_5d_change_bps', 0)
if bs_regime in ('tightening', 'easing') and abs(tnx_2d) < 10 and abs(tnx_5d) < 25:
    pricing_lag = True

base = {'qt_start': 0.50, 'qe_start': 0.50, 'qt_active': 0.45, 'qe_active': 0.45,
        'inferred_tightening': 0.45, 'inferred_easing': 0.45, 'qt_ongoing': 0.40,
        'pause': 0.50, 'none': 0.0}.get(shift_type, 0.0)
if shift_type == 'pause': direction = 'MILDLY_BULLISH'

confidence = base
if qt_pace_b_month > 50000: confidence += 0.12
elif qt_pace_b_month > 20000: confidence += 0.05
if pricing_lag: confidence += 0.08
if regime_shift_detected: confidence += 0.07
if abs(tnx_5d) > 25: confidence -= 0.08
confidence = min(confidence, 0.75)
if confidence < 0.35: confidence, direction, shift_type = 0.0, 'NEUTRAL', 'no_shift'

print(json.dumps({
    'date': '$TODAY_ISO', 'force_code': 'F5b', 'force_name': 'fed_balance_sheet_qt_qe',
    'walcl_total': round(walcl_total), 'walcl_weekly_change': round(walcl_weekly_change),
    'bs_regime': bs_regime, 'qt_pace_b_month': round(qt_pace_b_month),
    'regime_shift_detected': regime_shift_detected, 'shift_type': shift_type,
    'pricing_lag': pricing_lag, 'tnx_2d_change_bps': tnx_2d, 'tnx_5d_change_bps': tnx_5d,
    'direction': direction, 'confidence': round(confidence, 3),
    'source_tag': 'fomc_bs:$TODAY'
}))
" <<<"$walcl_data"$'\n'"$tnx_data" 2>/dev/null
}

# ── Main ──
walcl_data=$(fetch_walcl)
tnx_data=$(fetch_tnx)
result=$(compute_f5b "$walcl_data" "$tnx_data")
echo "$result" > "$OUTPUT"
esad_log "F5b output: $(echo "$result" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(f"regime={d[\"bs_regime\"]} dir={d[\"direction\"]} conf={d[\"confidence\"]}")' 2>/dev/null || echo 'parse error')"
echo "$result"
