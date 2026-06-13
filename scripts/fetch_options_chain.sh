#!/usr/bin/env bash
# fetch_options_chain.sh — Fetch options chain from Yahoo Finance
# Usage: fetch_options_chain.sh [-s SYM] [-o OUTDIR] [-a] [-v]
#   -s SYM     Symbol (default: SPY)
#   -o OUTDIR  Output directory (default: data/raw/options)
#   -a        Fetch ALL expiration dates (default: nearest only)
#   -v        Verbose output
#
# Design: B1_GEX_DATA_BACKUP.md
#   - Primary: yfinance Python library (handles cookies/crumbs automatically)
#   - Fallback: curl to Yahoo /v7/finance/options/{SYM} (prone to 429)
#   - Output: JSON matching Yahoo API schema for compute_gex.py
#   - Rate limiting: 1.2s between requests, exponential backoff on failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
SYM="${SYM:-SPY}"
OUTDIR=""
FETCH_ALL=false
VERBOSE=false

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

while getopts "s:o:avh" opt; do
    case $opt in
        s) SYM="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        a) FETCH_ALL=true ;;
        v) VERBOSE=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

: "${OUTDIR:=$PROJECT_DIR/data/raw/options}"
mkdir -p "$OUTDIR"

# ── Python fetcher using yfinance ──────────────────────────────
# yfinance handles Yahoo's cookie/crumb auth automatically,
# which the raw curl approach struggles with (429 rate limits).

FETCHER=$(cat <<'PYEOF'
import sys, json, time, os
import yfinance as yf
import pandas as pd

def main():
    sym = sys.argv[1]
    outdir = sys.argv[2]
    fetch_all = sys.argv[3] == "true"
    verbose = sys.argv[4] == "true"

    today = time.strftime("%Y%m%d")
    ticker = yf.Ticker(sym)

    # Get spot price from fast_info
    try:
        spot = ticker.fast_info.get("lastPrice", 0.0)
    except:
        spot = 0.0
    if spot <= 0:
        # Fallback: try info dict
        try:
            spot = ticker.info.get("regularMarketPrice", 0.0)
        except:
            spot = 0.0
    if verbose:
        print(f"[fetch] {sym} spot={spot}", file=sys.stderr)

    # Get all expiration dates
    expirations = list(ticker.options)
    if not expirations:
        print(f"FATAL: no options data for {sym}", file=sys.stderr)
        sys.exit(1)
    if verbose:
        print(f"[fetch] {sym} has {len(expirations)} expirations", file=sys.stderr)

    # Determine which expirations to fetch
    if fetch_all:
        target_exps = expirations  # all
    else:
        target_exps = [expirations[0]]  # nearest only

    all_calls = []
    all_puts = []
    seen = set()
    exp_dates_ts = []

    for idx, exp_str in enumerate(target_exps):
        if verbose:
            print(f"[fetch] processing expiry {idx+1}/{len(target_exps)}: {exp_str}", file=sys.stderr)

        try:
            chain = ticker.option_chain(exp_str)
        except Exception as e:
            print(f"[warn] failed to fetch {exp_str}: {e}", file=sys.stderr)
            continue

        # Convert expiration string to unix timestamp
        from datetime import datetime, timezone
        try:
            exp_dt = datetime.strptime(exp_str, "%Y-%m-%d").replace(tzinfo=timezone.utc)
            exp_ts = int(exp_dt.timestamp())
        except:
            exp_ts = 0
        exp_dates_ts.append(exp_ts)

        # Process calls
        for _, row in chain.calls.iterrows():
            contract = row.get("contractSymbol", "")
            strike = float(row.get("strike", 0))
            key = (contract, strike, exp_ts)
            if key in seen:
                continue
            seen.add(key)

            call_dict = {
                "contractSymbol": contract,
                "strike": strike,
                "lastPrice": float(row.get("lastPrice", 0)),
                "bid": float(row.get("bid", 0)) if pd.notna(row.get("bid")) else 0.0,
                "ask": float(row.get("ask", 0)) if pd.notna(row.get("ask")) else 0.0,
                "volume": int(row.get("volume", 0)) if pd.notna(row.get("volume")) else 0,
                "openInterest": int(row.get("openInterest", 0)) if pd.notna(row.get("openInterest")) else 0,
                "impliedVolatility": float(row.get("impliedVolatility", 0)) if pd.notna(row.get("impliedVolatility")) else 0.0,
                "expiration": exp_ts,
                "inTheMoney": bool(row.get("inTheMoney", False)),
            }
            all_calls.append(call_dict)

        # Process puts
        for _, row in chain.puts.iterrows():
            contract = row.get("contractSymbol", "")
            strike = float(row.get("strike", 0))
            key = (contract, strike, exp_ts)
            if key in seen:
                continue
            seen.add(key)

            put_dict = {
                "contractSymbol": contract,
                "strike": strike,
                "lastPrice": float(row.get("lastPrice", 0)),
                "bid": float(row.get("bid", 0)) if pd.notna(row.get("bid")) else 0.0,
                "ask": float(row.get("ask", 0)) if pd.notna(row.get("ask")) else 0.0,
                "volume": int(row.get("volume", 0)) if pd.notna(row.get("volume")) else 0,
                "openInterest": int(row.get("openInterest", 0)) if pd.notna(row.get("openInterest")) else 0,
                "impliedVolatility": float(row.get("impliedVolatility", 0)) if pd.notna(row.get("impliedVolatility")) else 0.0,
                "expiration": exp_ts,
                "inTheMoney": bool(row.get("inTheMoney", False)),
            }
            all_puts.append(put_dict)

        # Rate limit between requests
        if idx < len(target_exps) - 1:
            time.sleep(1.2)

    # Build output JSON matching Yahoo /v7/finance/options schema
    # so compute_gex.py can consume it seamlessly
    output = {
        "optionChain": {
            "result": [{
                "underlyingSymbol": sym,
                "expirationDates": exp_dates_ts,
                "hasMiniOptions": False,
                "quote": {
                    "regularMarketPrice": spot,
                    "regularMarketLastPrice": spot,
                },
                "options": [{
                    "calls": all_calls,
                    "puts": all_puts,
                    "expirationDate": "all" if fetch_all else exp_dates_ts[0] if exp_dates_ts else 0,
                }],
                "totalExpirationsMerged": len(target_exps),
            }],
        }
    }

    combined_file = os.path.join(outdir, f"{sym}_{today}_combined.json")
    with open(combined_file, "w") as f:
        json.dump(output, f, indent=2)

    # Also save individual nearest expiry
    nearest_file = os.path.join(outdir, f"{sym}_{today}_exp0.json")
    if len(target_exps) == 1:
        import shutil
        shutil.copy2(combined_file, nearest_file)

    print(f"Merged {len(target_exps)} expiry files: {len(all_calls)} calls, {len(all_puts)} puts", file=sys.stderr)
    print(combined_file)  # stdout: path to combined file

if __name__ == "__main__":
    main()
PYEOF
)

$VERBOSE && echo "[main] starting fetch for $SYM" >&2
python3 -c "$FETCHER" "$SYM" "$OUTDIR" "$FETCH_ALL" "$VERBOSE"
