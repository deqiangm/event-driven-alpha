#!/usr/bin/env python3
"""compute_gex.py — Black-Scholes GEX calculator

Core formula (from FlashAlpha-lab/gex-explained):
    GEX_per_contract = gamma_bs × OI × 100 × spot²
    Put GEX is negative: −gamma_bs × OI × 100 × spot²
    Aggregate by strike → GEX(strike) profile
    Zero-gamma level: interpolation across sign change

Input:  JSON from fetch_options_chain.sh (Yahoo options chain)
Output: JSON with gex_by_strike, zero_gamma, net_gex, spot, timestamp

Design ref: docs/solutions/B1_GEX_DATA_BACKUP.md
"""

import json
import math
import sys
from typing import Any

# ── Black-Scholes helpers (no scipy dependency, pure math) ─────────────────

def norm_pdf(x: float) -> float:
    """Standard normal PDF."""
    return math.exp(-0.5 * x * x) / math.sqrt(2 * math.pi)

def norm_cdf(x: float) -> float:
    """Standard normal CDF — Abramowitz & Stegun approximation."""
    a1, a2, a3, a4, a5 = 0.254829592, -0.284496736, 1.421413741, -1.453152027, 1.061405429
    p = 0.3275911
    sign = 1 if x >= 0 else -1
    x = abs(x) / math.sqrt(2.0)
    t = 1.0 / (1.0 + p * x)
    y = 1.0 - (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * math.exp(-x * x)
    return 0.5 * (1.0 + sign * y)

def bs_gamma(spot: float, strike: float, ttm: float, iv: float, r: float, q: float = 0.0) -> float:
    """Black-Scholes gamma (same for calls and puts).

    gamma = N'(d1) / (S * sigma * sqrt(T))
    where d1 = [ln(S/K) + (r - q + 0.5*sigma^2)*T] / (sigma*sqrt(T))
    """
    if ttm <= 0 or iv <= 0 or spot <= 0:
        return 0.0
    sqrt_t = math.sqrt(ttm)
    d1 = (math.log(spot / strike) + (r - q + 0.5 * iv * iv) * ttm) / (iv * sqrt_t)
    return norm_pdf(d1) / (spot * iv * sqrt_t)


def days_to_years(days: float) -> float:
    """Convert calendar days to year fraction (365-day basis)."""
    return days / 365.0


def compute_gex(data: dict, risk_free_rate: float = 0.045) -> dict[str, Any]:
    """Compute GEX from Yahoo options chain JSON.

    Returns dict with:
        gex_by_strike: dict[{strike: float}] = net_gex_billion
        zero_gamma: float or None
        net_gex: float (total net GEX in billions)
        spot: float
        call_gex_total: float
        put_gex_total: float
        n_contracts: int
        timestamp: str
    """
    result_chain = data.get("optionChain", {}).get("result", [])
    if not result_chain:
        raise ValueError("No optionChain data in input")

    meta = result_chain[0].get("quote", {})
    spot = meta.get("regularMarketPrice", 0.0)
    if spot <= 0:
        # Fallback to last price
        spot = meta.get("regularMarketLastPrice", meta.get("price", 0.0))
    if spot <= 0:
        raise ValueError(f"Cannot determine spot price from meta: {meta}")

    # Determine current timestamp
    import datetime
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()

    # Accumulate GEX by strike
    gex_by_strike: dict[float, float] = {}  # strike → net GEX in billions
    call_gex_total = 0.0
    put_gex_total = 0.0
    n_contracts = 0

    options_groups = result_chain[0].get("options", [])

    for opt_group in options_groups:
        # Process calls (positive GEX)
        for call in opt_group.get("calls", []):
            strike = call.get("strike", 0)
            oi = call.get("openInterest", 0)
            iv = call.get("impliedVolatility", 0)
            expiry_ts = call.get("expiration", 0)

            if oi <= 0 or iv <= 0:
                continue

            # Compute time to expiry in years
            if expiry_ts > 0:
                ttm = days_to_years(max((expiry_ts / 86400) - (int(datetime.datetime.now().timestamp()) / 86400), 1))
                # Ensure at least 1 day
                if ttm <= 0:
                    ttm = days_to_years(1)
            else:
                ttm = days_to_years(30)  # default 30 days if missing

            gamma = bs_gamma(spot, strike, ttm, iv, risk_free_rate)
            # GEX = gamma × OI × 100 × S²
            gex = gamma * oi * 100 * spot * spot
            gex_b = gex / 1e9  # convert to billions

            gex_by_strike[strike] = gex_by_strike.get(strike, 0.0) + gex_b
            call_gex_total += gex_b
            n_contracts += 1

        # Process puts (negative GEX — dealers are short gamma on puts)
        for put in opt_group.get("puts", []):
            strike = put.get("strike", 0)
            oi = put.get("openInterest", 0)
            iv = put.get("impliedVolatility", 0)
            expiry_ts = put.get("expiration", 0)

            if oi <= 0 or iv <= 0:
                continue

            if expiry_ts > 0:
                ttm = days_to_years(max((expiry_ts / 86400) - (int(datetime.datetime.now().timestamp()) / 86400), 1))
                if ttm <= 0:
                    ttm = days_to_years(1)
            else:
                ttm = days_to_years(30)

            gamma = bs_gamma(spot, strike, ttm, iv, risk_free_rate)
            gex = gamma * oi * 100 * spot * spot
            gex_b = -gex / 1e9  # ← puts are NEGATIVE

            gex_by_strike[strike] = gex_by_strike.get(strike, 0.0) + gex_b
            put_gex_total -= gex_b  # put_gex_total is the magnitude (positive)
            n_contracts += 1

    # Find zero-gamma level by interpolation
    zero_gamma = find_zero_gamma(gex_by_strike, spot)

    # Compute total net GEX
    net_gex = sum(gex_by_strike.values())

    # Sort strikes for output
    sorted_gex = {str(k): round(v, 6) for k, v in sorted(gex_by_strike.items())}

    return {
        "gex_by_strike": sorted_gex,
        "zero_gamma": zero_gamma,
        "net_gex_billions": round(net_gex, 6),
        "spot": spot,
        "call_gex_billions": round(call_gex_total, 6),
        "put_gex_billions": round(put_gex_total, 6),
        "n_contracts": n_contracts,
        "timestamp": timestamp,
        "risk_free_rate": risk_free_rate,
    }


def find_zero_gamma(gex_by_strike: dict[float, float], spot: float) -> float | None:
    """Find the zero-gamma (GEX flip) level by linear interpolation.

    Strategy: look for adjacent strikes where GEX changes sign,
    closest to the current spot price.
    """
    if not gex_by_strike:
        return None

    sorted_strikes = sorted(gex_by_strike.keys())
    candidates: list[float] = []

    for i in range(len(sorted_strikes) - 1):
        k1, k2 = sorted_strikes[i], sorted_strikes[i + 1]
        v1, v2 = gex_by_strike[k1], gex_by_strike[k2]

        if v1 * v2 < 0:  # sign change
            # Linear interpolation
            zero = k1 + (k2 - k1) * (-v1) / (v2 - v1)
            candidates.append(zero)

    if not candidates:
        return None

    # Return the zero-gamma level closest to current spot
    candidates.sort(key=lambda z: abs(z - spot))
    return round(candidates[0], 2)


def main():
    """CLI entry point: reads JSON, prints GEX results."""
    if len(sys.argv) < 2:
        print("Usage: compute_gex.py <options_chain.json> [risk_free_rate]", file=sys.stderr)
        print("  e.g. compute_gex.py data/raw/options/SPY_20260613_combined.json 0.045", file=sys.stderr)
        sys.exit(1)

    input_file = sys.argv[1]
    rfr = float(sys.argv[2]) if len(sys.argv) > 2 else 0.045  # default 4.5%

    with open(input_file) as f:
        data = json.load(f)

    result = compute_gex(data, risk_free_rate=rfr)

    # Pretty-print to stdout
    print(json.dumps(result, indent=2))

    # Also write to cache directory
    import os, datetime as dt_mod
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.dirname(script_dir)
    cache_dir = os.path.join(project_dir, "data", "cache", "gex")
    os.makedirs(cache_dir, exist_ok=True)

    # Infer symbol from filename
    basename = os.path.basename(input_file)
    sym = basename.split("_")[0] if "_" in basename else "UNKNOWN"
    today = dt_mod.datetime.now().strftime("%Y%m%d")

    cache_file = os.path.join(cache_dir, f"{sym}_{today}_gex.json")
    with open(cache_file, "w") as f:
        json.dump(result, f, indent=2)

    # Summary to stderr
    print(f"[gex] {sym}: spot={result['spot']:.2f}  "
          f"net_gex={result['net_gex_billions']:.4f}B  "
          f"zero_gamma={result['zero_gamma']}  "
          f"calls={result['call_gex_billions']:.4f}B  "
          f"puts={result['put_gex_billions']:.4f}B  "
          f"n_contracts={result['n_contracts']}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
