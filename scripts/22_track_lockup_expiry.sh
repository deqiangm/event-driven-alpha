#!/usr/bin/env bash
# 22_track_lockup_expiry.sh — F7: Lockup Expiration Force
# Phase 3: P3.6 — SEC S-1 parsing + lockup expiry tracking
#
# Lockup Expiry Effect:
#   - T-14 to T-0: Anticipatory selling pressure (BEARISH)
#   - T+0 to T+3: Relief rally if selling was front-run (BULLISH)
#   - Magnitude: Small cap > Mid cap > Large cap
#   - Insider ownership % = bigger effect
#
# Output Format (JSON):
# {
#   "date": "YYYY-MM-DD",
#   "force_code": "F7",
#   "force_name": "Lockup Expiry",
#   "direction": "BULLISH|BEARISH|NEUTRAL",
#   "confidence": 0.0-1.0,
#   "source_tag": "lockup:YYYYMMDD",
#   "details": {
#     "upcoming_expiries_count": int,
#     "avg_days_to_expiry": float,
#     "total_market_cap_exposure": float,
#     "expiry_regime": "anticipatory|relief_rally|none"
#   }
# }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/esad_common.sh"

export OUTPUT_FILE="${CACHE_DIR}/lockup_expiration_${TODAY}.json"

esad_log "F7: Tracking lockup expiry force (IPO calendar proxy)"

python3 << 'PYEOF'
import json
import os
import os
from datetime import date, timedelta

today = date.today()
cache_dir = os.environ.get('CACHE_DIR', '')

# ── Step 1: Get recent IPOs from cache (P3.6 proxy) ──────────────────
# Lockup expiry is typically 90-180 days after IPO
# We use the IPO calendar data to estimate upcoming expirations

ipo_cache = os.path.join(cache_dir, "ipo_calendar.json")
upcoming_expiries = []

if os.path.exists(ipo_cache):
    try:
        with open(ipo_cache) as f:
            ipo_data = json.load(f)
        # Look for IPOs in the last 6 months that have upcoming lockup
        # Standard lockup = 180 days after IPO
        ipos = ipo_data.get('ipos', []) if isinstance(ipo_data, dict) else []
        
        for ipo in ipos:
            ipo_date_str = ipo.get('date', '')
            if not ipo_date_str:
                continue
            try:
                from datetime import datetime
                ipo_date = datetime.strptime(ipo_date_str, '%Y-%m-%d').date()
                lockup_expiry = ipo_date + timedelta(days=180)  # Standard 6-month lockup
                days_to_expiry = (lockup_expiry - today).days
                if -10 <= days_to_expiry <= 30:
                    upcoming_expiries.append({
                        'symbol': ipo.get('symbol', 'UNKNOWN'),
                        'ipo_date': ipo_date_str,
                        'lockup_expiry': f"{lockup_expiry}",
                        'days_to_expiry': days_to_expiry,
                        'estimated_float_pct': ipo.get('float_pct', 25)
                    })
            except:
                pass
    except:
        pass

# ── Step 2: If no cache data, use seasonal proxy ─────────────────────
# IPO lockups tend to cluster 6 months after IPO waves (Jan/Feb IPOs → Jul/Aug expiries)
if not upcoming_expiries:
    # Proxy: count months that typically see lockup expiries
    month = today.month
    # IPO waves: Jan-Mar → Jul-Sep expiries; Apr-Jun → Oct-Dec expiries
    lockup_season = (
        (month in [7, 8, 9]) or    # Q1 IPO lockups
        (month in [10, 11, 12]) or  # Q2 IPO lockups
        (month in [1, 2])           # Q3/Q4 IPO delayed lockups
    )
    
    if lockup_season:
        upcoming_expiries = [{'symbol': 'PROXY', 'days_to_expiry': 15}]

# ── Step 3: Compute aggregate force ──────────────────────────────────
if not upcoming_expiries:
    direction = "NEUTRAL"
    confidence = 0.1
    expiry_regime = "none"
else:
    avg_days = sum(e['days_to_expiry'] for e in upcoming_expiries) / len(upcoming_expiries)
    count = len(upcoming_expiries)
    
    # Determine regime
    anticipatory_count = sum(1 for e in upcoming_expiries if 0 <= e['days_to_expiry'] <= 14)
    relief_count = sum(1 for e in upcoming_expiries if -3 <= e['days_to_expiry'] < 0)
    
    if anticipatory_count > 0:
        direction = "BEARISH"  # Anticipatory selling
        expiry_regime = "anticipatory"
        base_conf = 0.4
        day_factor = 1.0 if avg_days <= 7 else 0.8 if avg_days <= 14 else 0.5
        confidence = base_conf * (1 + (count - 1) * 0.1) * day_factor
    elif relief_count > 0:
        direction = "BULLISH"  # Relief rally
        expiry_regime = "relief_rally"
        base_conf = 0.35
        confidence = base_conf * (1 + (relief_count - 1) * 0.15)
    else:
        direction = "NEUTRAL"
        confidence = 0.2
        expiry_regime = "distant"

# Cap confidence
confidence = min(confidence, 0.55)

output = {
    "date": f"{today}",
    "force_code": "F7",
    "force_name": "Lockup Expiry",
    "direction": direction,
    "confidence": round(confidence, 3),
    "source_tag": f"lockup:{today.strftime('%Y%m%d')}",
    "details": {
        "upcoming_expiries_count": len(upcoming_expiries),
        "expiries_in_window": [e for e in upcoming_expiries if -10 <= e.get('days_to_expiry', 999) <= 30],
        "expiry_regime": expiry_regime,
        "note": "Full SEC S-1 parsing required for precise lockup dates; current is proxy"
    }
}

with open(os.environ['OUTPUT_FILE'], 'w') as f:
    json.dump(output, f, indent=2)

print(f"F7: {direction} (conf={confidence:.2f}), regime={expiry_regime}, {len(upcoming_expiries)} upcoming expiries")
PYEOF

esad_log "F7: Output saved to ${OUTPUT_FILE}"
