#!/usr/bin/env bash
# 23_monitor_index_rebalancing.sh — F6: Index Rebalancing Force
# Phase 3: P3.7 — S&P/Russell rebalancing calendar monitor
#
# Index Rebalancing Regimes:
#   - Russell: Annual rebalance (June 3rd Friday)
#   - S&P 500: Quarterly rebalance (3/6/9/12 third Friday)
#   - T-7 to T-1: Tracking funds front-run → volume spike
#   - Effect size: Russell > S&P, additions > deletions
#
# Output Format (JSON):
# {
#   "date": "YYYY-MM-DD",
#   "force_code": "F6",
#   "force_name": "Index Rebalancing",
#   "direction": "BULLISH|BEARISH|NEUTRAL",
#   "confidence": 0.0-1.0,
#   "source_tag": "rebal:YYYYMMDD",
#   "details": {
#     "upcoming_rebalances": [...],
#     "days_to_next_rebal": int,
#     "rebal_magnitude_score": float,
#     "regime": "front_running|execution|none"
#   }
# }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/esad_common.sh"

export OUTPUT_FILE="${CACHE_DIR}/index_rebalancing_${TODAY}.json"

esad_log "F6: Monitoring index rebalancing force"

python3 << 'PYEOF'
import json
import os
from datetime import date, timedelta
from calendar import monthrange

today = date.today()

# ── Step 1: Calculate rebalance dates (S&P + Russell) ──────────────
# S&P 500 quarterly rebalance: 3rd Friday of Mar/Jun/Sep/Dec
# Russell annual rebalance: 3rd Friday of June (biggest one)

def get_third_friday(year, month):
    """Get 3rd Friday of given month."""
    # First day of month
    first_day = date(year, month, 1)
    # Find first Friday
    days_to_first_friday = (4 - first_day.weekday()) % 7  # Friday = 4
    first_friday = first_day + timedelta(days=days_to_first_friday)
    # Third Friday = first Friday + 14 days
    third_friday = first_friday + timedelta(days=14)
    return third_friday

rebalance_dates = []

# Next 12 months of S&P quarterly rebalances
for offset in range(12):
    m = (today.month + offset - 1) % 12 + 1
    y = today.year + (today.month + offset - 1) // 12
    if m in [3, 6, 9, 12]:
        rb_date = get_third_friday(y, m)
        days_to = (rb_date - today).days
        is_russell = (m == 6)  # Russell annual in June (biggest)
        rebalance_dates.append({
            'date': f"{rb_date}",
            'index': 'S&P500' + ('+Russell' if is_russell else ''),
            'type': 'quarterly' + ('+annual' if is_russell else ''),
            'days_to': days_to,
            'magnitude': 1.5 if is_russell else 1.0
        })

# Filter to upcoming
upcoming = [r for r in rebalance_dates if -3 <= r['days_to'] <= 30]

# ── Step 2: Determine regime and force ──────────────────────────────
if not upcoming:
    direction = "NEUTRAL"
    confidence = 0.1
    regime = "none"
    next_rebal = None
else:
    next_rebal = min(upcoming, key=lambda x: abs(x['days_to']))
    days_to = next_rebal['days_to']
    magnitude = next_rebal['magnitude']
    
    if 2 <= days_to <= 10:
        # Front-running window: tracking funds buy additions
        regime = "front_running"
        direction = "BULLISH"  # Net effect: additions > deletions in market cap
        base_conf = 0.45
        day_factor = 1.0 if 3 <= days_to <= 7 else 0.7
        confidence = base_conf * magnitude * day_factor
    elif 0 <= days_to <= 1:
        # Execution day: massive volume, directional bias unclear
        regime = "execution"
        direction = "NEUTRAL"
        confidence = 0.3
    elif -2 <= days_to < 0:
        # Post-rebalance: relief
        regime = "post_rebal"
        direction = "BULLISH"
        confidence = 0.25 * magnitude
    else:
        regime = "distant"
        direction = "NEUTRAL"
        confidence = 0.15

# Cap confidence
confidence = min(confidence, 0.55)

output = {
    "date": f"{today}",
    "force_code": "F6",
    "force_name": "Index Rebalancing",
    "direction": direction,
    "confidence": round(confidence, 3),
    "source_tag": f"rebal:{today.strftime('%Y%m%d')}",
    "details": {
        "upcoming_rebalances_count": len(upcoming),
        "upcoming": upcoming[:5],
        "next_rebalance": next_rebal,
        "regime": regime,
        "note": "Russell June rebalance is highest magnitude (~5x S&P quarterly)"
    }
}

with open(os.environ['OUTPUT_FILE'], 'w') as f:
    json.dump(output, f, indent=2)

rb_info = f"{next_rebal['index']} {next_rebal['type']}" if next_rebal else "none"
print(f"F6: {direction} (conf={confidence:.2f}), regime={regime}, next={rb_info}")
PYEOF

esad_log "F6: Output saved to ${OUTPUT_FILE}"
