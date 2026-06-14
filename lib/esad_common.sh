#!/usr/bin/env bash
# esad_common.sh — Shared library for ESAD (Event-Driven Structural Alpha Detector)
# Provides: paths, logging, DB helpers, event ID generation, cache freshness checks

set -uo pipefail

# ── Project root (resolve symlink if needed) ──────────────────────────────
ESAD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
export ESAD_ROOT

# ── Directory layout ──────────────────────────────────────────────────────
DATA_DIR="${ESAD_ROOT}/data"
CACHE_DIR="${DATA_DIR}/cache"
LOG_DIR="${ESAD_ROOT}/log"
CONFIG_DIR="${ESAD_ROOT}/config"
export DATA_DIR CACHE_DIR LOG_DIR CONFIG_DIR

# ── Database paths ────────────────────────────────────────────────────────
EVENTS_DB="${DATA_DIR}/events.db"
SIGNALS_DB="${DATA_DIR}/signals.db"
MAPPING_DB="${DATA_DIR}/event_signal_mapping.db"
export EVENTS_DB SIGNALS_DB MAPPING_DB

# ── Ensure directories exist ──────────────────────────────────────────────
mkdir -p "${DATA_DIR}" "${CACHE_DIR}" "${LOG_DIR}" "${CONFIG_DIR}"

# ── Today's date (YYYY-MM-DD and YYYYMMDD) ───────────────────────────────
TODAY="$(date +%Y-%m-%d)"
TODAY_COMPACT="$(date +%Y%m%d)"
TODAY_ISO="$(date -Iseconds)"
export TODAY TODAY_COMPACT TODAY_ISO

# ── Logging (always to stderr) ────────────────────────────────────────────
esad_log()  { echo "[ESAD INFO]  $(date +%H:%M:%S) $*" >&2; }
esad_dbg()  { echo "[ESAD DEBUG] $(date +%H:%M:%S) $*" >&2; }
esad_warn() { echo "[ESAD WARN]  $(date +%H:%M:%S) $*" >&2; }

# ── Initialization Check ──────────────────────────────────────────────────
esad_init_check() {
    # Ensure databases are initialized
    if [[ ! -f "$EVENTS_DB" ]]; then
        esad_init_events_db
    fi
    if [[ ! -f "$SIGNALS_DB" ]]; then
        esad_init_signals_db
    fi
    if [[ ! -f "$MAPPING_DB" ]]; then
        esad_init_mapping_db
    fi
    # Ensure directories exist
    mkdir -p "$CACHE_DIR" "$DATA_DIR" "$LOG_DIR"
}

# ── Initialize events.db schema ───────────────────────────────────────────
# Supports multi-statement SQL (separated by ;)
esad_sql() {
    local db="$1"; shift
    local sql="$*"
    python3 -c "
import sqlite3, sys
db = sqlite3.connect('${db}')
db.executescript('''${sql}''')
db.commit()
db.close()
"
}

# ── Initialize events.db schema ───────────────────────────────────────────
esad_init_events_db() {
    esad_sql "${EVENTS_DB}" "
    CREATE TABLE IF NOT EXISTS upcoming_events (
        event_id      TEXT PRIMARY KEY,
        event_type    TEXT NOT NULL,
        event_name    TEXT NOT NULL,
        event_date    TEXT NOT NULL,
        magnitude     REAL DEFAULT 0,
        urgency       REAL DEFAULT 0,
        confidence    REAL DEFAULT 0,
        source        TEXT DEFAULT '',
        source_id     TEXT,
        structural_score REAL,
        raw_data      TEXT DEFAULT '',
        created_at    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE INDEX IF NOT EXISTS idx_events_type   ON upcoming_events(event_type);
    CREATE INDEX IF NOT EXISTS idx_events_date   ON upcoming_events(event_date);
    CREATE INDEX IF NOT EXISTS idx_events_urgency ON upcoming_events(urgency);
    "
}

# ── Generate human-readable event ID ──────────────────────────────────────
# Usage: generate_event_id <type> <name_slug>
# Output: evt_YYYYMMDD_type_nameslug
generate_event_id() {
    local etype="$1"
    local name_slug="$2"
    # Sanitize: lowercase, replace non-alnum with _, collapse duplicates
    name_slug="$(echo "${name_slug}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '_' | sed 's/^_//;s/_$//')"
    echo "evt_${TODAY_COMPACT}_${etype}_${name_slug}"
}

# ── Cache freshness check ────────────────────────────────────────────────
# Usage: is_cache_fresh <file> [ttl_hours]
# Returns 0 (true) if file exists and is newer than TTL, 1 (false) otherwise
# Default TTL = 12 hours
is_cache_fresh() {
    local file="$1"
    local ttl_hours="${2:-12}"
    [[ -f "${file}" ]] || return 1
    local file_epoch
    file_epoch="$(stat -c %Y "${file}" 2>/dev/null)" || return 1
    local now_epoch
    now_epoch="$(date +%s)"
    local age=$(( now_epoch - file_epoch ))
    local ttl_seconds=$(( ttl_hours * 3600 ))
    (( age < ttl_seconds ))
}

# ── Insert or replace an event into events.db ────────────────────────────
# Usage: upsert_event <event_id> <event_type> <event_name> <event_date> <magnitude> <urgency> <confidence> [source] [raw_json]
upsert_event() {
    local eid="$1" etype="$2" ename="$3" edate="$4"
    local mag="${5:-0}" urg="${6:-0}" conf="${7:-0}"
    local src="${8:-shell}" raw="${9:-}"
    esad_sql "${EVENTS_DB}" "
    INSERT OR REPLACE INTO upcoming_events (event_id,event_type,event_name,event_date,magnitude,urgency,confidence,source,raw_data,updated_at)
    VALUES ('${eid}','${etype}','${ename}','${edate}',${mag},${urg},${conf},'${src}','${raw}',strftime('%Y-%m-%dT%H:%M:%SZ','now'));
    "
}

# ── HTTP fetch with retry ─────────────────────────────────────────────────
# Usage: esad_curl <url> [timeout_secs] [max_retries]
# Output: response body on stdout, logs to stderr
esad_curl() {
    local url="$1"
    local timeout="${2:-30}"
    local retries="${3:-3}"
    local attempt=1
    while (( attempt <= retries )); do
        esad_log "Fetch attempt ${attempt}/${retries}: ${url}"
        local body
        body="$(curl -sS --max-time "${timeout}" \
            -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' \
            -H 'Accept: application/json' \
            "${url}" 2>/dev/null)" 
        local rc=$?
        if (( rc == 0 )) && [[ -n "${body}" ]]; then
            echo "${body}"
            return 0
        fi
        esad_warn "Fetch failed (rc=${rc}), attempt ${attempt}/${retries}"
        sleep $(( attempt * 2 ))
        (( attempt++ ))
    done
    esad_err "All ${retries} attempts failed for ${url}"
    return 1
}

# ── Python3 JSON helper: extract field(s) from JSON on stdin ──────────────
# Usage: json_extract <python_expr>  (stdin = JSON)
#   e.g. echo "$json" | json_extract "d['data']['rows']"
json_extract() {
    local expr="$1"
    python3 -c "
import json, sys
d = json.load(sys.stdin)
result = ${expr}
if isinstance(result, (list, dict)):
    print(json.dumps(result))
else:
    print(result)
"
}

# ── Compute days until a date (YYYY-MM-DD) ──────────────────────────────
days_until() {
    python3 -c "
from datetime import date
target = date.fromisoformat('$1')
today  = date.today()
print(max(0, (target - today).days))
"
}
