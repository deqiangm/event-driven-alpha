#!/usr/bin/env bash
# lib/esad_common.sh — Shared ESAD shell library
# Provides: logging, ID generation, DB path helpers, common constants
# Source this file: source "$(dirname "$0")/../lib/esad_common.sh"

# ── Paths ──
ESAD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${ESAD_ROOT}/data"
CACHE_DIR="${DATA_DIR}/cache"
LOG_DIR="${ESAD_ROOT}/logs"
CONFIG_DIR="${ESAD_ROOT}/config"

# ── Database paths ──
EVENTS_DB="${DATA_DIR}/events.db"
SIGNALS_DB="${DATA_DIR}/signals.db"
MAPPING_DB="${DATA_DIR}/event_signal_mapping.db"

# ── Constants ──
ESAD_VERSION="1.2-batch2"
TODAY=$(date +%Y%m%d)
TODAY_ISO=$(date +%Y-%m-%d)
YESTERDAY=$(date -d "yesterday" +%Y%m%d 2>/dev/null || date -v-1d +%Y%m%d)

# ── Confidence thresholds ──
CONF_GATE_ACTION=0.65
CONF_GATE_ALERT=0.55
CONF_GATE_WATCH=0.45
CONF_GATE_GLOBAL=0.50

# ── Check which sqlite3 interface is available ──
if command -v sqlite3 &>/dev/null; then
    _ESAD_SQLITE_MODE="cli"
else
    _ESAD_SQLITE_MODE="python"
fi

# ── Unified SQLite executor ──
# Usage: esad_sql "db_path" "SQL statement" [--json]
# Supports both CREATE/INSERT (DDL/DML) and SELECT (query)
# --json flag returns JSON output for SELECT queries
esad_sql() {
    local db_path="$1"
    local sql="$2"
    local json_mode=0
    [[ "${3:-}" = "--json" ]] && json_mode=1

    if [ "$_ESAD_SQLITE_MODE" = "cli" ]; then
        if [ "$json_mode" -eq 1 ]; then
            sqlite3 -json "$db_path" "$sql"
        else
            # Check if it's a SELECT query
            if echo "$sql" | grep -qi '^SELECT\|^ATTACH'; then
                sqlite3 -column -header "$db_path" "$sql"
            else
                sqlite3 "$db_path" "$sql"
            fi
        fi
    else
        # Python fallback — no sqlite3 CLI available
        python3 -c "
import sqlite3, json, sys, os

db_path = ${db_path@Q}
sql = '''$sql'''
json_mode = $json_mode

try:
    conn = sqlite3.connect(db_path)
    # Support ATTACH by executing all statements
    conn.execute('PRAGMA journal_mode=WAL')
    cursor = conn.cursor()
    
    is_select = sql.strip().upper().startswith('SELECT')
    
    if is_select or json_mode:
        cursor.execute(sql)
        rows = cursor.fetchall()
        if rows:
            cols = [d[0] for d in cursor.description]
            if json_mode:
                result = [dict(zip(cols, row)) for row in rows]
                print(json.dumps(result, default=str))
            else:
                # Column format
                fmt = ' | '.join('{:<20}' for _ in cols)
                print(fmt.format(*cols))
                print('-' * (22 * len(cols)))
                for row in rows:
                    print(fmt.format(*[str(c) if c else '' for c in row]))
        else:
            if json_mode:
                print('[]')
    else:
        cursor.executescript(sql)
    conn.commit()
    conn.close()
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
"
    fi
}

# ── Logging (all to stderr, stdout reserved for machine output) ──
esad_log()  { echo "[ESAD-INFO]  $(date +%T) $*" >&2; }
esad_warn() { echo "[ESAD-WARN]  $(date +%T) $*" >&2; }
esad_err()  { echo "[ESAD-ERROR] $(date +%T) $*" >&2; }
esad_dbg()  { [[ "${ESAD_DEBUG:-0}" = "1" ]] && echo "[ESAD-DEBUG] $(date +%T) $*" >&2; return 0; }

# ── ID Generation (human-readable, deterministic) ──
generate_event_id() {
    local event_type="$1"
    local event_date="$2"
    local identifier="$3"
    local clean_id=$(echo "${event_type}_${identifier}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g')
    echo "evt_${event_date//-/}_${clean_id}"
}

generate_force_id() {
    local scan_date="$1"
    local force_code="$2"
    local source_tag="$3"
    local source_suffix="${source_tag##*:}"
    local clean_suffix=$(echo "$source_suffix" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g')
    echo "frc_${scan_date//-/}_${force_code}_${clean_suffix}"
}

# Thread-safe via SQLite (not /tmp file — avoids cron race condition)
generate_signal_id() {
    local signal_date="$1"
    local date_compact="${signal_date//-/}"
    if [ ! -f "$SIGNALS_DB" ]; then
        esad_err "signals.db not found at $SIGNALS_DB"
        echo "ESAD-${date_compact}-000"
        return 1
    fi
    local seq
    seq=$(esad_sql "$SIGNALS_DB" \
        "SELECT COALESCE(MAX(CAST(SUBSTR(signal_id, -3) AS INTEGER)), 0) + 1 FROM generated_signals WHERE signal_date = '${signal_date}'")
    printf "ESAD-%s-%03d" "$date_compact" "$seq"
}

# ── Signal Tier Classification (per C4 Global Confidence Gate) ──
classify_signal_tier() {
    local confidence="$1"
    local tier
    tier=$(python3 -c "
c = $confidence
if c >= 0.65: print('SIGNAL')
elif c >= 0.55: print('ALERT')
elif c >= 0.45: print('POTENTIAL')
else: print('SUPPRESSED')
")
    echo "$tier"
}

# ── Cache helpers ──
is_cache_fresh() {
    local file="$1"
    local max_minutes="$2"
    [ -f "$file" ] && [ "$(find "$file" -mmin -"$max_minutes" 2>/dev/null | wc -l)" -eq 1 ]
}

# ── JSON helpers (jq with python fallback) ──
if command -v jq &>/dev/null; then
    esad_jq() { jq "$@"; }
else
    esad_jq() { python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
# Simple field extraction: esad_jq -r '.field'
import re
expr = ' '.join('''$*'''.split())
if expr.startswith('-r ') or expr.startswith('-c '):
    expr = expr[3:].strip()
result = data
for part in expr.strip('.').split('.'):
    if part:
        if part.endswith('[]'):
            part = part[:-2]
            result = result.get(part, [])
        elif part.startswith('[') and part.endswith(']'):
            idx = int(part[1:-1])
            result = result[idx] if isinstance(result, list) and idx < len(result) else None
        else:
            result = result.get(part, '') if isinstance(result, dict) else ''
if isinstance(result, (dict, list)):
    print(json.dumps(result))
else:
    print(result if result is not None else '')
"; }
fi

# ── Confidence math (bc with python fallback) ──
cap_confidence() {
    local conf="$1"
    local max="${2:-0.85}"
    python3 -c "c=$conf; m=$max; print(f'{min(c,m):.3f}')"
}

# ── Float comparison helper ──
# Usage: float_gt "0.75" "0.65" → returns 0 (true) or 1 (false)
float_gt() { python3 -c "import sys; sys.exit(0 if $1 > $2 else 1)"; }
float_ge() { python3 -c "import sys; sys.exit(0 if $1 >= $2 else 1)"; }
float_lt() { python3 -c "import sys; sys.exit(0 if $1 < $2 else 1)"; }
float_le() { python3 -c "import sys; sys.exit(0 if $1 <= $2 else 1)"; }

# ── Initialization check ──
esad_init_check() {
    mkdir -p "$DATA_DIR" "$CACHE_DIR" "$LOG_DIR" "$CONFIG_DIR"
    return 0
}

# ── Version info ──
esad_version_info() {
    echo "ESAD v${ESAD_VERSION} | data=${DATA_DIR} | cache=${CACHE_DIR} | sqlite=${_ESAD_SQLITE_MODE}" >&2
}
