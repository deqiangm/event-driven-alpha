#!/usr/bin/env bash
# scripts/11_format_report.sh — P1.16-P1.18: ESAD Alpha Report Formatter
# Reads signals.db + structural forces, formats as human-readable report
# for Telegram/delivery. Also outputs machine-readable JSON.
# Usage: ./11_format_report.sh [date] [--json]

set -euo pipefail
ESAD_ROOT="$(cd "$(dirname "$0")/.."; pwd)"
source "${ESAD_ROOT}/lib/esad_common.sh"

REPORT_DATE="${1:-$TODAY}"
OUTPUT_JSON="${2:-}"
SIGNAL_ID="sig_${REPORT_DATE//-/}"
FORCES_FILE="${DATA_DIR}/structural_forces_${REPORT_DATE}.json"
REPORT_FILE="${DATA_DIR}/esad_report_${REPORT_DATE}.txt"

esad_log "Formatting ESAD report for ${REPORT_DATE}"

# Export variables for Python
export REPORT_DATE SIGNAL_ID SIGNALS_DB FORCES_FILE REPORT_FILE

# ── Format report ──
python3 << 'PYEOF'
import os, json, sqlite3
from datetime import datetime

report_date = os.environ.get('REPORT_DATE', '')
signal_id = os.environ.get('SIGNAL_ID', '')
signals_db = os.environ.get('SIGNALS_DB', '')
forces_file = os.environ.get('FORCES_FILE', '')
report_file = os.environ.get('REPORT_FILE', '')
output_json = "${OUTPUT_JSON}"

# ── Fetch signal from DB ──
conn = sqlite3.connect(signals_db)
c = conn.cursor()
c.execute("""
SELECT signal_id, signal_date, composite_direction, composite_confidence,
       signal_tier, alert_suppressed, source_count, derivative_count,
       confluence_boost, entry_condition, entry_instrument, exit_condition,
       stop_loss, risk_reward, timing_window, alpha_types, structural_score,
       in_af4_pool, design_version
FROM generated_signals
WHERE signal_id = ?
""", (signal_id,))
row = c.fetchone()
conn.close()

if not row:
    print(f"No signal found for {report_date}")
    exit(1)

signal = {
    "signal_id": row[0],
    "date": row[1],
    "direction": row[2],
    "confidence": row[3],
    "tier": row[4],
    "alert_suppressed": row[5] == 1,
    "source_count": row[6] or 0,
    "derivative_count": row[7] or 0,
    "confluence_boost": row[8] or 0,
    "entry_condition": row[9],
    "entry_instrument": row[10],
    "exit_condition": row[11],
    "stop_loss": row[12],
    "risk_reward": row[13],
    "timing_window": row[14],
    "alpha_types": json.loads(row[15]) if row[15] else [],
    "structural_score": row[16] or 0,
    "in_af4_pool": row[17] == 1,
    "design_version": row[18]
}

# ── Load forces summary ──
forces = []
if os.path.exists(forces_file):
    with open(forces_file) as f:
        data = json.load(f)
        forces = data.get('forces_summary', [])

# ── If --json requested ──
if output_json == "--json":
    report = {
        "report_id": f"esad_{report_date.replace('-','')}",
        "report_date": report_date,
        "signal": signal,
        "active_forces": forces,
        "generated_at": datetime.utcnow().isoformat() + 'Z'
    }
    print(json.dumps(report, indent=2))
    exit(0)

# ── Format human-readable report ──
direction = signal['direction']
confidence = signal['confidence']
tier = signal['tier']

dir_emoji = {
    'BULLISH': '🟢',
    'BEARISH': '🔴',
    'NEUTRAL': '⚪'
}.get(direction, '⚪')

tier_label = {
    'STRONG': '🔴 STRONG ALERT',
    'ACTION': '🟢 ACTION NOW',
    'ALERT': '🟠 ALERT',
    'MONITOR': '🟡 MONITOR'
}.get(tier, '⚪ SUPPRESSED')

report_lines = []
report_lines.append("=" * 50)
report_lines.append(f"  ESAD Alpha Signal Report — {report_date}")
report_lines.append("=" * 50)
report_lines.append("")

report_lines.append(f"  SIGNAL: {dir_emoji} {direction}")
report_lines.append(f"  TIER:   {tier_label}")
report_lines.append(f"  CONF:   {confidence:.1%}")
report_lines.append(f"  SCORE:  {signal['structural_score']:.2f}")
report_lines.append("")

report_lines.append("  ── SOURCE ATTRIBUTION ──")
report_lines.append(f"  Independent Sources: {signal['source_count']}")
report_lines.append(f"  Derivative Forces:   {signal['derivative_count']}")
report_lines.append(f"  Confluence Boost:    x{signal['confluence_boost']:.2f}")
report_lines.append(f"  Alpha Types:         {', '.join(signal['alpha_types'])}")
report_lines.append("")

report_lines.append("  ── ACTIVE FORCES ──")
if forces:
    for f in forces:
        f_dir = f.get('dir', 'NEUTRAL')
        f_emoji = '🟢' if f_dir == 'BULLISH' else '🔴' if f_dir == 'BEARISH' else '⚪'
        report_lines.append(f"  {f_emoji} {f.get('code', '?')}: {f.get('src', '')} ({f.get('conf', 0):.0%})")
else:
    report_lines.append("  (No active structural forces)")
report_lines.append("")

report_lines.append("  ── TRADE PARAMETERS ──")
report_lines.append(f"  Instrument:    {signal['entry_instrument']}")
report_lines.append(f"  Entry:         {signal['entry_condition']}")
report_lines.append(f"  Exit:          {signal['exit_condition']}")
report_lines.append(f"  Stop Loss:     {signal['stop_loss']}")
report_lines.append(f"  Risk/Reward:   {signal['risk_reward']}")
report_lines.append(f"  Timing Window: {signal['timing_window']}")
report_lines.append("")

if signal['in_af4_pool']:
    report_lines.append("  ✓ ELIGIBLE for AF4 Alpha Portfolio")
else:
    report_lines.append("  ✗ Not eligible for AF4 Alpha Portfolio")
report_lines.append("")

report_lines.append("=" * 50)
report_lines.append(f"  Design: {signal['design_version']}  |  ID: {signal['signal_id']}")
report_lines.append("=" * 50)

full_report = '\n'.join(report_lines)
print(full_report)

with open(report_file, 'w') as f:
    f.write(full_report)
PYEOF

esad_log "Report saved to: ${REPORT_FILE}"
