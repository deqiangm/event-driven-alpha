#!/usr/bin/env bash
# 08_fetch_gamma_dealer_force.sh — F2: Gamma Dealer Positioning Force
# Phase 2: Integrates GEX pipeline into structural forces
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
#     "n_contracts": int
#   }
# }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/esad_common.sh"

# ── Configuration ──────────────────────────────────────────────────────────
SYMBOL="${1:-SPY}"
GEX_CACHE_DIR="${DATA_DIR}/cache/gex"
OUTPUT_FILE="${CACHE_DIR}/gamma_dealer_${TODAY}.json"

mkdir -p "$GEX_CACHE_DIR" "$CACHE_DIR"

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

# ── Step 2: Compute Force Signal ────────────────────────────────────────────
esad_log "F2: Computing gamma dealer force"

python3 << PYEOF
import json

# Load GEX data
with open('$GEX_FILE') as f:
    gex = json.load(f)

spot = gex['spot']
net_gex = gex['net_gex_billions']
zero_gamma = gex['zero_gamma']
n_contracts = gex.get('n_contracts', 0)

# Calculate distance to zero gamma (as % of spot)
distance_to_zg = abs(spot - zero_gamma) / spot * 100

# Determine GEX regime
# Negative gamma = dealer short gamma → amplify moves (volatile)
# Positive gamma = dealer long gamma → pinning behavior (range-bound)
if net_gex < -5:
    gex_regime = "negative_gamma"
    # Strong negative gamma: dealer needs to sell into down moves, buy into up moves
    # If near zero gamma, expect large move soon
    if distance_to_zg < 0.5:
        direction = "BULLISH"  # Near ZG with negative gamma = expect breakout
        confidence = 0.75
    else:
        direction = "BEARISH"  # Negative gamma away from ZG = volatility amplification
        confidence = 0.65
elif net_gex > 5:
    gex_regime = "positive_gamma"
    # Positive gamma: dealer sells into rallies, buys into dips → pinning
    direction = "BULLISH"  # Range-bound usually slightly bullish
    confidence = 0.55
else:
    gex_regime = "near_zero_gamma"
    # Near zero gamma: inflection point, expect increased volatility soon
    direction = "BULLISH"  # Inflection often precedes breakout
    confidence = 0.5

# Adjust confidence based on data quality
if n_contracts < 50:
    confidence *= 0.7  # Lower confidence for low data volume

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
        "n_contracts": n_contracts
    },
    "regime_interpretation": {
        "negative_gamma": "Dealer short gamma → volatility amplification, moves exaggerated",
        "positive_gamma": "Dealer long gamma → range-bound pinning, moves stabilized",
        "near_zero_gamma": "Gamma inflection point → expect increased volatility soon"
    }[gex_regime]
}

with open('$OUTPUT_FILE', 'w') as f:
    json.dump(output, f, indent=2)

print(f"F2: {direction} (conf={confidence:.2f}), regime={gex_regime}, net_gex={net_gex:.2f}B")
PYEOF

esad_log "F2: Output saved to ${OUTPUT_FILE}"
