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
export REPORT_DATE SIGNAL_ID SIGNALS_DB FORCES_FILE REPORT_FILE OUTPUT_JSON

# ── Format report ──
python3 << 'PYEOF'
import os, json, sqlite3
from datetime import datetime

report_date = os.environ.get('REPORT_DATE', '')
signal_id = os.environ.get('SIGNAL_ID', '')
signals_db = os.environ.get('SIGNALS_DB', '')
forces_file = os.environ.get('FORCES_FILE', '')
report_file = os.environ.get('REPORT_FILE', '')
output_json = os.environ.get('OUTPUT_JSON', '')

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

# ── Load forces summary and details ──
forces = []
force_details = {}
if os.path.exists(forces_file):
    with open(forces_file) as f:
        data = json.load(f)
        forces = data.get('forces_summary', [])
        # Get detailed force data for P2.7 GEX map
        active_forces = data.get('active_forces_data', [])
        for af in active_forces:
            code = af.get('force_code', '')
            if code and 'details' in af:
                force_details[code] = af['details']

# ── GEX Map Visualization Helper (P2.7) ──
def build_gex_ascii_map(gex_details):
    """Build ASCII visualization of strike-level gamma exposure."""
    if not gex_details:
        return []
    
    gex_map = gex_details.get('gex_map', {})
    strikes_raw = gex_map.get('strikes_near_spot', [])
    if not strikes_raw:
        return ["  (GEX map data unavailable)"]
    
    lines = []
    lines.append("  ── GEX MAP (Gamma by Strike) ──")
    
    # Convert to dict format
    strikes = [{'strike': s[0], 'net_gamma': s[1]} for s in strikes_raw]
    
    # Sort strikes
    strikes_sorted = sorted(strikes, key=lambda x: float(x.get('strike', 0)))
    if not strikes_sorted:
        return ["  (No GEX map strikes available)"]
    
    # Normalize for bar chart
    gex_values = [abs(float(s.get('net_gamma', 0))) for s in strikes_sorted]
    max_gex = max(gex_values) if gex_values else 1
    
    spot_price = float(gex_details.get('spot', 0))
    zero_gamma = float(gex_details.get('zero_gamma', 0))
    
    for strike_data in strikes_sorted:
        strike = float(strike_data.get('strike', 0))
        net_gamma = float(strike_data.get('net_gamma', 0))
        
        # Bar width: up to 20 chars
        bar_width = int(abs(net_gamma) / max_gex * 20) if max_gex > 0 else 0
        
        # Call side (positive gamma) = green, Put side (negative gamma) = red
        bar_char = '█' if net_gamma > 0 else '░'
        bar = bar_char * bar_width
        
        # Mark spot price
        spot_marker = '◄ SPOT' if abs(strike - spot_price) < 1.0 else ''
        zg_marker = '◄ ZG' if abs(strike - zero_gamma) < 1.0 else ''
        
        side = 'CALL' if net_gamma > 0 else 'PUT '
        lines.append(f"  {strike:.1f} | {side} | {bar:<20} | ${abs(net_gamma):.2f}M {spot_marker}{zg_marker}")
    
    # Add key gamma levels
    lines.append("")
    lines.append(f"  Zero Gamma Level: ${zero_gamma:.2f}")
    lines.append(f"  Spot Price:       ${spot_price:.2f}")
    lines.append(f"  Distance to ZG:   {gex_details.get('distance_to_zg_pct', 0) * 100:.2f}%")
    lines.append(f"  Regime:           {gex_details.get('gex_regime', 'UNKNOWN')}")
    lines.append(f"  Call/Put Ratio:   {gex_map.get('call_put_ratio', 0):.2f}")
    
    return lines

# ── OpEx Info Helper (P2.6) ──
def build_opex_info(opex_details):
    """Build OpEx calendar signal info section."""
    if not opex_details:
        return []
    
    lines = []
    lines.append("  ── OPEX CALENDAR SIGNAL ──")
    
    days_until = opex_details.get('days_until_opex', '?')
    opex_type = opex_details.get('opex_type', '?')
    next_date = opex_details.get('next_opex_date', '?')
    
    regime = opex_details.get('opex_regime', '?')
    pin_strength = opex_details.get('pinning_strength', 0)
    vol_prob = opex_details.get('volatility_explosion_prob', 0)
    
    lines.append(f"  Next OpEx: {next_date} ({days_until} days, {opex_type})")
    lines.append(f"  Regime:    {regime}")
    lines.append(f"  Pinning:   {pin_strength:.0%}")
    lines.append(f"  Vol Expl:  {vol_prob:.0%}")
    
    return lines

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
    'MILDLY_BULLISH': '🟡',
    'BEARISH': '🔴',
    'MILDLY_BEARISH': '🟠',
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
        f_emoji = '🟢' if f_dir == 'BULLISH' else '🟡' if f_dir == 'MILDLY_BULLISH' else '🔴' if f_dir == 'BEARISH' else '🟠' if f_dir == 'MILDLY_BEARISH' else '⚪'
        report_lines.append(f"  {f_emoji} {f.get('code', '?')}: {f.get('src', '')} ({f.get('conf', 0):.0%})")
else:
    report_lines.append("  (No active structural forces)")
report_lines.append("")

# ── GEX Map Section (P2.7) ──
if 'F2' in force_details:
    gex_lines = build_gex_ascii_map(force_details['F2'])
    for line in gex_lines:
        report_lines.append(line)
    report_lines.append("")

# ── OpEx Calendar Section (P2.6) ──
if 'F2b' in force_details:
    opex_lines = build_opex_info(force_details['F2b'])
    for line in opex_lines:
        report_lines.append(line)
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
