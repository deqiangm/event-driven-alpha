#!/usr/bin/env bash
# scripts/init_databases.sh — Create all 3 ESAD SQLite databases with correct schemas
# Part of Batch 2 (C2): Event-Signal DB Linkage
# Usage: ./init_databases.sh [--force]

set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")"/.. && pwd)"
DATA_DIR="${BASE_DIR}/data"

mkdir -p "$DATA_DIR"

esad_log() { echo "[ESAD-INFO]  $(date +%T) $*" >&2; }

# ─── 1. events.db ───
esad_log "Initializing events.db..."
python3 - "$DATA_DIR" << 'PYEOF'
import sqlite3, sys

data_dir = sys.argv[1]
db_path = f"{data_dir}/events.db"

conn = sqlite3.connect(db_path)
conn.execute('PRAGMA journal_mode=WAL')
conn.executescript("""
CREATE TABLE IF NOT EXISTS upcoming_events (
    event_id      TEXT PRIMARY KEY,
    event_type    TEXT NOT NULL,
    event_name    TEXT NOT NULL,
    event_date    TEXT NOT NULL,
    source        TEXT NOT NULL,
    source_id     TEXT,
    magnitude     REAL,
    urgency       REAL,
    confidence    REAL,
    structural_score REAL,
    raw_data      TEXT,
    created_at    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_events_type ON upcoming_events(event_type);
CREATE INDEX IF NOT EXISTS idx_events_date ON upcoming_events(event_date);
CREATE INDEX IF NOT EXISTS idx_events_source ON upcoming_events(source);
""")
conn.commit()
conn.close()
PYEOF
esad_log "[OK] events.db initialized"

# ─── 2. event_signal_mapping.db ───
esad_log "Initializing event_signal_mapping.db..."
python3 - "$DATA_DIR" << 'PYEOF'
import sqlite3, sys

data_dir = sys.argv[1]
db_path = f"{data_dir}/event_signal_mapping.db"

conn = sqlite3.connect(db_path)
conn.execute('PRAGMA journal_mode=WAL')
conn.executescript("""
CREATE TABLE IF NOT EXISTS structural_forces (
    force_id      TEXT PRIMARY KEY,
    force_code    TEXT NOT NULL,
    force_name    TEXT NOT NULL,
    direction     TEXT NOT NULL,
    confidence    REAL NOT NULL,
    base_confidence REAL,
    conflict_penalty REAL DEFAULT 0.0,
    source_tag    TEXT NOT NULL,
    priority_rank INTEGER,
    override_power REAL,
    trigger_event_ids TEXT NOT NULL,
    trigger_conditions TEXT,
    target_instrument TEXT,
    timing_window_start TEXT,
    timing_window_end   TEXT,
    computed_at   TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    scan_date     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_forces_code   ON structural_forces(force_code);
CREATE INDEX IF NOT EXISTS idx_forces_source ON structural_forces(source_tag);
CREATE INDEX IF NOT EXISTS idx_forces_date   ON structural_forces(scan_date);
CREATE INDEX IF NOT EXISTS idx_forces_event  ON structural_forces(trigger_event_ids);

CREATE TABLE IF NOT EXISTS event_force_map (
    map_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id      TEXT NOT NULL,
    force_id      TEXT NOT NULL,
    relationship  TEXT NOT NULL DEFAULT 'direct',
    derivative_of TEXT,
    created_at    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(event_id, force_id)
);
CREATE INDEX IF NOT EXISTS idx_efm_event ON event_force_map(event_id);
CREATE INDEX IF NOT EXISTS idx_efm_force ON event_force_map(force_id);
CREATE INDEX IF NOT EXISTS idx_efm_rel   ON event_force_map(relationship);

CREATE TABLE IF NOT EXISTS force_signal_map (
    map_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    force_id      TEXT NOT NULL,
    signal_id     TEXT NOT NULL,
    contribution  TEXT NOT NULL DEFAULT 'contributing',
    contribution_weight REAL DEFAULT 1.0,
    created_at    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(force_id, signal_id)
);
CREATE INDEX IF NOT EXISTS idx_fsm_force  ON force_signal_map(force_id);
CREATE INDEX IF NOT EXISTS idx_fsm_signal ON force_signal_map(signal_id);
""")
conn.commit()
conn.close()
PYEOF
esad_log "[OK] event_signal_mapping.db initialized"

# ─── 3. signals.db ───
esad_log "Initializing signals.db..."
python3 - "$DATA_DIR" << 'PYEOF'
import sqlite3, sys

data_dir = sys.argv[1]
db_path = f"{data_dir}/signals.db"

conn = sqlite3.connect(db_path)
conn.execute('PRAGMA journal_mode=WAL')
conn.executescript("""
CREATE TABLE IF NOT EXISTS generated_signals (
    signal_id           TEXT PRIMARY KEY,
    signal_date         TEXT NOT NULL,
    composite_direction TEXT NOT NULL,
    composite_confidence REAL NOT NULL,
    signal_tier         TEXT NOT NULL DEFAULT 'SIGNAL',
    alert_suppressed    INTEGER DEFAULT 0,
    source_count        INTEGER,
    derivative_count    INTEGER,
    confluence_boost    REAL,
    conflict_resolution TEXT,
    event_ids           TEXT NOT NULL DEFAULT '[]',
    force_ids           TEXT NOT NULL DEFAULT '[]',
    entry_condition     TEXT,
    entry_instrument    TEXT,
    exit_condition      TEXT,
    stop_loss           TEXT,
    risk_reward         TEXT,
    timing_window       TEXT,
    alpha_types         TEXT,
    structural_score    REAL,
    in_af4_pool         INTEGER DEFAULT 0,
    design_version      TEXT DEFAULT '1.2-batch2',
    created_at          TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_signals_date      ON generated_signals(signal_date);
CREATE INDEX IF NOT EXISTS idx_signals_tier      ON generated_signals(signal_tier);
CREATE INDEX IF NOT EXISTS idx_signals_direction  ON generated_signals(composite_direction);
""")
conn.commit()
conn.close()
PYEOF
esad_log "[OK] signals.db initialized"

# ─── Verify ───
echo "" >&2
esad_log "All 3 databases ready in ${DATA_DIR}/"
for db in events.db event_signal_mapping.db signals.db; do
    dbfile="${DATA_DIR}/${db}"
    if [ -f "$dbfile" ]; then
        table_count=$(python3 -c "
import sqlite3
conn = sqlite3.connect('${dbfile}')
cur = conn.cursor()
cur.execute(\"SELECT count(*) FROM sqlite_master WHERE type='table'\")
print(cur.fetchone()[0])
conn.close()
")
        esad_log "  ${db}: ${table_count} table(s) OK"
    else
        esad_log "  ${db}: FAILED"
        exit 1
    fi
done
