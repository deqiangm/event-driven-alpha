#!/usr/bin/env bash
# gex_cache.sh — Cache management for GEX pipeline
#
# TTL rules:
#   OpEx week (Mon-Fri of monthly expiration): 6 hours
#   Normal week: 24 hours
#
# Usage:
#   gex_cache.sh check    [-s SYM]   # Exit 0 if cache valid, 1 if stale/missing
#   gex_cache.sh fetch    [-s SYM]   # Fetch + compute if cache stale
#   gex_cache.sh show     [-s SYM]   # Display cached GEX summary
#   gex_cache.sh list               # List all cached symbols
#   gex_cache.sh clean     [-s SYM]  # Remove stale cache entries
#   gex_cache.sh force     [-s SYM]  # Force re-fetch regardless of TTL
#
# OpEx week detection: monthly options expire on 3rd Friday of each month.
#   If today falls within Mon-Fri of that week → 6h TTL, else 24h.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="${PROJECT_DIR}/data/cache/gex"
RAW_DIR="${PROJECT_DIR}/data/raw/options"
SYM="${SYM:-SPY}"

# ── OpEx detection ──────────────────────────────────────────────

is_opex_week() {
    # Monthly options expire on 3rd Friday of each month.
    # OpEx week = Mon..Fri containing the 3rd Friday.
    # Returns 0 (true) if today is in OpEx week, 1 (false) otherwise.
    local year month day dow third_friday opex_dow delta

    year=$(date +%Y)
    month=$(date +%m)
    day=$(date +%d)
    dow=$(date +%u)  # 1=Mon..7=Sun

    # Find the 3rd Friday of current month
    # Strategy: find what weekday the 1st is, then compute 3rd Friday
    local first_dow
    first_dow=$(date -d "${year}-${month}-01" +%u 2>/dev/null || python3 -c "
import datetime
d = datetime.date(int('$year'), int('$month'), 1)
print(d.isoweekday())
")

    # 3rd Friday: first Friday occurs on day = (5 - first_dow + 7) % 7 + 1
    local first_friday
    if [[ $first_dow -le 5 ]]; then
        first_friday=$(( 5 - first_dow + 1 ))
    else
        first_friday=$(( 12 - first_dow + 1 ))  # first_sat + 6
    fi
    third_friday=$(( first_friday + 14 ))  # 1st + 14 = 3rd

    # Day of week of the 3rd Friday
    opex_dow=$(date -d "${year}-${month}-${third_friday}" +%u 2>/dev/null || echo 5)

    # OpEx week: Mon=3rd_friday-4 .. Fri=3rd_friday
    # Check if today's day falls within [3rd_friday - 4, 3rd_friday]
    if [[ $day -ge $(( third_friday - 4 )) ]] && [[ $day -le $third_friday ]]; then
        return 0  # true: is OpEx week
    fi
    return 1  # false
}

get_ttl_seconds() {
    if is_opex_week; then
        echo $(( 6 * 3600 ))   # 6 hours
    else
        echo $(( 24 * 3600 )) # 24 hours
    fi
}

get_ttl_label() {
    if is_opex_week; then
        echo "6h (OpEx week)"
    else
        echo "24h (normal)"
    fi
}

# ── Cache helpers ────────────────────────────────────────────────

cache_file() {
    local today
    today=$(date +%Y%m%d)
    echo "${CACHE_DIR}/${SYM}_${today}_gex.json"
}

raw_file() {
    local today
    today=$(date +%Y%m%d)
    echo "${RAW_DIR}/${SYM}_${today}_combined.json"
}

cache_age_seconds() {
    local cf
    cf=$(cache_file)
    if [[ ! -f "$cf" ]]; then
        echo "999999999"  # very stale
        return
    fi
    local now mtime
    now=$(date +%s)
    mtime=$(stat -c %Y "$cf" 2>/dev/null || stat -f %m "$cf" 2>/dev/null || echo 0)
    echo $(( now - mtime ))
}

cache_valid() {
    # Returns 0 if cache is valid (fresh), 1 if stale
    local cf age ttl
    cf=$(cache_file)
    if [[ ! -f "$cf" ]]; then
        return 1  # missing
    fi
    # Check JSON validity
    if ! python3 -c "import json; json.load(open('$cf'))" 2>/dev/null; then
        return 1  # corrupt
    fi
    age=$(cache_age_seconds)
    ttl=$(get_ttl_seconds)
    if [[ $age -lt $ttl ]]; then
        return 0  # fresh
    fi
    return 1  # stale
}

# ── Commands ─────────────────────────────────────────────────────

cmd_check() {
    local cf age ttl
    cf=$(cache_file)
    if cache_valid; then
        age=$(cache_age_seconds)
        ttl=$(get_ttl_seconds)
        echo "VALID ($SYM): cache is ${age}s old (TTL=$(get_ttl_label))"
        exit 0
    else
        if [[ ! -f "$cf" ]]; then
            echo "STALE ($SYM): no cache file found"
        else
            age=$(cache_age_seconds)
            echo "STALE ($SYM): cache is ${age}s old (TTL=$(get_ttl_label))"
        fi
        exit 1
    fi
}

cmd_fetch() {
    if cache_valid; then
        echo "CACHE HIT ($SYM): using cached GEX ($(get_ttl_label))" >&2
        cache_file
        return
    fi

    echo "CACHE MISS ($SYM): fetching options chain..." >&2
    local combined fetch_stderr
    fetch_stderr=$(mktemp)
    combined=$("${SCRIPT_DIR}/fetch_options_chain.sh" -s "$SYM" 2>"$fetch_stderr") || true
    local fetch_rc=$?

    if [[ ! -f "$combined" || -z "$combined" ]]; then
        echo "ERROR: fetch_options_chain.sh failed for $SYM:" >&2
        [[ -s "$fetch_stderr" ]] && cat "$fetch_stderr" >&2
        rm -f "$fetch_stderr"
        exit 1
    fi
    rm -f "$fetch_stderr"

    echo "Computing GEX..." >&2
    python3 "${SCRIPT_DIR}/compute_gex.py" "$combined" >/dev/null

    local cf
    cf=$(cache_file)
    if [[ -f "$cf" ]]; then
        echo "CACHED ($SYM): GEX saved to $cf (TTL=$(get_ttl_label))" >&2
        echo "$cf"  # stdout: cache file path (machine-readable)
    else
        echo "ERROR: GEX computation failed" >&2
        exit 1
    fi
}

cmd_show() {
    local cf
    cf=$(cache_file)
    if [[ ! -f "$cf" ]]; then
        echo "No cache for $SYM"
        exit 1
    fi

    python3 -c "
import json, sys
with open('$cf') as f:
    d = json.load(f)
print(f'Symbol:      $SYM')
print(f'Spot:        {d[\"spot\"]:.2f}')
print(f'Net GEX:     {d[\"net_gex_billions\"]:.4f}B')
print(f'Call GEX:    {d[\"call_gex_billions\"]:.4f}B')
print(f'Put GEX:     {d[\"put_gex_billions\"]:.4f}B')
print(f'Zero Gamma:  {d[\"zero_gamma\"]}')
print(f'Contracts:   {d[\"n_contracts\"]}')
print(f'RFR:         {d[\"risk_free_rate\"]*100:.2f}%')
print(f'Timestamp:   {d[\"timestamp\"]}')
"
}

cmd_list() {
    if [[ ! -d "$CACHE_DIR" ]]; then
        echo "No cache directory"
        return
    fi

    echo "GEX Cache: $CACHE_DIR"
    echo "TTL policy: $(get_ttl_label)"
    echo "---"

    local f age_human ttl
    ttl=$(get_ttl_seconds)
    for f in "${CACHE_DIR}"/*_gex.json; do
        [[ -f "$f" ]] || continue
        local base age_s status
        base=$(basename "$f")
        age_s=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0) ))

        if [[ $age_s -lt $ttl ]]; then
            status="FRESH"
        else
            status="STALE"
        fi

        # Human-readable age
        if [[ $age_s -ge 86400 ]]; then
            age_human="$(( age_s / 86400 ))d"
        elif [[ $age_s -ge 3600 ]]; then
            age_human="$(( age_s / 3600 ))h"
        else
            age_human="$(( age_s / 60 ))m"
        fi

        echo "  $base  age=${age_human}  [$status]"
    done
}

cmd_clean() {
    local ttl f age_s
    ttl=$(get_ttl_seconds)
    local cleaned=0

    for f in "${CACHE_DIR}"/*_gex.json; do
        [[ -f "$f" ]] || continue
        age_s=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0) ))
        if [[ $age_s -ge $ttl ]]; then
            rm "$f"
            echo "REMOVED: $(basename "$f") (age=${age_s}s)"
            cleaned=$(( cleaned + 1 ))
        fi
    done

    if [[ $cleaned -eq 0 ]]; then
        echo "No stale cache entries to clean"
    else
        echo "Cleaned $cleaned stale entries"
    fi
}

cmd_force() {
    echo "FORCE RE-FETCH ($SYM)..." >&2
    # Remove today's cache
    local cf
    cf=$(cache_file)
    [[ -f "$cf" ]] && rm "$cf"

    # Also remove raw data to force fresh download
    local rf today
    today=$(date +%Y%m%d)
    rm -f "${RAW_DIR}/${SYM}_${today}"_*.json 2>/dev/null || true

    cmd_fetch
}

# ── Arg parsing ──────────────────────────────────────────────────

# First non-flag argument is the action
ACTION=""
SYM="${SYM:-SPY}"
remaining=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s)
            SYM="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        -*)
            echo "Unknown flag: $1" >&2
            exit 1
            ;;
        *)
            if [[ -z "$ACTION" ]]; then
                ACTION="$1"
            else
                remaining+=("$1")
            fi
            shift
            ;;
    esac
done

ACTION="${ACTION:-check}"

case "$ACTION" in
    check) cmd_check ;;
    fetch) cmd_fetch ;;
    show)  cmd_show ;;
    list)  cmd_list ;;
    clean) cmd_clean ;;
    force) cmd_force ;;
    *)
        echo "Unknown action: $ACTION"
        echo "Usage: $0 {check|fetch|show|list|clean|force} [-s SYM]"
        exit 1
        ;;
esac
