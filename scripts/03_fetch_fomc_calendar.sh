#!/usr/bin/env bash
# 03_fetch_fomc_calendar.sh — Fetch FOMC meeting schedule
# ESAD Phase 1: Data Collection — FOMC events
# Primary: Try Federal Reserve website. Fallback: known 2026 FOMC schedule.
# FOMC 2026 dates: Jun 17, Jul 29, Sep 16, Nov 4, Dec 16.
# Minutes: 3 weeks after each meeting.
# Rate decision: magnitude=0.85, confidence=0.9, urgency=days_until/30
# Minutes: magnitude=0.5, confidence=0.9, urgency=days_until/30
# Cache at ${CACHE_DIR}/fomc_calendar.json with 7d TTL.

set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/esad_common.sh"

CACHE_FILE="${CACHE_DIR}/fomc_calendar.json"

# ── Step 1: Check cache freshness (TTL = 7 days = 168h) ──────────────────
if is_cache_fresh "${CACHE_FILE}" 168; then
    esad_log "FOMC calendar cache is fresh, skipping fetch"
    CACHED_COUNT="$(python3 -c "
import json
try:
    with open('${CACHE_FILE}') as f:
        d = json.load(f)
    print(len(d.get('events', [])))
except Exception:
    print(0)
")"
    esad_log "Cached FOMC events: ${CACHED_COUNT}" >&2
    exit 0
fi

# ── Step 2: Fetch data if stale ───────────────────────────────────────────
esad_log "Fetching FOMC calendar from Federal Reserve..."

FED_URL="https://www.federalreserve.gov/monetarypolicy/fomccalendars.htm"
RESPONSE=""
FETCH_OK=false

# Try primary URL
RESPONSE="$(curl -sS --max-time 30 \
    -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36' \
    -H 'Accept: text/html' \
    "${FED_URL}" 2>/dev/null)" && FETCH_OK=true || true

if [[ "${FETCH_OK}" != "true" ]] || [[ -z "${RESPONSE}" ]]; then
    esad_warn "Primary Fed URL failed, trying alternate..."
    FED_ALT="https://www.federalreserve.gov/newsevents/calendar.htm"
    RESPONSE="$(esad_curl "${FED_ALT}" 30 3)" || {
        esad_warn "Fed website unreachable, using hardcoded 2026 schedule"
        RESPONSE=""
    }
fi

# ── Step 3: Parse and build events ────────────────────────────────────────
RESULT="$(python3 <<'PYEOF'
import json, sys, re
from datetime import date, timedelta

today = date.today()
today_compact = today.strftime('%Y%m%d')

# ── Hardcoded FOMC 2026 schedule (8 meetings, ~6 weeks apart) ───────────
# Rate decision dates
FOMC_2026_RATE_DECISIONS = [
    date(2026, 1, 28),
    date(2026, 3, 18),
    date(2026, 5, 6),
    date(2026, 6, 17),
    date(2026, 7, 29),
    date(2026, 9, 16),
    date(2026, 11, 4),
    date(2026, 12, 16),
]

# FOMC minutes = 3 weeks (21 days) after each meeting
FOMC_2026_MINUTES = [d + timedelta(days=21) for d in FOMC_2026_RATE_DECISIONS]

# Also include remaining 2025 dates if still in the future
FOMC_2025_RATE_DECISIONS = [
    date(2025, 6, 18),
    date(2025, 7, 30),
    date(2025, 9, 17),
    date(2025, 11, 5),
    date(2025, 12, 17),
]
FOMC_2025_MINUTES = [d + timedelta(days=21) for d in FOMC_2025_RATE_DECISIONS]

SOURCE = "hardcoded_2026_schedule"
html = sys.stdin.read().strip() if not sys.stdin.isatty() else ""

parsed_rate_dates = []
parsed_minutes_dates = []

if html:
    # Try to parse FOMC dates from HTML
    month_map = {
        'january': 1, 'february': 2, 'march': 3, 'april': 4,
        'may': 5, 'june': 6, 'july': 7, 'august': 8,
        'september': 9, 'october': 10, 'november': 11, 'december': 12
    }

    # Pattern: "June 17-18, 2026" or "March 18, 2026"
    p1 = r'(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{1,2})(?:\s*[-\u2013]\s*\d{1,2})?,?\s*(\d{4})'
    for m in re.finditer(p1, html, re.IGNORECASE):
        try:
            mon = month_map[m.group(1).lower()]
            day = int(m.group(2))
            year = int(m.group(3))
            d = date(year, mon, day)
            if d >= today and d.year in (2025, 2026):
                parsed_rate_dates.append(d)
        except (ValueError, KeyError):
            continue

    # Pattern: ISO dates in data attributes
    for m in re.finditer(r'(\d{4})-(\d{2})-(\d{2})', html):
        try:
            d = date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
            if d >= today and d.year in (2025, 2026):
                parsed_rate_dates.append(d)
        except ValueError:
            continue

events = []

if parsed_rate_dates:
    # Use website-parsed dates
    SOURCE = "federal_reserve"
    deduped = sorted(set(parsed_rate_dates))
    for d in deduped:
        is_rate_decision = True  # Assume website dates are meetings
        label = f"FOMC Rate Decision {d.strftime('%b %Y')}"
        minutes_date = d + timedelta(days=21)

        # Rate decision event
        days = max(0, (d - today).days)
        magnitude = 0.85
        confidence = 0.9
        urgency = round(days / 30.0, 4)

        slug = f"fomc_rate_decision_{d.strftime('%Y%m')}"
        eid = f"evt_{today_compact}_fomc_{slug}"

        evt = {
            "event_id": eid,
            "event_type": "fomc",
            "event_name": label,
            "event_date": d.isoformat(),
            "is_rate_decision": True,
            "magnitude": magnitude,
            "urgency": urgency,
            "confidence": confidence
        }
        events.append(evt)

        # Minutes release event
        if minutes_date >= today:
            m_days = max(0, (minutes_date - today).days)
            m_label = f"FOMC Minutes {d.strftime('%b %Y')}"
            m_urgency = round(m_days / 30.0, 4)
            m_slug = f"fomc_minutes_{minutes_date.strftime('%Y%m')}"
            m_eid = f"evt_{today_compact}_fomc_{m_slug}"

            m_evt = {
                "event_id": m_eid,
                "event_type": "fomc",
                "event_name": m_label,
                "event_date": minutes_date.isoformat(),
                "is_rate_decision": False,
                "magnitude": 0.5,
                "urgency": m_urgency,
                "confidence": 0.9
            }
            events.append(m_evt)
else:
    # Fallback: use hardcoded schedule
    all_rate = FOMC_2025_RATE_DECISIONS + FOMC_2026_RATE_DECISIONS
    all_minutes = FOMC_2025_MINUTES + FOMC_2026_MINUTES

    for d in all_rate:
        if d < today:
            continue
        days = max(0, (d - today).days)
        magnitude = 0.85
        confidence = 0.9
        urgency = round(days / 30.0, 4)

        label = f"FOMC Rate Decision {d.strftime('%b %Y')}"
        slug = f"fomc_rate_decision_{d.strftime('%Y%m')}"
        eid = f"evt_{today_compact}_fomc_{slug}"

        evt = {
            "event_id": eid,
            "event_type": "fomc",
            "event_name": label,
            "event_date": d.isoformat(),
            "is_rate_decision": True,
            "magnitude": magnitude,
            "urgency": urgency,
            "confidence": confidence
        }
        events.append(evt)

    for i, d in enumerate(all_minutes):
        if d < today:
            continue
        m_days = max(0, (d - today).days)
        m_urgency = round(m_days / 30.0, 4)

        # Find the corresponding meeting date for labeling
        all_rate_list = all_rate
        meeting_date = all_rate_list[i] if i < len(all_rate_list) else d
        m_label = f"FOMC Minutes {meeting_date.strftime('%b %Y')}"
        m_slug = f"fomc_minutes_{d.strftime('%Y%m')}"
        m_eid = f"evt_{today_compact}_fomc_{m_slug}"

        m_evt = {
            "event_id": m_eid,
            "event_type": "fomc",
            "event_name": m_label,
            "event_date": d.isoformat(),
            "is_rate_decision": False,
            "magnitude": 0.5,
            "urgency": m_urgency,
            "confidence": 0.9
        }
        events.append(m_evt)

output = {
    "events": events,
    "fetched_at": today.isoformat(),
    "source": SOURCE
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

TMP_JSON="$(mktemp /tmp/esad_fomc_XXXXXX.json)"
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
        'federal_reserve', '',
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
esad_log "Fetched ${NEW_COUNT:-0} FOMC events (rate decisions + minutes)" >&2
