# ESAD Implementation Checklist

## Phase 1: Event Calendar + IPO Force (Week 1) 🔴 NOT STARTED

### Infrastructure
- [ ] P1.1 Create SQLite schema for events.db
- [ ] P1.2 Create SQLite schema for signals.db
- [ ] P1.3 Setup cache directory structure
- [ ] P1.4 Setup logging framework

### Data Collection Scripts
- [ ] P1.5 `01_fetch_ipo_calendar.sh` — NASDAQ IPO calendar API
- [ ] P1.6 `02_fetch_sec_filings.sh` — SEC EDGAR S-1/424B4 monitoring
- [ ] P1.7 `03_fetch_fomc_calendar.sh` — FOMC meeting schedule
- [ ] P1.8 `04_fetch_econ_calendar.sh` — Economic release calendar
- [ ] P1.9 `05_fetch_opex_dates.sh` — CBOE expiration date calculator

### Force Deduction
- [ ] P1.10 IPO underwriter stabilization force logic
- [ ] P1.11 FOMC vol compression force logic
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

## Phase 2: GEX + OpEx Forces (Week 2) ⬜ PENDING

- [ ] P2.1 CBOE OI data fetcher
- [ ] P2.2 gex_calculator.py (Python math helper)
- [ ] P2.3 Gamma pinning force deduction
- [ ] P2.4 Negative gamma acceleration detection
- [ ] P2.5 Key gamma strike identification
- [ ] P2.6 OpEx signal generation
- [ ] P2.7 GEX map in daily report
- [ ] P2.8 Test with historical OpEx events

---

## Phase 3: Window Dressing + Squeeze + Lockup (Week 3) ⬜ PENDING

- [ ] P3.1 Quarter-end date tracker
- [ ] P3.2 Stock quarterly performance ranker
- [ ] P3.3 Window dressing force deduction
- [ ] P3.4 Finviz short interest scraper
- [ ] P3.5 Short squeeze setup detector
- [ ] P3.6 Lockup expiration tracker (SEC S-1 parsing)
- [ ] P3.7 Index rebalancing monitor (S&P announcements)
- [ ] P3.8 All 7 forces integration test

---

## Phase 4: Alpha Finder V4 Integration (Week 4) ⬜ PENDING

- [ ] P4.1 esad_signals.json → Alpha Finder V4 reader
- [ ] P4.2 New fusion dimension (structural 0.10)
- [ ] P4.3 Alpha type enrichment (5 new types)
- [ ] P4.4 Backward compatibility verification
- [ ] P4.5 Joint report generation
- [ ] P4.6 Full pipeline integration test

---

## Phase 5: Backtesting + Optimization (Week 5) ⬜ PENDING

- [ ] P5.1 Historical IPO signal validation (2020-2026)
- [ ] P5.2 Historical OpEx signal validation
- [ ] P5.3 Confidence score calibration
- [ ] P5.4 Entry/exit timing optimization
- [ ] P5.5 Win rate tracking per force type
- [ ] P5.6 Adaptive confidence adjustment
- [ ] P5.7 Performance report
