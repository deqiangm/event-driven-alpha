# ESAD Worklog

## 2026-06-13: Phase 1 Batch 1 — GEX Pipeline Build + Stability Testing

### Session 1: Design & Implementation
**Duration:** ~2h

1. **System Design** — Created `SYSTEM_DESIGN.md` (EN + CN bilingual)
   - 9 structural forces, event-signal DB architecture, 4-phase delivery
   - Three-Validation (First Principles / Inductive / Deductive) applied

2. **Research** — Created `RESEARCH_SUMMARY.md`
   - Free data sources validated: yfinance (options), SEC EDGAR, NASDAQ IPO, CBOE OI
   - Rate limits documented: EDGAR 10 req/s, NASDAQ no limit

3. **Code Review** — Created `docs/REVIEW_ISSUES_PLAN.md` (12 issues)
   - 4 Architecture (C1-C4), 3 Force expansion (A1-A3), 1 Data integrity (D1), 4 UX

4. **Implementation** — 3 scripts:
   - `scripts/fetch_options_chain.sh` — Yahoo/yfinance options chain fetcher
   - `scripts/compute_gex.py` — Black-Scholes GEX calculator (242 lines, no scipy)
   - `scripts/gex_cache.sh` — 6h/24h TTL cache with 6 sub-commands

---

### Session 2: Stability Testing (6 test suites, 3 bugs found & fixed)

**Test 1: fetch_options_chain.sh** ✅ PASS
- SPY options chain fetched successfully
- JSON structure verified: underlyingSymbol, expirationDates, calls/puts arrays
- All required fields present: strike, openInterest, impliedVolatility, expiration

**Test 2: compute_gex.py** ✅ PASS
- norm_cdf(0)=0.5, norm_cdf(1.96)≈0.975 — correct
- norm_pdf(0)≈0.3989 — correct
- BS gamma ATM verification passed
- SPY single-expiry: spot=741.75, net_gex=-25.5B, zero_gamma=740.94, 214 contracts

**Test 3: gex_cache.sh sub-commands** ✅ PASS
- check / list / show / fetch / clean / force — all working

**Test 4: End-to-end pipeline** ✅ PASS (after bug fix #1)
- 🐛 **Bug #1**: `cmd_fetch` stdout/stderr mixing — cache hit message + path both to stdout
- **Fix**: Message → stderr, path → stdout (strict machine/human separation)
- Location: `gex_cache.sh` lines 154-155

**Test 5: Multi-symbol (QQQ/IWM)** ✅ PASS (after bug fix #2)
- 🐛 **Bug #2**: `getopts` stops parsing at non-flag `force`, so `force -s QQQ` always processes SPY
- **Fix**: Rewrote arg parsing from getopts to manual while-loop
- Location: `gex_cache.sh` lines 122-138
- QQQ: spot=721.34, net_gex=+35B, zero_gamma=719.09, 193 contracts
- IWM: spot=292.95, net_gex=+7B, zero_gamma=288.82, 116 contracts

**Test 6: Edge cases** ✅ PASS (after bug fix #3)
- 🐛 **Bug #3**: `set -e` causes `$(fetch_options_chain.sh ...)` failure to silently exit, error message lost
- **Fix**: `|| true` to temporarily disable errexit, capture stderr via mktemp tmpfile
- Location: `gex_cache.sh` lines 159-170
- Invalid symbol → complete error + exit 1 ✅
- Unknown flag → "Unknown flag: -x" + exit 1 ✅
- Full-expiry flag (-a): SPY 9555 contracts, net_gex=-264.2B, zero_gamma=742.47 ✅

### GEX Analysis Summary (2026-06-13 snapshot)
| Symbol | Spot | Net GEX | Zero Gamma | Contracts | Dealer Position |
|--------|------|---------|------------|-----------|-----------------|
| SPY | 741.75 | -25.5B (1-exp) / -264B (all) | 740.94 / 742.47 | 214 / 9555 | Short gamma → amplify moves |
| QQQ | 721.34 | +35B | 719.09 | 193 | Long gamma → pinning behavior |
| IWM | 292.95 | +7B | 288.82 | 116 | Weak long gamma |

All zero_gamma within spot±2 — physically consistent.

---

## Next: Phase 1 Batch 2 — Force System Completion
- A1: ETF Fund Flow Momentum
- A2: VIX Roll Yield Window
- A3: FOMC Force expansion (sub-forces)
- C1-C4: Architecture fixes
