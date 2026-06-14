# ESAD Implemention Checklist

## Batch 1: Data Source Validation ✅ COMPLETE

### GEX Pipeline (B1)
- [x] B1.1 `fetch_options_chain.sh` — Yahoo/yfinance options chain fetcher
- [x] B1.2 `compute_gex.py` — Black-Scholes GEX calculator (no scipy)
- [x] B1.3 `gex_cache.sh` — 6h/24h TTL cache management
- [x] B1.4 GEX pipeline integration tested (SPY/QQQ/IWM)
- [x] B1.5 Edge cases verified (invalid symbol, clean start, force re-fetch)

### SEC EDGAR Pipeline (B2)
- [x] B2.1 Verified SEC EDGAR API — 10 concurrent requests OK, sleep 0.11s
- [x] B2.2 Rate limiting strategy documented

### IPO Calendar Pipeline (B3)
- [x] B3.1 Verified NASDAQ IPO API — 35 filings, SpaceX as #1
- [x] B3.2 Alternative sources documented (IPOScoop, Google Finance)

---

## Batch 2: Force System Completion ✅ COMPLETE

### Force Expansion
- [x] A1 Add Force 8: ETF Fund Flow Momentum
- [x] A2 Add Force 9: VIX Roll Yield Window
- [x] A3 Split & Expand FOMC Force (sub-forces: Vol Compression + Fed Balance Sheet + Forward Guidance)

### Architecture Fixes
- [x] C1 Force Conflict Arbitration — priority matrix when forces oppose
- [x] C2 Event-Signal DB linkage — foreign key or mapping table (design: docs/BATCH2_DB_LINKAGE.md ✅)
- [x] C3 Confluence Boost fix — decorrelate same-event-derived forces
- [x] C4 Squeeze confidence threshold — raise minimum gate or tighten conditions

---

## Phase 1: Event Calendar + IPO Force 🔴 NOT STARTED

### Infrastructure
- [ ] P1.1 Create SQLite schema for events.db
- [ ] P1.2 Create SQLite schema for signals.db (with C2 linkage)
- [ ] P1.3 Setup cache directory structure
- [ ] P1.4 Setup logging framework

### Data Collection Scripts
- [ ] P1.5 `01_fetch_ipo_calendar.sh` — NASDAQ IPO calendar API
- [ ] P1.6 `02_fetch_sec_filings.sh` — SEC EDGAR S-1/424B4 monitoring (with B2 rate limiting)
- [ ] P1.7 `03_fetch_fomc_calendar.sh` — FOMC meeting schedule
- [ ] P1.8 `04_fetch_econ_calendar.sh` — Economic release calendar
- [ ] P1.9 `05_fetch_opex_dates.sh` — CBOE expiration date calculator

### Force Deduction
- [ ] P1.10 IPO underwriter stabilization force logic
- [ ] P1.11 FOMC vol compression force logic (expanded per A3)
- [ ] P1.12 Event scoring algorithm implementation

### Signal Generation
- [ ] P1.13 `10_generate_alpha_signals.sh` — Signal generator
- [ ] P1.14 Signal output format (JSON schema)
- [ ] P1.15 esad_signals.json writer

### Reporting
- [ ] P1.16 `11_format_report.sh` — Telegram-ready report
- [ ] P1.17 Dual Telegram send integration
- [ ] P1.18 Daily report cron job

### Verification
- [ ] P1.19 Test with historical IPO data (Alibaba, Airbnb cases)
- [ ] P1.20 Verify no conflicts with Alpha Finder V4 cron

---

## Phase 2: GEX + OpEx Forces ⬜ PENDING

- [ ] P2.1 CBOE OI data fetcher (integrated with B1 pipeline)
- [ ] P2.2 GEX pipeline enhancement (multi-expiry aggregation)
- [ ] P2.3 Gamma pinning force deduction
- [ ] P2.4 Negative gamma acceleration detection
- [ ] P2.5 Key gamma strike identification
- [ ] P2.6 OpEx signal generation
- [ ] P2.7 GEX map in daily report
- [ ] P2.8 Test with historical OpEx events

---

## Phase 3: Window Dressing + Squeeze + Lockup ⬜ PENDING

- [ ] P3.1 Quarter-end date tracker
- [ ] P3.2 Stock quarterly performance ranker
- [ ] P3.3 Window dressing force deduction
- [ ] P3.4 Finviz short interest scraper
- [ ] P3.5 Short squeeze setup detector (with C4 confidence fix)
- [ ] P3.6 Lockup expiration tracker (SEC S-1 parsing)
- [ ] P3.7 Index rebalancing monitor (S&P announcements)
- [ ] P3.8 All 7→9 forces integration test

---

## Phase 4: Alpha Finder V4 Integration ⬜ PENDING

- [ ] P4.1 esad_signals.json → Alpha Finder V4 reader
- [ ] P4.2 Dynamic weight (no-signal → revert, signal → add structural 0.10) (D1 fix)
- [ ] P4.3 Alpha type enrichment (5 new types)
- [ ] P4.4 Backward compatibility verification
- [ ] P4.5 Joint report generation
- [ ] P4.6 Full pipeline integration test

---

## Phase 5: Backtesting + Optimization ⬜ PENDING

- [ ] P5.1 Historical IPO signal validation (2020-2026)
- [ ] P5.2 Historical OpEx signal validation
- [ ] P5.3 Confidence score calibration
- [ ] P5.4 Entry/exit timing optimization
- [ ] P5.5 Win rate tracking per force type
- [ ] P5.6 Adaptive confidence adjustment
- [ ] P5.7 Performance report
