#!/usr/bin/env bash
# scripts/10_generate_alpha_signals.sh — P1.13-P1.15: Alpha Signal Generation
# Reads structural forces JSON output, maps to signals.db schema,
# computes trade parameters (entry/exit/stop/risk-reward/timing)
# Writes to signals.db, outputs machine-readable JSON to stdout
# stderr: human-readable logs

set -euo pipefail
ESAD_ROOT="$(cd "$(dirname "$0")/.."; pwd)"
source "${ESAD_ROOT}/lib/esad_common.sh"

FORCE_DATE="${1:-$TODAY}"
FORCES_FILE="${DATA_DIR}/structural_forces_${FORCE_DATE}.json"
SIGNAL_ID="sig_${FORCE_DATE//-/}"

esad_log "Generating alpha signals for ${FORCE_DATE}"

# Check if structural forces file exists
if [[ ! -f "${FORCES_FILE}" ]]; then
    esad_err "Structural forces file not found: ${FORCES_FILE}"
    esad_err "Run 09_compute_structural_forces.sh first"
    exit 1
fi

esad_log "Reading structural forces from: ${FORCES_FILE}"

# ── Pipeline ──
# 1. Load forces JSON
# 2. Compute trade parameters based on tier/direction/confidence
# 3. Insert into signals.db
# 4. Output final signal JSON

python3 << PYEOF
import json, sqlite3, os, sys
from datetime import datetime, timedelta

forces_path = "${FORCES_FILE}"
signal_id = "${SIGNAL_ID}"
force_date = "${FORCE_DATE}"
signals_db = "${SIGNALS_DB}"

with open(forces_path) as f:
    forces = json.load(f)

direction = forces.get('direction', 'NEUTRAL')
confidence = forces.get('confidence', 0.0)
signal_tier = forces.get('signal_tier', 'SUPPRESSED')
alert_suppressed = 1 if forces.get('alert_suppressed', True) else 0
source_count = forces.get('confluence_detail', {}).get('independent_sources', 0)
derivative_count = forces.get('confluence_detail', {}).get('total_derivatives', 0)
confluence_boost = forces.get('confluence_detail', {}).get('composite_boost', 1.0)
conflict_count = forces.get('conflict_count', 0)
active_force_count = forces.get('active_force_count', 0)
design_version = forces.get('design_version', '1.2-batch2')

conflicts_detail = forces.get('conflicts_detail', [])
conflict_resolution = json.dumps(conflicts_detail) if conflicts_detail else None

forces_summary = forces.get('forces_summary', [])
force_ids = json.dumps([f.get('code', '') for f in forces_summary]) if forces_summary else '[]'

structural_score = confidence * confluence_boost
in_af4_pool = 1 if (confidence >= 0.5 and direction != 'NEUTRAL' and signal_tier != 'SUPPRESSED') else 0

# ── Compute Trade Parameters based on signal tier, direction, confidence ──
entry_condition = None
entry_instrument = "SPX,SPY,ES"
exit_condition = None
stop_loss = None
risk_reward = None
timing_window = None
alpha_types = []

if direction == 'BULLISH':
    if signal_tier == 'STRONG':
        entry_condition = "Market open next session, limit @ -0.25% gap"
        exit_condition = "3-day hold or +2.0% PnL, whichever comes first"
        stop_loss = "-1.0% hard stop / -1.5% trailing stop"
        risk_reward = "2:1"
        timing_window = "T+3"
        alpha_types = ["event-driven", "structural", "gamma"]
    elif signal_tier == 'ACTION':
        entry_condition = "Market open next session"
        exit_condition = "2-day hold or +1.75% PnL"
        stop_loss = "-0.9% hard stop"
        risk_reward = "1.94:1"
        timing_window = "T+2"
        alpha_types = ["event-driven", "structural", "confluence"]
    elif signal_tier == 'ALERT':
        entry_condition = "Market open next session"
        exit_condition = "2-day hold or +1.5% PnL"
        stop_loss = "-0.8% hard stop"
        risk_reward = "1.88:1"
        timing_window = "T+2"
        alpha_types = ["event-driven", "structural"]
    elif signal_tier == 'MONITOR':
        entry_condition = "Wait for confirmation signal"
        exit_condition = "N/A — monitor only"
        stop_loss = "N/A"
        risk_reward = "N/A"
        timing_window = "TBD"
        alpha_types = ["structural"]
elif direction == 'BEARISH':
    if signal_tier == 'STRONG':
        entry_condition = "Market open next session, limit @ +0.25% gap"
        exit_condition = "3-day hold or -2.0% PnL, whichever comes first"
        stop_loss = "+1.0% hard stop / +1.5% trailing stop"
        risk_reward = "2:1"
        timing_window = "T+3"
        alpha_types = ["event-driven", "structural", "gamma"]
    elif signal_tier == 'ACTION':
        entry_condition = "Market open next session"
        exit_condition = "2-day hold or -1.75% PnL"
        stop_loss = "+0.9% hard stop"
        risk_reward = "1.94:1"
        timing_window = "T+2"
        alpha_types = ["event-driven", "structural", "confluence"]
    elif signal_tier == 'ALERT':
        entry_condition = "Market open next session"
        exit_condition = "2-day hold or -1.5% PnL"
        stop_loss = "+0.8% hard stop"
        risk_reward = "1.88:1"
        timing_window = "T+2"
        alpha_types = ["event-driven", "structural"]
    elif signal_tier == 'MONITOR':
        entry_condition = "Wait for confirmation signal"
        exit_condition = "N/A — monitor only"
        stop_loss = "N/A"
        risk_reward = "N/A"
        timing_window = "TBD"
        alpha_types = ["structural"]
else:  # NEUTRAL / SUPPRESSED
    entry_condition = "No directional edge — hold cash / flat position"
    exit_condition = "N/A"
    stop_loss = "N/A"
    risk_reward = "N/A"
    timing_window = "N/A"
    alpha_types = ["neutral"]

alpha_types_json = json.dumps(alpha_types)

# ── Insert into signals.db ──
conn = sqlite3.connect(signals_db)
c = conn.cursor()

c.execute("""
INSERT OR REPLACE INTO generated_signals (
    signal_id, signal_date, composite_direction, composite_confidence,
    signal_tier, alert_suppressed, source_count, derivative_count,
    confluence_boost, conflict_resolution, event_ids, force_ids,
    entry_condition, entry_instrument, exit_condition, stop_loss,
    risk_reward, timing_window, alpha_types, structural_score,
    in_af4_pool, design_version, created_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
""", (
    signal_id, force_date, direction, confidence,
    signal_tier, alert_suppressed, source_count, derivative_count,
    confluence_boost, conflict_resolution, '[]', force_ids,
    entry_condition, entry_instrument, exit_condition, stop_loss,
    risk_reward, timing_window, alpha_types_json, structural_score,
    in_af4_pool, design_version, datetime.utcnow().isoformat() + 'Z'
))

conn.commit()
row_id = c.lastrowid
conn.close()

# ── Output signal JSON to stdout ──
signal_output = {
    "signal_id": signal_id,
    "date": force_date,
    "direction": direction,
    "confidence": round(confidence, 3),
    "tier": signal_tier,
    "is_alert": alert_suppressed == 0,
    "structural_score": round(structural_score, 3),
    "active_forces": active_force_count,
    "conflicts_resolved": conflict_count,
    "in_af4_pool": in_af4_pool == 1,
    "trade_params": {
        "entry_condition": entry_condition,
        "entry_instrument": entry_instrument,
        "exit_condition": exit_condition,
        "stop_loss": stop_loss,
        "risk_reward": risk_reward,
        "timing_window": timing_window
    },
    "db_row_inserted": row_id is not None and row_id > 0
}

print(json.dumps(signal_output, indent=2))
PYEOF

esad_log "Signal generated successfully"
