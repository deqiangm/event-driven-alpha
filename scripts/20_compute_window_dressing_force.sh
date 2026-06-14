#!/usr/bin/env bash
# 20_compute_window_dressing_force.sh — F3: Window Dressing Force
# Phase 3: P3.1-P3.3 — Quarter-end date tracking + performance ranker + force deduction
#
# Window Dressing Regimes:
#   - T-7 to T-2 before quarter-end: BUY winners, SELL losers
#   - Quarter-end day (T0): Marking the close
#   - T+1 to T+3: Rebound effect (sold losers bounce, bought winners retrace)
#
# Output Format (JSON):
# {
#   "date": "YYYY-MM-DD",
#   "force_code": "F3",
#   "force_name": "Window Dressing",
#   "direction": "BULLISH|BEARISH|NEUTRAL",
#   "confidence": 0.0-1.0,
#   "source_tag": "wd:YYYYMMDD",
#   "details": {
#     "regime": "pre_window|marking_close|rebound",
#     "days_to_quarter_end": int,
#     "quarter_weight": float,
#     "monthly_boost": bool
#   }
# }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/esad_common.sh"

export OUTPUT_FILE="${CACHE_DIR}/quarter_end_${TODAY}.json"

# ── Step 1: Compute dates (P3.1) ──────────────────────────────────────
esad_log "F3: Computing window dressing force"

python3 << 'PYEOF'
import json
import os
import os
from datetime import date, timedelta

today = date.today()
year, month, day = today.year, today.month, today.day

# Determine quarter end
quarter_end_months = [3, 6, 9, 12]
next_q_end_month = min([m for m in quarter_end_months if m >= month], default=3)
next_q_end_year = year if next_q_end_month >= month else year + 1

# Quarter end is last trading day approximation: last day of quarter month
q_end_day = 31 if next_q_end_month in [3, 12] else 30 if next_q_end_month in [6, 9] else 31
quarter_end = date(next_q_end_year, next_q_end_month, q_end_day)

# If already past quarter end, use next
if today > quarter_end:
    idx = quarter_end_months.index(next_q_end_month)
    next_q_end_month = quarter_end_months[(idx + 1) % 4]
    if next_q_end_month == 3:
        next_q_end_year += 1
    q_end_day = 31 if next_q_end_month in [3, 12] else 30
    quarter_end = date(next_q_end_year, next_q_end_month, q_end_day)

days_to_qe = (quarter_end - today).days

# ── Step 2: Determine regime and confidence (P3.3) ───────────────────
# Window dressing weight: Q4 > Q1/Q3 > Q2 (year-end is strongest)
quarter_weights = {1: 0.7, 2: 0.5, 3: 0.7, 4: 1.0}
quarter = (next_q_end_month - 1) // 3 + 1
q_weight = quarter_weights.get(quarter, 0.7)

# Also check if it's month-end (adds boost)
next_month = date(year, month % 12 + 1, 1)
days_to_month_end = (next_month - today).days - 1
is_month_end = days_to_month_end <= 3

# Regime determination
if 2 <= days_to_qe <= 7:
    # Pre-window dressing: buy winners, overall bullish skew (net buy)
    regime = "pre_window"
    direction = "BULLISH"
    base_conf = 0.6
    # Adjust by days from peak window (days 3-5 = peak)
    day_factor = 1.0 if 3 <= days_to_qe <= 5 else 0.8
    confidence = base_conf * q_weight * day_factor
    
elif days_to_qe <= 1:
    # Quarter end marking close: amplified volatility, directional bias weak
    regime = "marking_close"
    direction = "NEUTRAL"
    confidence = 0.3
    
elif -3 <= days_to_qe < 0:
    # Post quarter-end rebound: losers rebound = bullish
    regime = "rebound"
    direction = "BULLISH"
    base_conf = 0.45
    day_factor = 1.0 if abs(days_to_qe) <= 2 else 0.7
    confidence = base_conf * q_weight * day_factor
    
else:
    # Too far from quarter end
    regime = "none"
    direction = "NEUTRAL"
    confidence = 0.1

# Month-end boost (window dressing also happens monthly)
if is_month_end and regime != "none":
    confidence = min(confidence * 1.1, 0.8)

# Cap confidence
confidence = min(confidence, 0.75)

output = {
    "date": f"{today}",
    "force_code": "F3",
    "force_name": "Window Dressing",
    "direction": direction,
    "confidence": round(confidence, 3),
    "source_tag": f"wd:{today.strftime('%Y%m%d')}",
    "details": {
        "regime": regime,
        "days_to_quarter_end": days_to_qe,
        "quarter": quarter,
        "quarter_weight": round(q_weight, 2),
        "is_month_end_aligned": is_month_end,
        "next_quarter_end": f"{quarter_end}"
    }
}

with open(os.environ['OUTPUT_FILE'], 'w') as f:
    json.dump(output, f, indent=2)

print(f"F3: {direction} (conf={confidence:.2f}), regime={regime}, {days_to_qe} days to Q{quarter} end")
PYEOF

esad_log "F3: Output saved to ${OUTPUT_FILE}"
