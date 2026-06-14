#!/usr/bin/env bash
# 02_fetch_sec_filings.sh — Fetch recent S-1 and 424B4 filings from SEC EDGAR
# ESAD Phase 1: Data Collection — SEC filing events
# Fetches S-1 and 424B4 filings with rate limiting (10 req/s max = sleep 0.11s).
# Parses CIK, company name, filing type, filing date. Mega deals get higher magnitude.
# event_type='ipo_filing', source='sec_edgar'. Cache with 12h TTL.

set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/esad_common.sh"

CACHE_FILE="${CACHE_DIR}/sec_filings.json"

# ── Step 1: Check cache freshness (TTL = 12h) ────────────────────────────
if is_cache_fresh "${CACHE_FILE}" 12; then
    esad_log "SEC filings cache is fresh, skipping fetch"
    CACHED_COUNT="$(python3 -c "
import json
try:
    with open('${CACHE_FILE}') as f:
        d = json.load(f)
    print(len(d.get('events', [])))
except Exception:
    print(0)
")"
    esad_log "Cached SEC filings: ${CACHED_COUNT}" >&2
    exit 0
fi

# ── Step 2: Fetch data if stale ───────────────────────────────────────────
esad_log "Fetching S-1 and 424B4 filings from SEC EDGAR..."

# Fetch S-1 filings — save to temp file to avoid shell quoting issues with large JSON
S1_TMP="$(mktemp /tmp/esad_sec_s1_XXXXXX.json)"
if ! esad_curl "https://efts.sec.gov/LATEST/search-index?q=%22S-1%22&dateRange=custom&startdt=2026-01-01&enddt=2026-12-31" 30 3 > "${S1_TMP}"; then
    esad_warn "SEC EDGAR S-1 fetch failed"
    echo '{}' > "${S1_TMP}"
fi

# Rate limit: 10 req/s max => sleep 0.11s between requests
sleep 0.11

# Fetch 424B4 filings (IPO pricing)
B4_TMP="$(mktemp /tmp/esad_sec_b4_XXXXXX.json)"
if ! esad_curl "https://efts.sec.gov/LATEST/search-index?q=%22424B4%22&dateRange=custom&startdt=2026-01-01&enddt=2026-12-31" 30 3 > "${B4_TMP}"; then
    esad_warn "SEC EDGAR 424B4 fetch failed"
    echo '{}' > "${B4_TMP}"
fi

# Rate limit after second request
sleep 0.11

S1_SIZE="$(wc -c < "${S1_TMP}")"
B4_SIZE="$(wc -c < "${B4_TMP}")"
esad_log "Got S-1 (${S1_SIZE} bytes) and 424B4 (${B4_SIZE} bytes) responses"

# ── Step 3: Parse and build events ────────────────────────────────────────
# Write Python parser to a temp file to properly pass file paths as arguments
PARSE_SCRIPT="$(mktemp /tmp/esad_sec_parse_XXXXXX.py)"
cat > "${PARSE_SCRIPT}" <<'PYEOF'
import json, sys, re
from datetime import date, datetime, timedelta

today = date.today()
today_compact = today.strftime('%Y%m%d')
s1_file = sys.argv[1]
b4_file = sys.argv[2]

with open(s1_file, 'r') as f:
    s1_json = f.read()
with open(b4_file, 'r') as f:
    b4_json = f.read()

def parse_deal_size_to_billions(text):
    """Parse offering amount from text, return in billions."""
    if not text:
        return 0.0
    patterns = [
        (r'\$\s*([\d,]+(?:\.\d+)?)\s*billion', 1.0),
        (r'\$\s*([\d,]+(?:\.\d+)?)\s*million', 1e-3),
        (r'\$\s*([\d,]+(?:\.\d+)?)\s*B\b', 1.0),
        (r'\$\s*([\d,]+(?:\.\d+)?)\s*M\b', 1e-3),
        (r'offering amount.*?\$\s*([\d,]+(?:\.\d+)?)', None),
        (r'aggregate offering price.*?\$\s*([\d,]+(?:\.\d+)?)', None),
    ]
    for pat, scale in patterns:
        m = re.search(pat, text, re.IGNORECASE)
        if m:
            val = m.group(1).replace(',', '')
            try:
                num = float(val)
            except ValueError:
                continue
            if scale is not None:
                return num * scale
            else:
                if num > 100_000_000:
                    return num / 1_000_000_000.0
                elif num > 100_000:
                    return num / 1_000_000.0 * 1e-3
                else:
                    return num
    return 0.0

def slugify(s):
    s = s.lower().strip()
    s = re.sub(r'[^a-z0-9]+', '_', s)
    return s.strip('_')[:40]

def parse_sec_hits(data_json_str, form_label):
    """Parse a SEC EDGAR search-index response, return list of event dicts."""
    try:
        d = json.loads(data_json_str.strip())
    except (json.JSONDecodeError, TypeError, ValueError):
        return []

    hits = []
    if 'hits' in d:
        hits = d.get('hits', {}).get('hits', d['hits'])
    elif 'results' in d:
        hits = d['results']
    elif isinstance(d, list):
        hits = d
    elif isinstance(d, dict) and '_source' in d:
        hits = [d]

    events = []
    for hit in hits[:50]:
        source = hit.get('_source', hit) if isinstance(hit, dict) else {}

        form_type = source.get('form_type', source.get('formType', source.get('file_type', '')))
        if not form_type:
            form_type = form_label

        company = source.get('entity_name', source.get('company_name', source.get('companyName', '')))
        if not company:
            display_names = source.get('display_names', [])
            if isinstance(display_names, list) and len(display_names) > 0:
                company = display_names[0] if isinstance(display_names[0], str) else str(display_names[0])

        filed_date = source.get('file_date', source.get('fileDate', source.get('date', source.get('filing_date', ''))))
        accession  = source.get('accession_no', source.get('accessionNumber', ''))
        cik        = source.get('entity_id', source.get('cik', ''))

        # Parse filing date
        event_date = None
        if filed_date:
            for fmt in ('%Y-%m-%d', '%m/%d/%Y', '%Y%m%d'):
                try:
                    event_date = datetime.strptime(str(filed_date).split('T')[0], fmt).date()
                    break
                except ValueError:
                    continue

        if not event_date:
            continue

        # Skip old filings (> 30 days)
        if (today - event_date).days > 30:
            continue

        # Parse deal size from available metadata
        amount_b = 0.0
        text_content = source.get('text', '') or source.get('description', '') or source.get('content', '') or ''
        if text_content:
            amount_b = parse_deal_size_to_billions(text_content)

        # Determine magnitude and confidence
        if amount_b >= 5.0:
            magnitude = amount_b / 10.0
            confidence = 0.85
        elif amount_b >= 1.0:
            magnitude = amount_b / 10.0
            confidence = 0.65
        elif amount_b > 0.1:
            magnitude = amount_b / 10.0
            confidence = 0.50
        else:
            magnitude = 0.05 if form_label == '424B4' else 0.03
            confidence = 0.40

        days = max(0, (event_date - today).days)
        urgency = round(days / 30.0, 4)
        if days == 0:
            urgency = 1.0

        display_name = f"{company} {form_label}"
        slug = slugify(f"{company}_{form_label}")
        eid = f"evt_{today_compact}_ipo_filing_{slug}"

        evt = {
            "event_id": eid,
            "event_type": "ipo_filing",
            "event_name": display_name,
            "event_date": event_date.isoformat(),
            "form_type": form_label,
            "cik": str(cik) if cik else "",
            "accession": str(accession) if accession else "",
            "deal_size_b": amount_b,
            "magnitude": magnitude,
            "urgency": urgency,
            "confidence": confidence
        }
        events.append(evt)

    return events

all_events = []
all_events.extend(parse_sec_hits(s1_json, 'S-1'))
all_events.extend(parse_sec_hits(b4_json, '424B4'))

# Deduplicate by event_id
seen = set()
deduped = []
for e in all_events:
    if e['event_id'] not in seen:
        seen.add(e['event_id'])
        deduped.append(e)

output = {
    "events": deduped,
    "fetched_at": today.isoformat(),
    "source": "sec_edgar"
}
print(json.dumps(output, indent=2))
PYEOF

RESULT="$(python3 "${PARSE_SCRIPT}" "${S1_TMP}" "${B4_TMP}")"

rc=$?
if (( rc != 0 )); then
    esad_err "Python parser failed (rc=${rc})"
    exit 1
fi

# ── Step 4: Insert into events.db ─────────────────────────────────────────
esad_init_events_db

TMP_JSON="$(mktemp /tmp/esad_sec_XXXXXX.json)"
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
        'sec_edgar', e.get('cik', ''),
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
esad_log "Fetched ${NEW_COUNT:-0} new SEC filings (S-1 + 424B4)" >&2

# Clean up temp files
rm -f "${S1_TMP}" "${B4_TMP}" "${PARSE_SCRIPT}" 2>/dev/null || true
