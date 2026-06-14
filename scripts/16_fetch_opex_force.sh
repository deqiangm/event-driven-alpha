#!/usr/bin/env bash
# 16_fetch_opex_force.sh — F2b: OpEx (Options Expiration) Force
# Phase 2: P2.6 OpEx signal generation
#
# OpEx Regimes:
# - 0-2 days before OpEx: Pinning pressure strong → range-bound
# - OpEx day +1 day: Gamma flip → volatility explosion
# - Quarterly OpEx: Stronger effect
# - Zero gamma near OpEx = amplified effect
#
# Output Format (JSON):
# {
#   "date": "YYYY-MM-DD",
#   "force_code": "F2b",
#   "force_name": "OpEx Gamma Flip",
#   "direction": "BULLISH|BEARISH|NEUTRAL",
#   "confidence": 0.0-1.0,
#   "source_tag": "opex:YYYYMMDD",
#   "details": {
#     "next_opex_date": "YYYY-MM-DD",
#     "days_until_opex": int,
#     "opex_type": "weekly|monthly|quarterly",
#     "opex_regime": "pre_pin|gamma_flip|post_opex",
#     "pinning_strength": float,
#     "volatility_explosion_prob": float
#   }
# }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/esad_common.sh"

OUTPUT_FILE="${CACHE_DIR}/opex_force_${TODAY}.json"

# ── Step 1: Get OpEx dates ─────────────────────────────────────────────────
esad_log "F2b: Computing OpEx force signal"

# Ensure OpEx dates exist
"${SCRIPT_DIR}/05_fetch_opex_dates.sh" 2>/dev/null || true

OPEX_FILE="${CACHE_DIR}/opex_dates.json"

if [[ ! -f "$OPEX_FILE" ]]; then
    esad_log "ERROR: OpEx dates unavailable"
    python3 << PYEOF
import json
output = {
    "date": "$TODAY",
    "force_code": "F2b",
    "force_name": "OpEx Gamma Flip",
    "direction": "NEUTRAL",
    "confidence": 0.3,
    "source_tag": "opex:${TODAY_COMPACT}",
    "error": "OpEx dates unavailable",
    "details": {}
}
with open('$OUTPUT_FILE', 'w') as f:
    json.dump(output, f, indent=2)
PYEOF
    exit 0
fi

# ── Step 2: Compute OpEx force ────────────────────────────────────────────
python3 << PYEOF
import json
from datetime import date

today = date.today()

# Load OpEx dates
with open('$OPEX_FILE') as f:
    opex_data = json.load(f)

events = opex_data.get('events', [])

# Find next upcoming OpEx
next_opex = None
for event in sorted(events, key=lambda x: x['event_date']):
    e_date = date.fromisoformat(event['event_date'])
    if e_date >= today:
        next_opex = event
        break

if not next_opex:
    # No OpEx found in next 90 days, neutral signal
    output = {
        "date": "$TODAY",
        "force_code": "F2b",
        "force_name": "OpEx Gamma Flip",
        "direction": "NEUTRAL",
        "confidence": 0.3,
        "source_tag": "opex:${TODAY_COMPACT}",
        "details": {"note": "No upcoming OpEx in next 90 days"}
    }
    with open('$OUTPUT_FILE', 'w') as f:
        json.dump(output, f, indent=2)
    print("F2b: NEUTRAL (no upcoming OpEx)")
    exit()

# Parse OpEx data
next_opex_date = date.fromisoformat(next_opex['event_date'])
days_until = (next_opex_date - today).days
raw_opex_type = next_opex['event_type']
if 'quarterly' in raw_opex_type:
    opex_type = 'quarterly'
elif 'monthly' in raw_opex_type:
    opex_type = 'monthly'
else:
    opex_type = 'weekly'

# Determine OpEx regime and signal
if days_until <= 1:
    # OpEx day or day before: Gamma flip imminent, volatility explosion
    opex_regime = "gamma_flip"
    direction = "BULLISH"  # Gamma flip often leads to short squeeze / rally
    
    # Confidence: quarterly > monthly > weekly
    type_multipliers = {"quarterly": 1.0, "monthly": 0.85, "weekly": 0.6}
    base_conf = 0.65 * type_multipliers.get(opex_type, 0.6)
    
    # Days adjustment: 0 days (today) = highest confidence
    if days_until == 0:
        confidence = base_conf * 1.1
    else:
        confidence = base_conf
    
    pinning_strength = 0.8 if days_until == 0 else 0.6
    vol_explosion_prob = 0.85 if opex_type == "quarterly" else 0.7

elif days_until <= 3:
    # 2-3 days before: Strong pinning pressure
    opex_regime = "pre_pin"
    direction = "NEUTRAL"  # Range-bound
    confidence = 0.45
    pinning_strength = 0.9
    vol_explosion_prob = 0.3

else:
    # Too far out, minimal effect
    opex_regime = "post_opex"
    direction = "NEUTRAL"
    confidence = 0.25
    pinning_strength = 0.2
    vol_explosion_prob = 0.1

# Cap confidence
confidence = min(confidence, 0.85)

output = {
    "date": "$TODAY",
    "force_code": "F2b",
    "force_name": "OpEx Gamma Flip",
    "direction": direction,
    "confidence": round(confidence, 3),
    "source_tag": "opex:${TODAY_COMPACT}",
    "details": {
        "next_opex_date": next_opex['event_date'],
        "days_until_opex": days_until,
        "opex_type": opex_type,
        "opex_regime": opex_regime,
        "pinning_strength": round(pinning_strength, 2),
        "volatility_explosion_prob": round(vol_explosion_prob, 2),
        "magnitude": next_opex.get('magnitude', 0)
    },
    "regime_interpretation": {
        "gamma_flip": "OpEx imminent → gamma flip expected, watch for volatility explosion",
        "pre_pin": "Pre-OpEx pinning window → range-bound price action expected",
        "post_opex": "No immediate OpEx effect"
    }[opex_regime]
}

with open('$OUTPUT_FILE', 'w') as f:
    json.dump(output, f, indent=2)

print(f"F2b: {direction} (conf={confidence:.2f}), {days_until} days to {opex_type} OpEx, regime={opex_regime}")
PYEOF

esad_log "F2b: Output saved to ${OUTPUT_FILE}"
