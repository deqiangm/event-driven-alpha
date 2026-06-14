#!/usr/bin/env bash
# 08_fetch_gamma_dealer_force.sh — F2: Gamma Dealer Positioning Force
# Phase 2: Integrates GEX pipeline into structural forces with enhancements
#
# Enhancements:
# - P2.4: Negative gamma acceleration detection (rate of change)
# - P2.5: Key gamma strike identification (max gamma levels)
# - P2.7: GEX map data for daily report
#
# Output Format (JSON):
# {
#   "date": "YYYY-MM-DD",
#   "force_code": "F2",
#   "force_name": "Gamma Dealer Positioning",
#   "direction": "BULLISH|BEARISH|NEUTRAL",
#   "confidence": 0.0-1.0,
#   "source_tag": "gex:SPY:YYYYMMDD",
#   "details": {
#     "spot": float,
#     "net_gex_billion": float,
#     "zero_gamma": float,
#     "distance_to_zg_pct": float,
#     "gex_regime": "negative_gamma|positive_gamma|near_zero_gamma",
#     "n_contracts": int,
#     "gamma_acceleration": float,       # P2.4: % change from previous
#     "acceleration_direction": "bullish|bearish|neutral",
#     "key_strikes": {                   # P2.5: Key gamma levels
#       "max_call_gamma": float,
#       "max_put_gamma": float,
#       "largest_abs_gamma": float,
#       "pinning_candidates": [float]
#     },
#     "gex_map": {                       # P2.7: Data for report visualization
#       "strikes_near_spot": [strike, net_gamma],
#       "call_put_ratio": float
#     }
#   }
# }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/esad_common.sh"

# ── Configuration ──────────────────────────────────────────────────────────
SYMBOL="${1:-SPY}"
GEX_CACHE_DIR="${DATA_DIR}/cache/gex"
OUTPUT_FILE="${CACHE_DIR}/gamma_dealer_${TODAY}.json"
HISTORY_DIR="${DATA_DIR}/gex_history"

mkdir -p "$GEX_CACHE_DIR" "$CACHE_DIR" "$HISTORY_DIR"

# ── Step 1: Fetch/Retrieve GEX Data ─────────────────────────────────────────
esad_log "F2: Fetching GEX data for ${SYMBOL}"

GEX_FILE=$("${SCRIPT_DIR}/gex_cache.sh" fetch -s "$SYMBOL" 2>/dev/null)

if [[ ! -f "$GEX_FILE" ]]; then
    esad_log "ERROR: Failed to fetch GEX data for ${SYMBOL}"
    # Fallback to neutral signal
    python3 << PYEOF
import json
output = {
    "date": "$TODAY",
    "force_code": "F2",
    "force_name": "Gamma Dealer Positioning",
    "direction": "NEUTRAL",
    "confidence": 0.3,
    "source_tag": "gex:${SYMBOL}:${TODAY_COMPACT}",
    "error": "GEX data unavailable",
    "details": {}
}
with open('$OUTPUT_FILE', 'w') as f:
    json.dump(output, f, indent=2)
PYEOF
    exit 0
fi

# Save for history tracking
cp "$GEX_FILE" "${HISTORY_DIR}/gex_${SYMBOL}_${TODAY_COMPACT}.json" 2>/dev/null || true

# ── Step 2: Compute Force Signal with Phase 2 Enhancements ─────────────────
esad_log "F2: Computing enhanced gamma dealer force (P2.4 + P2.5 + P2.7)"

python3 << PYEOF
import json
import os
import glob

# Load current GEX data
with open('$GEX_FILE') as f:
    gex = json.load(f)

spot = gex['spot']
net_gex = gex['net_gex_billions']
call_gex = gex['call_gex_billions']
put_gex = gex['put_gex_billions']
zero_gamma = gex['zero_gamma']
n_contracts = gex.get('n_contracts', 0)
gex_by_strike = gex.get('gex_by_strike', {})

# Calculate distance to zero gamma (as % of spot)
distance_to_zg = abs(spot - zero_gamma) / spot * 100

# Determine GEX regime
if net_gex < -5:
    gex_regime = "negative_gamma"
    if distance_to_zg < 0.5:
        direction = "BULLISH"
        confidence = 0.75
    else:
        direction = "BEARISH"
        confidence = 0.65
elif net_gex > 5:
    gex_regime = "positive_gamma"
    direction = "BULLISH"
    confidence = 0.55
else:
    gex_regime = "near_zero_gamma"
    direction = "BULLISH"
    confidence = 0.5

# ── P2.4: Gamma Acceleration Detection ─────────────────────────────
# Find previous day's GEX data for comparison
gamma_acceleration = 0.0
accel_direction = "neutral"

history_files = sorted(glob.glob('${HISTORY_DIR}/gex_${SYMBOL}_*.json'), reverse=True)
if len(history_files) >= 2:
    try:
        with open(history_files[1]) as f:  # Previous day (0 is today)
            prev_gex = json.load(f)
        prev_net_gex = prev_gex['net_gex_billions']
        if prev_net_gex != 0:
            gamma_acceleration = (net_gex - prev_net_gex) / abs(prev_net_gex) * 100
            # Accelerating negative gamma = more bearish (more amplification)
            # Accelerating positive gamma = more bullish (more pinning)
            if gamma_acceleration > 10:  # Moving toward positive gamma
                accel_direction = "bullish"
                confidence += 0.05
            elif gamma_acceleration < -10:  # Moving toward negative gamma
                accel_direction = "bearish"
                confidence += 0.05
    except:
        pass

# ── P2.5: Key Gamma Strike Identification ──────────────────────────
strike_gamma_list = [(float(k), float(v)) for k, v in gex_by_strike.items()]
strike_gamma_list.sort(key=lambda x: x[0])

key_strikes = {}
if strike_gamma_list:
    # Max positive gamma (call dominated)
    max_pos = max(strike_gamma_list, key=lambda x: x[1])
    key_strikes["max_call_gamma"] = max_pos[0]
    
    # Max negative gamma (put dominated)
    max_neg = min(strike_gamma_list, key=lambda x: x[1])
    key_strikes["max_put_gamma"] = max_neg[0]
    
    # Largest absolute gamma (strongest pinning candidate)
    largest_abs = max(strike_gamma_list, key=lambda x: abs(x[1]))
    key_strikes["largest_abs_gamma"] = largest_abs[0]
    
    # Pinning candidates: strikes near spot with high gamma
    pinning_candidates = []
    for strike, g in strike_gamma_list:
        if abs(strike - spot) / spot < 0.02 and abs(g) > 0.001:
            pinning_candidates.append(strike)
    key_strikes["pinning_candidates"] = pinning_candidates[:5]

# ── P2.7: GEX Map Data for Report ──────────────────────────────────
gex_map = {}
if strike_gamma_list:
    # Strikes near spot for report visualization
    near_spot = [(s, g) for s, g in strike_gamma_list if abs(s - spot) / spot < 0.1]
    gex_map["strikes_near_spot"] = near_spot[:20]
    gex_map["call_put_ratio"] = abs(call_gex / put_gex) if put_gex != 0 else 1.0

# Adjust confidence based on data quality
if n_contracts < 50:
    confidence *= 0.7

# Cap confidence
confidence = min(confidence, 0.95)

# Build output
output = {
    "date": "$TODAY",
    "force_code": "F2",
    "force_name": "Gamma Dealer Positioning",
    "direction": direction,
    "confidence": round(confidence, 3),
    "source_tag": "gex:${SYMBOL}:${TODAY_COMPACT}",
    "details": {
        "spot": round(spot, 2),
        "net_gex_billion": round(net_gex, 4),
        "zero_gamma": round(zero_gamma, 2),
        "distance_to_zg_pct": round(distance_to_zg, 3),
        "gex_regime": gex_regime,
        "n_contracts": n_contracts,
        "gamma_acceleration_pct": round(gamma_acceleration, 2),
        "acceleration_direction": accel_direction,
        "key_strikes": key_strikes,
        "gex_map": gex_map
    },
    "regime_interpretation": {
        "negative_gamma": "Dealer short gamma → volatility amplification, moves exaggerated",
        "positive_gamma": "Dealer long gamma → range-bound pinning, moves stabilized",
        "near_zero_gamma": "Gamma inflection point → expect increased volatility soon"
    }[gex_regime],
    "enhancements": {
        "P2.4_gamma_acceleration": "implemented",
        "P2.5_key_strike_id": "implemented",
        "P2.7_gex_map": "implemented"
    }
}

with open('$OUTPUT_FILE', 'w') as f:
    json.dump(output, f, indent=2)

print(f"F2: {direction} (conf={confidence:.2f}), regime={gex_regime}, net_gex={net_gex:.2f}B")
print(f"    P2.4: Acceleration={gamma_acceleration:.1f}% ({accel_direction})")
print(f"    P2.5: Key strike={key_strikes.get('largest_abs_gamma', 'N/A')}, candidates={len(key_strikes.get('pinning_candidates', []))}")
PYEOF

esad_log "F2: Enhanced output saved to ${OUTPUT_FILE}"
