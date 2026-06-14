#!/usr/bin/env bash
# scripts/07_fetch_fomc_vol_compression_force.sh — F5a: FOMC Volatility Compression Force
# Detects pre-FOMC volatility compression and post-FOMC volatility release
# stdout=JSON machine output, stderr=human logs

set -euo pipefail
source "$(dirname "$0")/../lib/esad_common.sh"
export EVENTS_DB DATA_DIR CACHE_DIR TODAY

FORCE_DATE="${1:-$TODAY}"
OUTPUT="${CACHE_DIR}/fomc_vol_compression_${TODAY_COMPACT}.json"

esad_log "F5a: Computing FOMC Volatility Compression Force for ${FORCE_DATE}"

# ── Step 1: Read upcoming FOMC events from events.db ──
read_fomc_events() {
    python3 << 'PYEOF'
import sqlite3, json, os, sys

db_path = os.environ.get('EVENTS_DB', '')
if not db_path:
    esad_root = os.environ.get('ESAD_ROOT', '')
    db_path = os.path.join(esad_root, 'data', 'events.db') if esad_root else ''

if not db_path or not os.path.exists(db_path):
    print(json.dumps([]))
    sys.exit(0)

conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute('''
    SELECT event_id, event_name, event_date, raw_data
    FROM upcoming_events
    WHERE event_type = 'fomc'
    ORDER BY event_date
''')
events = []
for row in cur.fetchall():
    events.append({
        'event_id': row[0],
        'event_name': row[1],
        'event_date': row[2],
        'raw_data': json.loads(row[3]) if row[3] else {}
    })
conn.close()
print(json.dumps(events))
PYEOF
}

# ── Step 2: Fetch VIX term structure for volatility regime context ──
fetch_vix_regime() {
    # Use existing F9 script output if available
    local vix_cache="${CACHE_DIR}/vix_term_structure_${TODAY_COMPACT}.json"
    if [ -f "$vix_cache" ]; then
        cat "$vix_cache"
    else
        # Fallback: fetch spot VIX from yfinance
        python3 << 'PYEOF' 2>/dev/null
import json
try:
    import yfinance as yf
    vix = yf.Ticker("^VIX")
    hist = vix.history(period='5d')
    if len(hist) > 0:
        spot = float(hist['Close'].iloc[-1])
        print(json.dumps({'spot_vix': round(spot, 2), 'source': 'yfinance_fallback'}))
    else:
        print(json.dumps({'spot_vix': 18.0, 'source': 'default'}))
except:
    print(json.dumps({'spot_vix': 18.0, 'source': 'default'}))
PYEOF
    fi
}

# ── Step 3: Compute F5a volatility compression force ──
compute_f5a() {
    local fomc_events="$1"
    local vix_regime="$2"

    python3 - "$fomc_events" "$vix_regime" << 'PYEOF' 2>&1 | grep -v '^$'
import json, sys, os
from datetime import date

fomc_events_json = sys.argv[1]
vix_regime_json = sys.argv[2]

try:
    fomc_events = json.loads(fomc_events_json) if fomc_events_json else []
except:
    fomc_events = []

try:
    vix_regime = json.loads(vix_regime_json) if vix_regime_json else {}
except:
    vix_regime = {'spot_vix': 18.0}

spot_vix = vix_regime.get('spot_vix', 18.0)

today = date.today()
# Force test date if in test environment
test_date = os.environ.get('TODAY', '')
if test_date and len(test_date) == 8:
    today = date(int(test_date[:4]), int(test_date[4:6]), int(test_date[6:8]))

active_forces = []

for evt in fomc_events:
    evt_date_str = evt.get('event_date', '')
    if not evt_date_str:
        continue

    try:
        y, m, d = map(int, evt_date_str.split('-'))
        fomc_date = date(y, m, d)
    except:
        continue

    days_until_fomc = (fomc_date - today).days
    days_since_fomc = (today - fomc_date).days

    # ── Force 5a.1: Pre-FOMC Volatility Compression (3 days before meeting) ──
    # Markets typically compress volatility ahead of FOMC
    if 0 <= days_until_fomc <= 3:
        magnitude = 0.5 + (3 - days_until_fomc) * 0.1
        confidence = 0.6

        # Higher confidence for rate decision meetings vs. minutes
        is_decision_meeting = 'meeting' in evt.get('event_name', '').lower()
        if is_decision_meeting:
            confidence += 0.12
            magnitude += 0.08

        # High volatility regime: compression effect is stronger
        if spot_vix > 25:
            confidence += 0.08
            magnitude += 0.1
        elif spot_vix > 20:
            confidence += 0.04

        # Compression usually means range-bound or mildly bullish
        active_forces.append({
            'force_subtype': 'pre_fomc_vol_compression',
            'fomc_event_id': evt['event_id'],
            'fomc_date': evt_date_str,
            'days_until_fomc': days_until_fomc,
            'is_decision_meeting': is_decision_meeting,
            'direction': 'BULLISH',
            'magnitude': round(min(magnitude, 0.9), 3),
            'confidence': round(min(confidence, 0.85), 3),
            'volatility_regime_spot': spot_vix
        })

    # ── Force 5a.2: Meeting Day Volatility Release ──
    if days_until_fomc == 0:
        # On meeting day: expect volatility release
        magnitude = 0.85
        confidence = 0.75

        # Volatility regime adjustment
        if spot_vix > 25:
            confidence += 0.08
        elif spot_vix < 15:
            confidence -= 0.05

        active_forces.append({
            'force_subtype': 'fomc_meeting_day_vol_release',
            'fomc_event_id': evt['event_id'],
            'fomc_date': evt_date_str,
            'meeting_day': True,
            'direction': 'VOLATILE',
            'magnitude': round(magnitude, 3),
            'confidence': round(min(confidence, 0.88), 3),
            'volatility_regime_spot': spot_vix,
            'note': 'Expected high volatility, direction uncertain'
        })

    # ── Force 5a.3: Post-FOMC Drift (1-3 days after meeting) ──
    if 1 <= days_since_fomc <= 3:
        magnitude = 0.55 - days_since_fomc * 0.08
        confidence = 0.58 - days_since_fomc * 0.05

        # Post-FOMC drift is typically bullish when no hawkish surprise
        active_forces.append({
            'force_subtype': 'post_fomc_drift',
            'fomc_event_id': evt['event_id'],
            'fomc_date': evt_date_str,
            'days_since_fomc': days_since_fomc,
            'direction': 'BULLISH',
            'magnitude': round(max(magnitude, 0.3), 3),
            'confidence': round(max(confidence, 0.4), 3),
            'volatility_regime_spot': spot_vix
        })

    # ── Force 5a.4: Minutes Release Volatility ──
    is_minutes = 'minute' in evt.get('event_name', '').lower()
    if is_minutes and 0 <= days_until_fomc <= 2:
        magnitude = 0.45
        confidence = 0.52

        active_forces.append({
            'force_subtype': 'fomc_minutes_release',
            'fomc_event_id': evt['event_id'],
            'fomc_date': evt_date_str,
            'days_until_fomc': days_until_fomc,
            'direction': 'VOLATILE',
            'magnitude': round(magnitude, 3),
            'confidence': round(confidence, 3),
            'volatility_regime_spot': spot_vix,
            'note': 'Minutes release typically causes moderate volatility'
        })

# ── Force 5a.5: Fed Blackout Period (10 days before meeting) ──
# Fed officials don't speak publicly — reduces event risk, volatility compresses
for evt in fomc_events:
    evt_date_str = evt.get('event_date', '')
    if not evt_date_str:
        continue
    try:
        y, m, d = map(int, evt_date_str.split('-'))
        fomc_date = date(y, m, d)
    except:
        continue

    days_until_fomc = (fomc_date - today).days
    if 4 <= days_until_fomc <= 10:
        # Blackout period — lower volatility, mild bullish bias
        magnitude = 0.35
        confidence = 0.48

        active_forces.append({
            'force_subtype': 'fed_blackout_period',
            'fomc_event_id': evt['event_id'],
            'fomc_date': evt_date_str,
            'days_until_fomc': days_until_fomc,
            'direction': 'BULLISH',
            'magnitude': round(magnitude, 3),
            'confidence': round(confidence, 3),
            'volatility_regime_spot': spot_vix,
            'note': 'Fed blackout period — reduced event risk'
        })

# Build result
result = {
    'date': os.environ.get('TODAY', today.isoformat()),
    'force_code': 'F5a',
    'force_name': 'fomc_volatility_compression',
    'active_force_count': len(active_forces),
    'active_forces': active_forces,
    'spot_vix': spot_vix,
    'source_tag': f'fomc_vol:{today.strftime("%Y%m%d")}'
}

# Top-level fields for pipeline compatibility
# Filter out VOLATILE direction for top-level (pipeline expects BULLISH/BEARISH/NEUTRAL)
directional_forces = [f for f in active_forces if f['direction'] in ('BULLISH', 'BEARISH')]
if directional_forces:
    best = max(directional_forces, key=lambda x: x['confidence'] * x['magnitude'])
    result['direction'] = best['direction']
    result['confidence'] = best['confidence']
    result['magnitude'] = best['magnitude']
elif active_forces:
    # Only VOLATILE forces — default to NEUTRAL for pipeline
    result['direction'] = 'NEUTRAL'
    result['confidence'] = max(f['confidence'] for f in active_forces)
    result['magnitude'] = max(f['magnitude'] for f in active_forces)
else:
    result['direction'] = 'NEUTRAL'
    result['confidence'] = 0.0
    result['magnitude'] = 0.0
    result['source_tag'] += '#inactive'

print(json.dumps(result, indent=2))
PYEOF
}

# ── Main ──
fomc_events=$(read_fomc_events)
fomc_count=$(echo "$fomc_events" | python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())))' 2>/dev/null || echo '0')
esad_log "Found ${fomc_count} FOMC events in events.db"

vix_regime=$(fetch_vix_regime)
esad_log "VIX regime: $(echo "$vix_regime" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(f"spot={d.get(\"spot_vix\",0)}")' 2>/dev/null || echo 'N/A')"

result=$(compute_f5a "$fomc_events" "$vix_regime")
echo "$result" > "$OUTPUT"
esad_log "F5a output: $(echo "$result" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(f"dir={d.get(\"direction\",\"N/A\")} conf={d.get(\"confidence\",0)} forces={d.get(\"active_force_count\",0)}")' 2>/dev/null || echo 'parse error')"
echo "$result"
