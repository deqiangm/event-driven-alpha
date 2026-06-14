#!/usr/bin/env bash
# 01_fetch_ipo_calendar.sh — Fetch IPO calendar from NASDAQ API
# ESAD Phase 1: Data Collection — IPO events
# Parses IPOs with deal_size, company name, expected date, deal size, underwriter names.
# Mega IPOs (>= $5B): magnitude=deal_size_in_billions/10, confidence=0.85, urgency=days_until/30
# Regular IPOs (>$1B): magnitude=deal_size/10, confidence=0.65, urgency=days_until/30

set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/esad_common.sh"

CACHE_FILE="${CACHE_DIR}/ipo_calendar.json"

# ── Step 1: Check cache freshness (TTL = 24h) ─────────────────────────────
if is_cache_fresh "${CACHE_FILE}" 24; then
    esad_log "IPO calendar cache is fresh, skipping fetch"
    # Count cached events
    CACHED_COUNT="$(python3 -c "
import json, sys
try:
    with open('${CACHE_FILE}') as f:
        d = json.load(f)
    print(len(d.get('events', [])))
except Exception:
    print(0)
")"
    esad_log "Cached IPOs: ${CACHED_COUNT}" >&2
    exit 0
fi

# ── Step 2: Fetch data if stale ───────────────────────────────────────────
esad_log "Fetching IPO calendar from NASDAQ API..."

NASDAQ_URL="https://api.nasdaq.com/api/ipo/calendar?limit=50"
RESPONSE=""

RESPONSE="$(esad_curl "${NASDAQ_URL}" 30 3)" || {
    esad_err "NASDAQ IPO API failed"
    exit 1
}

esad_log "Got NASDAQ response (${#RESPONSE} bytes)"

# ── Step 3: Parse and build events ────────────────────────────────────────
RESULT="$(python3 <<'PYEOF'
import json, sys, re
from datetime import date, datetime, timedelta

try:
    data = json.loads(sys.stdin.read().strip())
except json.JSONDecodeError as e:
    print(json.dumps({"events": [], "error": f"json_decode_error: {e}"}))
    sys.exit(0)

events = []
today = date.today()
today_compact = today.strftime('%Y%m%d')

def parse_deal_size_to_billions(val):
    """Parse deal size string to float (billions USD). Returns 0 if unparseable."""
    if not val:
        return 0.0
    val = str(val).strip().replace(",", "").replace("$", "").strip()
    # Try "X.X B" or "X.X Billion"
    m = re.search(r'([\d.]+)\s*[Bb](?:illion)?', val, re.IGNORECASE)
    if m:
        return float(m.group(1))
    # Try "X.X M" or "X.X Million"
    m = re.search(r'([\d.]+)\s*[Mm](?:illion)?', val, re.IGNORECASE)
    if m:
        return float(m.group(1)) / 1000.0
    # Try raw number — if > 100M assume it's in dollars
    try:
        num = float(val)
        if num > 100_000_000:
            return num / 1_000_000_000.0
        elif num > 100_000:
            return num / 1_000_000.0  # assume raw dollars
        return num  # assume billions already
    except ValueError:
        return 0.0

def slugify(s):
    s = s.lower().strip()
    s = re.sub(r'[^a-z0-9]+', '_', s)
    return s.strip('_')[:40]

# Parse NASDAQ-style response
rows = []
if 'data' in data and isinstance(data['data'], dict):
    rows = data['data'].get('rows', data['data'].get('priced', []))
    if isinstance(rows, dict):
        rows = rows.get('rows', [])
elif 'data' in data and isinstance(data['data'], list):
    rows = data['data']
elif isinstance(data, list):
    rows = data

if isinstance(rows, dict):
    rows = rows.get('rows', rows.get('RESULTS', []))

if not isinstance(rows, list):
    rows = []

for row in rows:
    if not isinstance(row, dict):
        continue

    name = row.get('companyName', row.get('company', row.get('name', '')))
    sym  = row.get('proposedTickerSymbol', row.get('symbol', row.get('ticker', '')))
    edate_str = row.get('expectedPricingDate', row.get('pricedDate', row.get('date', row.get('expectedDate', ''))))
    deal_str  = row.get('dealSize', row.get('dollarValueOfSharesOffered', row.get('deal', row.get('dealSizeText', ''))))
    underwriters = row.get('leadUnderwriter', row.get('underwriters', row.get('underwriter', '')))

    if not name:
        continue

    # Parse date
    event_date = None
    for fmt in ('%m/%d/%Y', '%Y-%m-%d', '%m/%d/%y', '%B %d, %Y', '%b %d, %Y'):
        try:
            event_date = datetime.strptime(str(edate_str).split('T')[0], fmt).date()
            break
        except (ValueError, TypeError):
            continue

    if not event_date:
        # Try to extract any date-like string
        m = re.search(r'(\d{1,2}/\d{1,2}/\d{2,4})', str(edate_str))
        if m:
            for fmt in ('%m/%d/%Y', '%m/%d/%y'):
                try:
                    event_date = datetime.strptime(m.group(1), fmt).date()
                    break
                except ValueError:
                    continue

    if not event_date or event_date < today:
        continue  # skip past IPOs

    deal_b = parse_deal_size_to_billions(deal_str)
    days = (event_date - today).days
    if days < 0:
        days = 0

    edate_iso = event_date.isoformat()
    display_name = f"{name} ({sym})" if sym else name

    # Mega IPO: deal_size >= $5B
    if deal_b >= 5.0:
        magnitude = deal_b / 10.0
        confidence = 0.85
        urgency = round(days / 30.0, 4)
    elif deal_b > 1.0:
        # Regular IPO: > $1B
        magnitude = deal_b / 10.0
        confidence = 0.65
        urgency = round(days / 30.0, 4)
    else:
        # Small IPO — still include but lower params
        magnitude = round(deal_b / 10.0, 4) if deal_b > 0 else 0.05
        confidence = 0.50
        urgency = round(days / 30.0, 4)

    slug = slugify(name)
    eid = f"evt_{today_compact}_ipo_{slug}"

    evt = {
        "event_id": eid,
        "event_type": "ipo",
        "event_name": display_name,
        "event_date": edate_iso,
        "deal_size": deal_str,
        "deal_size_b": deal_b,
        "underwriters": str(underwriters) if underwriters else "",
        "magnitude": magnitude,
        "urgency": urgency,
        "confidence": confidence
    }
    events.append(evt)

output = {"events": events, "fetched_at": today.isoformat(), "source": "nasdaq"}
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

# Write result to temp file for reliable parsing
TMP_JSON="$(mktemp /tmp/esad_ipo_XXXXXX.json)"
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
    # SQL-escape single quotes in names and raw_data
    raw = json.dumps(e)

    cur.execute("""
    INSERT OR REPLACE INTO upcoming_events
    (event_id, event_type, event_name, event_date, source, source_id,
     magnitude, urgency, confidence, structural_score, raw_data, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
    """, (
        e['event_id'], e['event_type'], e['event_name'], e['event_date'],
        'nasdaq', '',
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
esad_log "Fetched ${NEW_COUNT:-0} new IPOs from NASDAQ" >&2
