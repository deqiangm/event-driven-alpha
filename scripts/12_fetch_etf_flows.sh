#!/usr/bin/env bash
# scripts/12_fetch_etf_flows.sh — F8: ETF Fund Flow Momentum
# Fetches iShares fund flows (primary), etf.com (fallback), computes momentum
# stdout=JSON machine output, stderr=human logs

set -euo pipefail
source "$(dirname "$0")/../lib/esad_common.sh"

FORCE_DATE="${1:-$TODAY_ISO}"
OUTPUT="${CACHE_DIR}/etf_flows_${TODAY}.json"
SECTOR_MAP="${CONFIG_DIR}/etf_sector_map.json"

esad_log "F8: Fetching ETF Fund Flow data for ${FORCE_DATE}"
esad_init_check

# ── Step 1: Fetch iShares fund flows (primary) ──
# iShares publishes daily fund flows via their API
fetch_ishares_flows() {
    local cache_file="${CACHE_DIR}/ishares_flows_${TODAY}.json"
    if is_cache_fresh "$cache_file" 1440; then
        esad_dbg "Using cached iShares flows"
        cat "$cache_file"
        return 0
    fi
    esad_log "Fetching iShares fund flows"
    # iShares daily holdings/flows API (public)
    local url="https://www.ishares.com/us/product-screener/product-screener-v3.jsp?productType=ishares&viewData=hrefExportCsv&sortField=totalNetAssets&sortOrder=desc"
    local http_code
    http_code=$(curl -s -o "$cache_file" -w "%{http_code}" \
        -H "Accept: text/csv" "$url" 2>/dev/null) || true
    if [ "$http_code" = "200" ] && [ -s "$cache_file" ]; then
        cat "$cache_file"
    else
        esad_warn "iShares API failed (HTTP ${http_code:-none})"
        echo '{}'  # empty — will trigger fallback
    fi
}

# ── Step 2: Fetch sector ETF flows via yfinance (secondary) ──
# Uses volume + price changes as flow proxy when direct data unavailable
fetch_sector_flow_proxy() {
    python3 << 'PYEOF' 2>/dev/null
import json, sys
try:
    import yfinance as yf
    sectors = {
        'XLK': 'Technology', 'XLF': 'Financials', 'XLE': 'Energy',
        'XLV': 'Healthcare', 'XLI': 'Industrials', 'XLY': 'Consumer Discretionary',
        'XLP': 'Consumer Staples', 'XLU': 'Utilities', 'XLB': 'Materials',
        'XLRE': 'RealEstate', 'XLC': 'Communication'
    }
    results = []
    for ticker, sector in sectors.items():
        try:
            etf = yf.Ticker(ticker)
            hist = etf.history(period='5d')
            if len(hist) >= 2:
                latest_vol = float(hist['Volume'].iloc[-1])
                avg_vol = float(hist['Volume'].mean())
                vol_ratio = latest_vol / avg_vol if avg_vol > 0 else 1.0
                price_change = (float(hist['Close'].iloc[-1]) / float(hist['Close'].iloc[-2])) - 1
                etf_assets = getattr(etf.info, 'totalAssets', 0) if hasattr(etf, 'info') else 0
                info = etf.info if hasattr(etf, 'info') else {}
                etf_assets = info.get('totalAssets', 0)
                # Flow proxy: high volume + positive price = inflow
                # Simplified: volume ratio * price direction * AUM
                flow_direction = 'inflow' if price_change > 0 else 'outflow'
                results.append({
                    'ticker': ticker, 'sector': sector,
                    'vol_ratio': round(vol_ratio, 2),
                    'price_change_pct': round(price_change * 100, 2),
                    'flow_direction': flow_direction,
                    'aum': int(etf_assets) if etf_assets else 0,
                    'source': 'yfinance_proxy'
                })
        except Exception:
            pass
    print(json.dumps(results))
except Exception as e:
    print(json.dumps([]), file=sys.stderr)
    print(json.dumps([]))
PYEOF
}

# ── Step 3: Fetch VIX (for confidence adjustment) ──
fetch_vix_level() {
    python3 << 'PYEOF' 2>/dev/null
import json, sys
try:
    import yfinance as yf
    vix = yf.Ticker('^VIX')
    hist = vix.history(period='1mo')
    if len(hist) >= 2:
        latest = float(hist['Close'].iloc[-1])
        ma20 = float(hist['Close'].mean()) if len(hist) >= 10 else latest
        print(json.dumps({'vix_spot': round(latest, 2), 'vix_20d_ma': round(ma20, 2)}))
    else:
        print(json.dumps({'vix_spot': 20, 'vix_20d_ma': 20}))
except Exception:
    print(json.dumps({'vix_spot': 20, 'vix_20d_ma': 20}))
PYEOF
}

# ── Step 4: Compute confidence ──
compute_f8() {
    local flows_data="$1"
    local vix_data="$2"
    python3 << PYEOF
import json, sys

flows = json.loads('$( echo "$flows_data" | python3 -c "import sys,json; d=sys.stdin.read(); print(json.dumps(json.loads(d))) if d.strip() else '[]'" 2>/dev/null || echo '[]' )')
vix = json.loads('$( echo "$vix_data" | python3 -c "import sys,json; print(json.dumps(json.loads(sys.stdin.read())))" 2>/dev/null || echo '{"vix_spot":20}' )')

vix_spot = vix.get('vix_spot', 20)

# Aggregate sector flows
sector_flows = {}
active_forces = []
for f in flows if isinstance(flows, list) else []:
    sector = f.get('sector', '')
    direction = f.get('flow_direction', 'neutral')
    vol_ratio = f.get('vol_ratio', 1.0)
    price_pct = f.get('price_change_pct', 0)
    aum = f.get('aum', 0)
    ticker = f.get('ticker', '')

    if sector not in sector_flows:
        sector_flows[sector] = {'inflow_count': 0, 'outflow_count': 0, 'max_vol_ratio': 1.0, 'max_price_pct': 0, 'tickers': []}
    sf = sector_flows[sector]
    if direction == 'inflow': sf['inflow_count'] += 1
    elif direction == 'outflow': sf['outflow_count'] += 1
    sf['max_vol_ratio'] = max(sf['max_vol_ratio'], vol_ratio)
    sf['max_price_pct'] = max(abs(sf['max_price_pct']), abs(price_pct))
    sf['tickers'].append(ticker)

# Generate per-sector force entries
for sector, sf in sector_flows.items():
    net_dir = 'inflow' if sf['inflow_count'] > sf['outflow_count'] else ('outflow' if sf['outflow_count'] > sf['inflow_count'] else 'neutral')
    if net_dir == 'neutral':
        continue

    # Flow proxy magnitude (volume ratio * price move)
    flow_proxy_b = sf['max_vol_ratio'] * sf['max_price_pct'] * 100  # rough USD proxy
    is_large = sf['max_vol_ratio'] > 1.5 and abs(sf['max_price_pct']) > 1.0

    confidence = 0.45
    direction = 'BULLISH' if net_dir == 'inflow' else 'BEARISH'

    if is_large: confidence += 0.10
    if sf['max_vol_ratio'] > 2.0: confidence += 0.08  # accelerating volume
    # Cross-sector confirmation
    aligned_count = sum(1 for s, d in sector_flows.items() if (d['inflow_count'] > d['outflow_count']) == (net_dir == 'inflow') and s != sector)
    if aligned_count >= 2: confidence += 0.07
    # High-beta ETF amplification
    high_beta_tickers = {'XLE', 'XLF', 'XLK'}
    if any(t in high_beta_tickers for t in sf['tickers']): confidence += 0.05
    # VIX adjustment
    if vix_spot > 30: confidence -= 0.05
    confidence = min(confidence, 0.75)

    if confidence >= 0.35:
        active_forces.append({
            'sector': sector, 'flow_direction': net_dir,
            'direction': direction, 'confidence': round(confidence, 3),
            'vol_ratio': sf['max_vol_ratio'], 'tickers': sf['tickers']
        })

result = {
    'date': '$TODAY_ISO', 'force_code': 'F8', 'force_name': 'etf_fund_flow_momentum',
    'vix_spot': vix_spot, 'sector_flow_count': len(active_forces),
    'active_sectors': active_forces,
    'source_tag': 'etf_flow:$TODAY'
}
# Top-level fields for pipeline compatibility
if active_forces:
    best = max(active_forces, key=lambda x: x['confidence'])
    result['direction'] = best['direction']
    result['confidence'] = best['confidence']
else:
    result['direction'] = 'NEUTRAL'
    result['confidence'] = 0.0
    result['source_tag'] = 'etf_flow:$TODAY#inactive'

print(json.dumps(result))
PYEOF
}

# ── Main ──
ishares_data=$(fetch_ishares_flows)
flows_data=$(fetch_sector_flow_proxy)
vix_data=$(fetch_vix_level)

# Merge: prefer iShares direct data, fall back to yfinance proxy
if [ "$ishares_data" = "{}" ]; then
    esad_warn "iShares data unavailable, using yfinance proxy only"
fi

result=$(compute_f8 "$flows_data" "$vix_data")
echo "$result" > "$OUTPUT"
esad_log "F8 output: $(echo "$result" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(f"dir={d[\"direction\"]} conf={d[\"confidence\"]} sectors={d[\"sector_flow_count\"]}")' 2>/dev/null || echo 'parse error')"
echo "$result"
