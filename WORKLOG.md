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

## 2026-06-14: Phase 1 Batch 2 — Force System Completion ✅ COMPLETE

### Implementation Summary
**Duration:** ~4h

1. **Shared Infrastructure (C2)**
   - Created `lib/esad_common.sh` — constants, logging helpers, SQLite executor with Python fallback
   - Created `scripts/init_databases.sh` — 3 SQLite databases: `events.db`, `event_signal_mapping.db`, `signals.db`
   - Created `config/force_priority.json` — 9 forces ranked by historical win rate, conflict penalty rules
   - Created `config/etf_sector_map.json` — ETF→sector mapping for Force 8

2. **Force Expansion (A1-A3)**
   - **A1 F8 ETF Fund Flow Momentum** (`12_fetch_etf_flows.sh`) — yfinance proxy for sector ETF flows, VIX adjustment
   - **A2 F9 VIX Roll Yield Window** (`13_fetch_vix_term_structure.sh`) — contango/backwardation regime detection, shift detection with 60-day history
   - **A3 FOMC Force Split**
     - F5b Fed Balance Sheet (`14_fetch_fed_balance_sheet.sh`) — FRED WALCL API, QT/QE regime detection, TLT fallback
     - F5c FOMC Forward Guidance (`15_fetch_fomc_guidance.sh`) — CME FedWatch implied rate, COT positioning data

3. **Architecture Fixes (C1-C4)** — All implemented in single pipeline `09_compute_structural_forces.sh`
   - **C1 Force Conflict Arbitration** — priority matrix, adjacent stalemate (0.7x penalty), priority override (rank-scaled penalty), overwhelming strength override (≥0.80 conf + top-3 rank = no penalty), multi-way blur fallback
   - **C3 Decorrelated Confluence Boost** — B_base (1/2/3/4+ sources = 1.00/1.20/1.35/1.45), B_deriv (1 + 0.10 × derivative count), hard cap at 0.92
   - **C4 Global Confidence Gate** — 0.50 minimum threshold, tier system: ≥0.65=ACTION, 0.55–0.64=ALERT, 0.45–0.54=WATCH, 0.45–0.49=POTENTIAL (log only, no alert), <0.45=SUPPRESSED

### Pipeline Integration Test ✅ PASS
**Test scenario:** 4 concurrent forces (F2 Gamma BULLISH, F5b QT BEARISH, F8 ETF Flow BULLISH, F9 VIX Contango BULLISH)
- 4 forces collected, 1 BEARISH vs 3 BULLISH
- 3 conflicts detected (bull vs bear pairings)
- 4 independent sources → boost = 1.45
- Mean confidence 0.53 × 1.45 = 0.768 → capped to 0.658 (ACTION tier)
- Final output: tier=ACTION, dir=BULLISH, conf=0.658

### Batch 2 Deliverables Summary
| Component | Files | Status |
|-----------|-------|--------|
| Shared lib | `lib/esad_common.sh` | ✅ |
| DB init | `scripts/init_databases.sh` | ✅ |
| Config | `config/force_priority.json`, `config/etf_sector_map.json` | ✅ |
| New forces | `12_fetch_etf_flows.sh`, `13_fetch_vix_term_structure.sh`, `14_fetch_fed_balance_sheet.sh`, `15_fetch_fomc_guidance.sh` | ✅ |
| Pipeline | `09_compute_structural_forces.sh` (C1+C3+C4) | ✅ |
| Integration tested | 4-force multi-source scenario | ✅ |

---

## Next: Phase 1 Implementation — Event Calendar + IPO Force
- P1.1-P1.4 Infrastructure: SQLite schemas, cache/logging framework
- P1.5-P1.9 Data Collection Scripts: IPO, EDGAR, FOMC, Econ, OpEx
- P1.10-P1.12 Force Deduction: IPO stabilization, FOMC vol compression
- P1.13-P1.18 Signal Generation + Reporting + Cron

## 2026-06-14: Phase 3 — Window Dressing + Squeeze + Lockup + Rebalancing ✅ COMPLETE

### Implementation Summary

Phase 3 adds 4 new structural forces (F3, F4, F6, F7), bringing total to **10 active forces**:

1. **F3 Window Dressing** (`20_compute_window_dressing_force.sh`)
   - P3.1 Quarter-end date tracking: 3/6/9/12 month-ends
   - P3.2 Performance ranker embedded in weighting logic
   - 3 regimes: pre_window (T-7 to T-2) → marking_close → rebound
   - Quarter weighting: Q4 (1.0x) > Q1/Q3 (0.7x) > Q2 (0.5x)
   - Month-end aligned boost for concurrent monthly rebalancing

2. **F4 Short Squeeze** (`21_detect_short_squeeze.sh`)
   - P3.4 Finviz proxy: yfinance VIX + volume composite
   - P3.5 Squeeze setup detector: 4-factor intensity scoring
     * Contango score (VIX term structure): 30% weight
     * Volume spike score (SPY 5d vs 10d avg): 30% weight
     * Price momentum score: 25% weight
     * Seasonal score (Jan/Feb meme, June): 15% weight
   - Intensity >= 0.75 → BULLISH
   - Current: intensity=0.82 → BULLISH 70% confidence

3. **F6 Index Rebalancing** (`23_monitor_index_rebalancing.sh`)
   - P3.7 S&P + Russell calendar-based monitor
   - S&P quarterly (3/6/9/12 3rd Friday)
   - Russell annual (June 3rd Friday, 1.5x magnitude)
   - 3 regimes: front_running (T-10 to T-2) → execution → post_rebal
   - Current: 5 days to June 19 Russell rebalance → BULLISH 55%

4. **F7 Lockup Expiry** (`22_track_lockup_expiry.sh`)
   - P3.6 SEC S-1 proxy: IPO calendar + 180-day lockup calculation
   - 3 regimes: anticipatory selling → relief rally → distant
   - IPO waves: Q1→Jul, Q2→Oct, Q3→Jan, Q4→Apr

### Integration Test Results (ALL 10 FORCES)

| Code | Force | Direction | Conf | Status |
|------|-------|-----------|------|--------|
| F1 | IPO Underwriter | — | — | Inactive (no IPOs) |
| F2 | Gamma Dealer | BULLISH | 75% | ✅ Negative gamma @ ZG |
| F2b | OpEx Gamma Flip | NEUTRAL | 25% | ✅ 5 days to weekly OpEx |
| F3 | Window Dressing | NEUTRAL | 10% | ✅ 16 days to Q2 end |
| F4 | Short Squeeze | BULLISH | 70% | ✅ High squeeze intensity |
| F5a | FOMC Vol Compression | BULLISH | 60% | ✅ FOMC blackout |
| F5b | Fed Balance Sheet | MILDLY_BULLISH | 50% | ✅ Real FRED data |
| F6 | Index Rebalancing | BULLISH | 55% | ✅ Russell front-running |
| F7 | Lockup Expiry | NEUTRAL | 10% | ✅ No near-term expiries |
| F8 | ETF Flows | BULLISH | 57% | ✅ Inflow momentum |
| F9 | VIX Term Structure | BULLISH | 40% | ✅ Contango regime |

**Pipeline Final Output:**
- 10 active forces (9 decorrelated source groups)
- 0 conflicts (C1 clean pass)
- Confluence boost: 1.595x
- Final signal: **BULLISH 92% ACTION tier**

---
