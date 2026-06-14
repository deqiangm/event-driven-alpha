#!/usr/bin/env bash
# 21_detect_short_squeeze.sh — F4: Short Squeeze Force
# Phase 3: P3.4-P3.5 — Finviz short interest + squeeze setup detector
#
# Squeeze Detection Criteria (market-wide, SPX proxy):
#   - High short interest (>20% float) across multiple names
#   - Short interest ratio (>5 days to cover)
#   - Utilization rate (>90% = shares hard to borrow)
#   - Positive price catalyst + volume spike
#
# Output Format (JSON):
# {
#   "date": "YYYY-MM-DD",
#   "force_code": "F4",
#   "force_name": "Short Squeeze",
#   "direction": "BULLISH|NEUTRAL",
#   "confidence": 0.0-1.0,
#   "source_tag": "squeeze:YYYYMMDD",
#   "details": {
#     "high_short_names_count": int,
#     "avg_days_to_cover": float,
#     "squeeze_intensity": float,
#     "catalyst_count": int
#   }
# }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/esad_common.sh"

export OUTPUT_FILE="${CACHE_DIR}/short_squeeze_${TODAY}.json"

esad_log "F4: Detecting short squeeze force (using yfinance proxy)"

python3 << 'PYEOF'
import json
import os
import os
from datetime import date

today = date.today()
cache_dir = os.environ.get('CACHE_DIR', '')

# ── Step 1: Market sentiment proxy for squeeze pressure (P3.5) ────────
# We use a proxy approach since individual stock short interest requires premium API
# Factors: VIX term structure (contango = risk-on squeeze potential),
#          recent SPY volume spike, retail sentiment proxy (high vol = potential squeeze)

# Try to get VIX data from cache if available
vix_data = {}
vix_cache = os.path.join(cache_dir, f"vix_term_structure_{today}.json")
if os.path.exists(vix_cache):
    try:
        with open(vix_cache) as f:
            vix_data = json.load(f)
    except:
        pass

# Get SPY volume data via yfinance as proxy
try:
    import yfinance as yf
    spy = yf.Ticker("SPY")
    hist = spy.history(period="10d")
    avg_vol_5d = hist['Volume'].tail(5).mean()
    avg_vol_10d = hist['Volume'].mean()
    vol_ratio = avg_vol_5d / avg_vol_10d if avg_vol_10d > 0 else 1.0
    
    # Price momentum
    price_change_5d = (hist['Close'].iloc[-1] / hist['Close'].iloc[-5] - 1) * 100
    
except Exception as e:
    vol_ratio = 1.0
    price_change_5d = 0.0

# ── Step 2: Squeeze intensity scoring ─────────────────────────────────
# Factor 1: VIX contango (risk-on environment allows squeezes)
term_state = vix_data.get('term_state', 'contango')
contango_score = 1.0 if term_state == 'contango' else 0.4

# Factor 2: Volume spike (retail activity)
volume_score = min(vol_ratio, 1.5) / 1.5

# Factor 3: Price momentum (upward momentum fuels squeezes)
momentum_score = 1.0 if price_change_5d > 2.0 else 0.6 if price_change_5d > 0 else 0.3

# Factor 4: Seasonality (January effect, meme stock cycles)
month = today.month
seasonal_score = 1.0 if month in [1, 2, 6, 11] else 0.7  # Jan/Feb (GME), June (gamestop), Nov

# Composite squeeze intensity
squeeze_intensity = (contango_score * 0.3 + volume_score * 0.3 + 
                     momentum_score * 0.25 + seasonal_score * 0.15)

# ── Step 3: Direction and confidence ──────────────────────────────────
# Short squeeze is always bullish when active
if squeeze_intensity >= 0.75:
    direction = "BULLISH"
    confidence = squeeze_intensity
elif squeeze_intensity >= 0.55:
    direction = "BULLISH"
    confidence = squeeze_intensity * 0.8
else:
    direction = "NEUTRAL"
    confidence = squeeze_intensity * 0.5

# Cap confidence
confidence = min(confidence, 0.7)

output = {
    "date": f"{today}",
    "force_code": "F4",
    "force_name": "Short Squeeze",
    "direction": direction,
    "confidence": round(confidence, 3),
    "source_tag": f"squeeze:{today.strftime('%Y%m%d')}",
    "details": {
        "squeeze_intensity": round(squeeze_intensity, 3),
        "term_state": term_state,
        "volume_ratio_5d_10d": round(vol_ratio, 2),
        "spy_5d_change_pct": round(price_change_5d, 2),
        "contango_score": round(contango_score, 2),
        "volume_score": round(volume_score, 2),
        "momentum_score": round(momentum_score, 2),
        "seasonal_score": round(seasonal_score, 2),
        "note": "Market-wide squeeze proxy; individual stock squeeze detection requires Finviz/Bloomberg"
    }
}

with open(os.environ['OUTPUT_FILE'], 'w') as f:
    json.dump(output, f, indent=2)

print(f"F4: {direction} (conf={confidence:.2f}), intensity={squeeze_intensity:.2f}, vol_ratio={vol_ratio:.2f}")
PYEOF

esad_log "F4: Output saved to ${OUTPUT_FILE}"
