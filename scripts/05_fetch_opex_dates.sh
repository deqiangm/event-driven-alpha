#!/usr/bin/env bash
# 05_fetch_opex_dates.sh — Compute CBOE options expiration dates for next 90 days
# ESAD Phase 1: Data Collection — OpEx events
# Monthly OpEx = third Friday of each month
# Weekly OpEx = every Friday
# Quarter-end OpEx = last trading day before quarter end (Mar/Jun/Sep/Dec)
# magnitude: monthly=0.7, quarterly=0.85, weekly=0.4
# Quarterly OpEx also gets quarter_end event_type.
# Cache at ${CACHE_DIR}/opex_dates.json with 30d TTL.

set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/esad_common.sh"

CACHE_FILE="${CACHE_DIR}/opex_dates.json"

# ── Step 1: Check cache freshness (TTL = 30 days = 720h) ─────────────────
if is_cache_fresh "${CACHE_FILE}" 720; then
    esad_log "OpEx dates cache is fresh, skipping computation"
    CACHED_COUNT="$(python3 -c "
import json
try:
    with open('${CACHE_FILE}') as f:
        d = json.load(f)
    print(len(d.get('events', [])))
except Exception:
    print(0)
")"
    esad_log "Cached OpEx dates: ${CACHED_COUNT}" >&2
    exit 0
fi

# ── Step 2: Compute OpEx dates (no API needed — deterministic) ────────────
esad_log "Computing CBOE options expiration dates for next 90 days..."

RESULT="$(python3 <<'PYEOF'
import json, re
from datetime import date, timedelta

today = date.today()
today_compact = today.strftime('%Y%m%d')
end_date = today + timedelta(days=90)

# Magnitude values as specified
MAG_MONTHLY   = 0.7
MAG_QUARTERLY = 0.85
MAG_WEEKLY    = 0.4
CONFIDENCE    = 0.95  # OpEx dates are deterministic

QUARTER_END_MONTHS = {3, 6, 9, 12}  # Mar, Jun, Sep, Dec

def third_friday_of_month(year, month):
    """Find the 3rd Friday of a given month."""
    first_day = date(year, month, 1)
    # Friday = weekday 4
    first_friday = first_day + timedelta(days=(4 - first_day.weekday()) % 7)
    third_friday = first_friday + timedelta(weeks=2)
    return third_friday

def last_business_day_of_month(year, month):
    """Get last business day (Mon-Fri) before month end."""
    if month == 12:
        last_day = date(year + 1, 1, 1) - timedelta(days=1)
    else:
        last_day = date(year, month + 1, 1) - timedelta(days=1)
    while last_day.weekday() > 4:  # Saturday=5, Sunday=6
        last_day -= timedelta(days=1)
    return last_day

def compute_urgency(days_until):
    """urgency = days_until / 30"""
    return round(days_until / 30.0, 4)

def slugify(s):
    s = s.lower().strip()
    s = re.sub(r'[^a-z0-9]+', '_', s)
    return s.strip('_')[:40]

events = []
seen_dates = {}  # Track dates already added (avoid duplicates)

# ── Compute Monthly OpEx dates (3rd Friday of each month) ────────────────
check_date = today.replace(day=1)
# Go back one month in case today is after the 3rd Friday
if check_date.month == 1:
    check_date = date(check_date.year - 1, 12, 1)
else:
    check_date = date(check_date.year, check_date.month - 1, 1)

while check_date <= end_date:
    year = check_date.year
    month = check_date.month

    third_fri = third_friday_of_month(year, month)

    if today <= third_fri <= end_date:
        is_quarterly = month in QUARTER_END_MONTHS
        mag = MAG_QUARTERLY if is_quarterly else MAG_MONTHLY
        label_type = "Quarterly" if is_quarterly else "Monthly"
        label = f"{label_type} OpEx {third_fri.strftime('%b %Y')}"

        days = (third_fri - today).days
        urgency = compute_urgency(days)

        opex_type = "quarterly" if is_quarterly else "monthly"
        slug = slugify(f"{opex_type}_opex_{third_fri.strftime('%Y%m')}")
        eid = f"evt_{today_compact}_opex_{slug}"

        evt = {
            "event_id": eid,
            "event_type": "opex",
            "event_name": label,
            "event_date": third_fri.isoformat(),
            "opex_type": opex_type,
            "magnitude": mag,
            "urgency": urgency,
            "confidence": CONFIDENCE
        }
        events.append(evt)
        seen_dates[third_fri.isoformat()] = True

        # For quarterly OpEx, also insert a quarter_end event type
        if is_quarterly:
            qe_label = f"Quarter End {third_fri.strftime('%b %Y')}"
            qe_slug = slugify(f"quarter_end_{third_fri.strftime('%Y%m')}")
            qe_eid = f"evt_{today_compact}_quarter_end_{qe_slug}"

            qe_evt = {
                "event_id": qe_eid,
                "event_type": "quarter_end",
                "event_name": qe_label,
                "event_date": third_fri.isoformat(),
                "opex_type": "quarter_end",
                "magnitude": MAG_QUARTERLY,
                "urgency": urgency,
                "confidence": CONFIDENCE
            }
            events.append(qe_evt)

    # Move to next month
    if month == 12:
        check_date = date(year + 1, 1, 1)
    else:
        check_date = date(year, month + 1, 1)

# ── Compute Quarter-end OpEx dates ───────────────────────────────────────
# Quarter-end OpEx = last trading day before quarter end (Mar/Jun/Sep/Dec)
for offset_year in [today.year, today.year + 1]:
    for qm in sorted(QUARTER_END_MONTHS):
        qend = last_business_day_of_month(offset_year, qm)

        if today <= qend <= end_date:
            # Add opex event for the quarter-end business day if not same as monthly
            if qend.isoformat() not in seen_dates:
                days = (qend - today).days
                urgency = compute_urgency(days)

                slug = slugify(f"qe_opex_{qend.strftime('%Y%m')}")
                eid = f"evt_{today_compact}_opex_{slug}"
                label = f"Quarter-End OpEx {qend.strftime('%b %Y')}"

                evt = {
                    "event_id": eid,
                    "event_type": "opex",
                    "event_name": label,
                    "event_date": qend.isoformat(),
                    "opex_type": "quarter_end",
                    "magnitude": MAG_QUARTERLY,
                    "urgency": urgency,
                    "confidence": CONFIDENCE
                }
                events.append(evt)
                seen_dates[qend.isoformat()] = True

            # Also add quarter_end event type for this date
            qe_slug = slugify(f"quarter_end_biz_{qend.strftime('%Y%m')}")
            qe_eid = f"evt_{today_compact}_quarter_end_{qe_slug}"
            qe_label = f"Quarter End {qend.strftime('%b %Y')}"
            days_qe = (qend - today).days

            qe_evt = {
                "event_id": qe_eid,
                "event_type": "quarter_end",
                "event_name": qe_label,
                "event_date": qend.isoformat(),
                "opex_type": "quarter_end",
                "magnitude": MAG_QUARTERLY,
                "urgency": compute_urgency(days_qe),
                "confidence": CONFIDENCE
            }
            events.append(qe_evt)

# ── Compute Weekly OpEx dates (every Friday) ──────────────────────────────
days_to_friday = (4 - today.weekday()) % 7
if days_to_friday == 0 and today.weekday() == 4:
    next_friday = today  # Today is Friday
else:
    next_friday = today + timedelta(days=days_to_friday)

current_friday = next_friday
while current_friday <= end_date:
    if current_friday.isoformat() not in seen_dates:
        days = (current_friday - today).days
        urgency = compute_urgency(days)

        slug = slugify(f"weekly_opex_{current_friday.strftime('%Y%m%d')}")
        eid = f"evt_{today_compact}_opex_{slug}"
        label = f"Weekly OpEx {current_friday.strftime('%a %b %d %Y')}"

        evt = {
            "event_id": eid,
            "event_type": "opex",
            "event_name": label,
            "event_date": current_friday.isoformat(),
            "opex_type": "weekly",
            "magnitude": MAG_WEEKLY,
            "urgency": urgency,
            "confidence": CONFIDENCE
        }
        events.append(evt)

    current_friday += timedelta(weeks=1)

# Sort events by date
events.sort(key=lambda e: e['event_date'])

output = {
    "events": events,
    "fetched_at": today.isoformat(),
    "source": "computed_local",
    "computation_rules": {
        "monthly": "Third Friday of each month",
        "quarterly": "Third Friday of Mar/Jun/Sep/Dec + last business day of quarter",
        "weekly": "Every Friday",
        "quarter_end": "Last trading day before quarter end"
    }
}
print(json.dumps(output, indent=2))
PYEOF
)"

rc=$?
if (( rc != 0 )); then
    esad_err "Python computation failed (rc=${rc})"
    exit 1
fi

# ── Step 4: Insert into events.db ─────────────────────────────────────────
esad_init_events_db

TMP_JSON="$(mktemp /tmp/esad_opex_XXXXXX.json)"
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
        'computed_local', '',
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
esad_log "Computed ${NEW_COUNT:-0} OpEx events (monthly + weekly + quarter-end) for next 90 days" >&2
