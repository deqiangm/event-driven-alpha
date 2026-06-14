#!/usr/bin/env bash
# 04_fetch_econ_calendar.sh — Fetch major economic releases for next 90 days
# ESAD Phase 1: Data Collection — Economic release events
# Key releases: NFP (first Friday monthly), CPI (mid-month), PCE (last week monthly),
# Retail Sales (mid-month). Compute from known schedule patterns.
# magnitude: NFP=0.9, CPI=0.85, PCE=0.75, RetailSales=0.65
# confidence=0.85 for scheduled releases. Cache with 24h TTL.

set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/esad_common.sh"

CACHE_FILE="${CACHE_DIR}/econ_calendar.json"

# ── Step 1: Check cache freshness (TTL = 24h) ────────────────────────────
if is_cache_fresh "${CACHE_FILE}" 24; then
    esad_log "Econ calendar cache is fresh, skipping fetch"
    CACHED_COUNT="$(python3 -c "
import json
try:
    with open('${CACHE_FILE}') as f:
        d = json.load(f)
    print(len(d.get('events', [])))
except Exception:
    print(0)
")"
    esad_log "Cached econ releases: ${CACHED_COUNT}" >&2
    exit 0
fi

# ── Step 2: Try FRED API if key is available, else compute locally ───────
esad_log "Computing economic release calendar for next 90 days..."

# Try FRED API if available
RESPONSE=""
SOURCE="computed_schedule"

if [[ -n "${FRED_API_KEY:-}" ]]; then
    esad_log "Using FRED API (key detected)"
    FRED_URL="https://api.stlouisfed.org/fred/releases/dates?api_key=${FRED_API_KEY}&realtime_start=${TODAY}&realtime_end=$(date -d '+90 days' +%Y-%m-%d 2>/dev/null || date -v+90d +%Y-%m-%d 2>/dev/null || echo '2026-09-12')&file_type=json"
    RESPONSE="$(esad_curl "${FRED_URL}" 30 3)" || {
        esad_warn "FRED API failed, falling back to computed schedule"
        RESPONSE=""
    }
    if [[ -n "${RESPONSE}" ]]; then
        SOURCE="fred"
    fi
fi

# ── Step 3: Parse and build events ────────────────────────────────────────
RESULT="$(python3 <<'PYEOF'
import json, sys, re, os
from datetime import date, datetime, timedelta

today = date.today()
today_compact = today.strftime('%Y%m%d')
end_date = today + timedelta(days=90)
source = os.environ.get('ESAD_ECON_SOURCE', 'computed_schedule')

# Magnitude map for key releases as specified
MAG_NFP = 0.9
MAG_CPI = 0.85
MAG_PCE = 0.75
MAG_RETAIL = 0.65
CONFIDENCE = 0.85  # for scheduled releases

def compute_urgency(days_until):
    """urgency = days_until / 30"""
    return round(days_until / 30.0, 4)

def slugify(s):
    s = s.lower().strip()
    s = re.sub(r'[^a-z0-9]+', '_', s)
    return s.strip('_')[:40]

events = []

# Check if we have valid FRED data
raw_input = sys.stdin.read().strip()
fred_data = None
if raw_input:
    try:
        fred_data = json.loads(raw_input)
    except (json.JSONDecodeError, ValueError):
        pass

if fred_data and source == 'fred' and 'release_dates' in fred_data:
    # Parse FRED API response
    KEY_RELEASES = {
        '50': ('NFP', 'Nonfarm Payrolls', MAG_NFP),
        '10': ('CPI', 'Consumer Price Index', MAG_CPI),
        '61': ('PCE', 'Personal Consumption Expenditures', MAG_PCE),
        '78': ('Retail', 'Retail Sales', MAG_RETAIL),
    }

    for rd in fred_data.get('release_dates', []):
        rid = str(rd.get('release_id', ''))
        if rid not in KEY_RELEASES:
            continue

        short, full_name, magnitude = KEY_RELEASES[rid]
        dstr = rd.get('date', rd.get('release_date', ''))

        event_date = None
        for fmt in ('%Y-%m-%d', '%m/%d/%Y'):
            try:
                event_date = datetime.strptime(str(dstr).split('T')[0], fmt).date()
                break
            except ValueError:
                continue

        if not event_date or event_date < today or event_date > end_date:
            continue

        days = max(0, (event_date - today).days)
        urgency = compute_urgency(days)

        label = f"{full_name} ({event_date.strftime('%b %Y')})"
        slug = slugify(f"{short}_{event_date.strftime('%Y%m')}")
        eid = f"evt_{today_compact}_econ_release_{slug}"

        evt = {
            "event_id": eid,
            "event_type": "econ_release",
            "event_name": label,
            "event_date": event_date.isoformat(),
            "release_type": short,
            "magnitude": magnitude,
            "urgency": urgency,
            "confidence": CONFIDENCE
        }
        events.append(evt)

else:
    # Compute from known schedule patterns
    source = "computed_schedule"

    for offset in range(1, 91):
        future = today + timedelta(days=offset)

        # NFP: first Friday of each month
        if future.weekday() == 4:  # Friday
            first_day = future.replace(day=1)
            first_friday = first_day + timedelta(days=(4 - first_day.weekday()) % 7)
            if future == first_friday:
                label = f"Nonfarm Payrolls ({future.strftime('%b %Y')})"
                slug = slugify(f"nfp_{future.strftime('%Y%m')}")
                eid = f"evt_{today_compact}_econ_release_{slug}"
                days = (future - today).days
                events.append({
                    "event_id": eid,
                    "event_type": "econ_release",
                    "event_name": label,
                    "event_date": future.isoformat(),
                    "release_type": "nfp",
                    "magnitude": MAG_NFP,
                    "urgency": compute_urgency(days),
                    "confidence": CONFIDENCE
                })

        # CPI: mid-month, typically 10th-13th, usually Tuesday or Wednesday
        if 10 <= future.day <= 13 and future.weekday() == 2:  # Wednesday
            label = f"CPI ({future.strftime('%b %Y')})"
            slug = slugify(f"cpi_{future.strftime('%Y%m')}")
            eid = f"evt_{today_compact}_econ_release_{slug}"
            days = (future - today).days
            events.append({
                "event_id": eid,
                "event_type": "econ_release",
                "event_name": label,
                "event_date": future.isoformat(),
                "release_type": "cpi",
                "magnitude": MAG_CPI,
                "urgency": compute_urgency(days),
                "confidence": CONFIDENCE
            })

        # PCE: last week of month, typically 26th-31st, Friday
        if 26 <= future.day <= 31 and future.weekday() == 4:  # Friday
            label = f"PCE ({future.strftime('%b %Y')})"
            slug = slugify(f"pce_{future.strftime('%Y%m')}")
            eid = f"evt_{today_compact}_econ_release_{slug}"
            days = (future - today).days
            events.append({
                "event_id": eid,
                "event_type": "econ_release",
                "event_name": label,
                "event_date": future.isoformat(),
                "release_type": "pce",
                "magnitude": MAG_PCE,
                "urgency": compute_urgency(days),
                "confidence": CONFIDENCE
            })

        # Retail Sales: mid-month, typically 14th-15th, Wednesday
        if 14 <= future.day <= 16 and future.weekday() == 2:  # Wednesday
            label = f"Retail Sales ({future.strftime('%b %Y')})"
            slug = slugify(f"retail_{future.strftime('%Y%m')}")
            eid = f"evt_{today_compact}_econ_release_{slug}"
            days = (future - today).days
            events.append({
                "event_id": eid,
                "event_type": "econ_release",
                "event_name": label,
                "event_date": future.isoformat(),
                "release_type": "retail",
                "magnitude": MAG_RETAIL,
                "urgency": compute_urgency(days),
                "confidence": CONFIDENCE
            })

# Deduplicate by event_id
seen = set()
deduped = []
for e in events:
    if e['event_id'] not in seen:
        seen.add(e['event_id'])
        deduped.append(e)

output = {
    "events": deduped,
    "fetched_at": today.isoformat(),
    "source": source
}
print(json.dumps(output, indent=2))
PYEOF
)" <<< "${RESPONSE}"

rc=$?
if (( rc != 0 )); then
    esad_err "Python parser failed (rc=${rc})"
    exit 1
fi

# ── Step 4: Insert into events.db ─────────────────────────────────────────
esad_init_events_db

TMP_JSON="$(mktemp /tmp/esad_econ_XXXXXX.json)"
echo "${RESULT}" > "${TMP_JSON}"

NEW_COUNT="$(python3 - "${TMP_JSON}" <<'PYEOF'
import json, sys, sqlite3, os

db_path = os.environ.get('EVENTS_DB', '')
if not db_path:
    esad_root = os.environ.get('ESAD_ROOT', '')
    db_path = os.path.join(esad_root, 'data', 'events.db') if esad_root else ''
if not db_path:
    sys.exit(1)

json_file = sys.argv[1]
if not json_file or not os.path.exists(json_file):
    sys.exit(1)

with open(json_file) as f:
    data = json.load(f)

events = data.get('events', [])
if not events:
    print(0)
    sys.exit(0)

conn = sqlite3.connect(db_path)
cur = conn.cursor()

for e in events:
    raw = json.dumps(e)
    cur.execute("""
    INSERT OR REPLACE INTO upcoming_events
    (event_id, event_type, event_name, event_date, source, source_id,
     magnitude, urgency, confidence, structural_score, raw_data, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
    """, (
        e['event_id'], e['event_type'], e['event_name'], e['event_date'],
        'computed_schedule', '',
        e.get('magnitude', 0), e.get('urgency', 0), e.get('confidence', 0),
        round(e.get('magnitude', 0) * e.get('urgency', 0) * e.get('confidence', 0), 6),
        raw
    ))

conn.commit()
conn.close()
print(len(events))
PYEOF
)"

rc=$?
if (( rc != 0 )); then
    esad_err "DB upsert failed (rc=${rc})"
fi

# ── Step 5: Write cache file ─────────────────────────────────────────────
echo "${RESULT}" > "${CACHE_FILE}"
esad_log "Wrote cache: ${CACHE_FILE} (${#RESULT} bytes)"

# ── Output summary to stderr ──────────────────────────────────────────────
esad_log "Fetched ${NEW_COUNT:-0} economic release events for next 90 days" >&2
