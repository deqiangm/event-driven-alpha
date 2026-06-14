#!/usr/bin/env bash
# scripts/06_fetch_ipo_underwriter_force.sh — F1: IPO Underwriter Lockup/Stabilization Force
# Detects IPO underwriter stabilization flows and lockup expirations
# stdout=JSON machine output, stderr=human logs

set -euo pipefail
source "$(dirname "$0")/../lib/esad_common.sh"
export EVENTS_DB DATA_DIR CACHE_DIR TODAY

FORCE_DATE="${1:-$TODAY}"
OUTPUT="${CACHE_DIR}/ipo_underwriter_force_${TODAY}.json"

esad_log "F1: Computing IPO Underwriter Stabilization Force for ${FORCE_DATE}"

# ── Step 1: Read upcoming IPO events from events.db ──
read_ipo_events() {
    python3 << 'PYEOF'
import sqlite3, json, os

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
    WHERE event_type = 'ipo'
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

# ── Step 2: Compute F1 underwriter force from IPO events ──
compute_f1() {
    local ipo_events="$1"

    python3 - "$ipo_events" << 'PYEOF' 2>&1 | grep -v '^$'
import json, sys, os
from datetime import date, timedelta

ipo_events_json = sys.argv[1]
try:
    ipo_events = json.loads(ipo_events_json) if ipo_events_json else []
except:
    ipo_events = []

# Underwriter reputation tiers
PRESTIGE_UNDERWRITERS = {
    'Goldman Sachs': 1.0, 'Morgan Stanley': 1.0,
    'J.P. Morgan': 0.95, 'Bank of America': 0.9,
    'Citigroup': 0.85, 'Barclays': 0.85,
    'Credit Suisse': 0.8, 'Deutsche Bank': 0.75,
    'UBS': 0.75, 'Wells Fargo': 0.7
}

today = date.today()
# Force test date if in test environment
test_date = os.environ.get('TODAY', '')
if test_date and len(test_date) == 8:
    today = date(int(test_date[:4]), int(test_date[4:6]), int(test_date[6:8]))

active_forces = []

# ── IPO stabilization window (first 30 days post-IPO) ──
# Underwriters typically support price during stabilization period
for evt in ipo_events:
    evt_date_str = evt.get('event_date', '')
    if not evt_date_str:
        continue

    try:
        y, m, d = map(int, evt_date_str.split('-'))
        ipo_date = date(y, m, d)
    except:
        continue

    days_since_ipo = (today - ipo_date).days
    days_until_ipo = (ipo_date - today).days

    # Force 1a: Pre-IPO bookbuilding demand (0-7 days before IPO)
    if 0 <= days_until_ipo <= 7:
        magnitude = 0.6 + (7 - days_until_ipo) * 0.05
        confidence = 0.55
        underwriter = evt.get('raw_data', {}).get('underwriter', '')
        if underwriter in PRESTIGE_UNDERWRITERS:
            confidence = 0.55 + PRESTIGE_UNDERWRITERS[underwriter] * 0.15

        offering_amount = evt.get('raw_data', {}).get('offering_amount', 0)
        if isinstance(offering_amount, (int, float)) and offering_amount > 500:  # > $500M
            magnitude += 0.15
            confidence += 0.08

        active_forces.append({
            'force_subtype': 'pre_ipo_bookbuilding',
            'ipo_event_id': evt['event_id'],
            'ipo_name': evt['event_name'],
            'ipo_date': evt_date_str,
            'days_until_ipo': days_until_ipo,
            'direction': 'BULLISH',
            'magnitude': round(min(magnitude, 0.95), 3),
            'confidence': round(min(confidence, 0.85), 3),
            'underwriter': underwriter
        })

    # Force 1b: Post-IPO stabilization (first 30 days after IPO)
    if 0 <= days_since_ipo <= 30:
        stabilization_strength = max(0.3, 0.7 - days_since_ipo * 0.015)
        confidence = 0.5
        underwriter = evt.get('raw_data', {}).get('underwriter', '')
        if underwriter in PRESTIGE_UNDERWRITERS:
            confidence = 0.5 + PRESTIGE_UNDERWRITERS[underwriter] * 0.1

        active_forces.append({
            'force_subtype': 'post_ipo_stabilization',
            'ipo_event_id': evt['event_id'],
            'ipo_name': evt['event_name'],
            'ipo_date': evt_date_str,
            'days_since_ipo': days_since_ipo,
            'direction': 'BULLISH',
            'magnitude': round(stabilization_strength, 3),
            'confidence': round(min(confidence, 0.75), 3),
            'underwriter': underwriter
        })

    # Force 1c: Lockup expiration window (-7 to +3 days around lockup expiry)
    # Typically 180 days after IPO
    lockup_date = ipo_date + timedelta(days=180)
    days_until_lockup = (lockup_date - today).days
    if -3 <= days_until_lockup <= 7:
        magnitude = 0.7 - abs(days_until_lockup) * 0.05
        confidence = 0.65
        if days_until_lockup < 0:
            # Lockup expired: insiders can sell
            direction = 'BEARISH'
            magnitude *= 1.2
        else:
            # Pre-lockup: market typically anticipates selling
            direction = 'BEARISH'

        underwriter = evt.get('raw_data', {}).get('underwriter', '')
        if underwriter in PRESTIGE_UNDERWRITERS:
            confidence += PRESTIGE_UNDERWRITERS[underwriter] * 0.1

        active_forces.append({
            'force_subtype': 'lockup_expiration',
            'ipo_event_id': evt['event_id'],
            'ipo_name': evt['event_name'],
            'ipo_date': evt_date_str,
            'lockup_date': lockup_date.isoformat(),
            'days_until_lockup': days_until_lockup,
            'direction': direction,
            'magnitude': round(min(magnitude, 0.9), 3),
            'confidence': round(min(confidence, 0.85), 3),
            'underwriter': underwriter
        })

# ── Syndicate coverage initiation (usually 25-40 days post-IPO) ──
# All underwriters initiate coverage, usually with Buy ratings
for evt in ipo_events:
    evt_date_str = evt.get('event_date', '')
    if not evt_date_str:
        continue
    try:
        y, m, d = map(int, evt_date_str.split('-'))
        ipo_date = date(y, m, d)
    except:
        continue

    days_since_ipo = (today - ipo_date).days
    if 25 <= days_since_ipo <= 40:
        magnitude = 0.55
        confidence = 0.6
        if 30 <= days_since_ipo <= 35:
            # Peak initiation window
            magnitude = 0.65
            confidence = 0.68

        active_forces.append({
            'force_subtype': 'syndicate_coverage_initiation',
            'ipo_event_id': evt['event_id'],
            'ipo_name': evt['event_name'],
            'days_since_ipo': days_since_ipo,
            'direction': 'BULLISH',
            'magnitude': round(magnitude, 3),
            'confidence': round(confidence, 3)
        })

# Build result
result = {
    'date': os.environ.get('TODAY', today.isoformat()),
    'force_code': 'F1',
    'force_name': 'ipo_underwriter_stabilization',
    'active_force_count': len(active_forces),
    'active_forces': active_forces,
    'source_tag': f'ipo_underwriter:{today.strftime("%Y%m%d")}'
}

# Top-level fields for pipeline compatibility
if active_forces:
    best = max(active_forces, key=lambda x: x['confidence'] * x['magnitude'])
    result['direction'] = best['direction']
    result['confidence'] = best['confidence']
    result['magnitude'] = best['magnitude']
else:
    result['direction'] = 'NEUTRAL'
    result['confidence'] = 0.0
    result['magnitude'] = 0.0
    result['source_tag'] += '#inactive'

print(json.dumps(result, indent=2))
PYEOF
}

# ── Main ──
ipo_events=$(read_ipo_events)
ipo_count=$(echo "$ipo_events" | python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())))' 2>/dev/null || echo '0')
esad_log "Found ${ipo_count} IPO events in events.db"

result=$(compute_f1 "$ipo_events")
echo "$result" > "$OUTPUT"
esad_log "F1 output: $(echo "$result" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(f"dir={d.get(\"direction\",\"N/A\")} conf={d.get(\"confidence\",0)} forces={d.get(\"active_force_count\",0)}")' 2>/dev/null || echo 'parse error')"
echo "$result"
