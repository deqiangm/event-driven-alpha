# ESAD — Event-Driven Structural Alpha Detector

## System Design Document v1.0

**Project**: Event-Driven Structural Alpha Detector (ESAD)  
**Created**: 2026-06-11  
**Philosophy**: Detect hidden market opportunities driven by STRUCTURAL FORCES, not by price momentum or social sentiment  
**Integration**: Feeds signals into Alpha Finder V4 as a new dimension + standalone alert system  

---

## 1. Problem Statement

Alpha Finder V4 is a **reactionary system** — it detects alpha AFTER signals appear (technical breakouts, social spikes, insider moves). It cannot detect:

- **Pre-IPO market stabilization** (underwriters buying indices before mega-IPOs)
- **Gamma-driven price floors/ceilings** (options dealer hedging creating invisible support/resistance)
- **Quarter-end forced flows** (institutions window-dressing portfolios)
- **Short squeeze setups** (structural conditions before a catalyst triggers explosion)
- **Index rebalancing opportunities** (mechanical buying/selling on predictable dates)
- **Lockup expiration pressure** (insider selling at known future dates)

These are **structural alpha** — opportunities derived from the self-interest of market participants, not from chart patterns or Reddit posts.

**The SpaceX Example**: Market drops Mon-Wed before a mega-IPO. Underwriters MUST support the market or risk IPO failure. Wednesday's dip = the best buying opportunity, because Thursday's recovery is structurally guaranteed by underwriter self-interest.

---

## 2. Design Principles

1. **Shell-first**: All data collection and signal processing in Shell scripts. Python only for complex math (GEX calculation) or when no shell alternative exists.
2. **Event calendar as the spine**: Everything starts from "what events are coming?" — not "what's the market doing now?"
3. **Structural force deduction, not price prediction**: We don't predict direction from charts. We deduce direction from WHO has WHAT incentive and WHEN they must act.
4. **Three-validation framework**: Every signal must pass First Principles (why does this force exist?) + Induction (what happened historically?) + Deduction (what must happen logically?).
5. **Backward compatible**: Output integrates with Alpha Finder V4 pipeline without breaking existing flows.
6. **LLM for interpretation only**: LLM reads event context and explains implications. Never in the computation path.

---

## 3. Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    ESAD System                          │
│                                                         │
│  ┌─────────────┐    ┌──────────────┐    ┌────────────┐ │
│  │ Layer 1:    │───▶│ Layer 2:     │───▶│ Layer 3:   │ │
│  │ Event       │    │ Structural   │    │ Alpha      │ │
│  │ Calendar    │    │ Force        │    │ Signal     │ │
│  │ Scanner     │    │ Deduction    │    │ Generator  │ │
│  └─────────────┘    └──────────────┘    └────────────┘ │
│        │                   │                   │        │
│        ▼                   ▼                   ▼        │
│  ┌──────────┐      ┌────────────┐     ┌──────────────┐ │
│  │ Event DB │      │ Force DB   │     │ Signal DB    │ │
│  │ (SQLite) │      │ (JSON)     │     │ (SQLite)     │ │
│  └──────────┘      └────────────┘     └──────────────┘ │
│                                                 │       │
│                    ┌──────────────────────┐      │       │
│                    │ Output Layer         │◀─────┘       │
│                    │ ├ Alpha Finder Feed  │              │
│                    │ ├ Telegram Alerts    │              │
│                    │ └ Daily Report       │              │
│                    └──────────────────────┘              │
└─────────────────────────────────────────────────────────┘
```

### Layer 1: Event Calendar Scanner

**Purpose**: Know WHAT is happening and WHEN, before it happens.

**Event Types Tracked**:

| Event | Source | Update Frequency | Lead Time |
|-------|--------|-------------------|-----------|
| Mega IPO (>$1B) | NASDAQ/NYSE IPO calendar, SEC EDGAR 424B4 | Daily | 5-30 days |
| FOMC meetings | Federal Reserve calendar | Weekly | 1-8 weeks |
| Major economic releases | FRED, TradingEconomics | Weekly | 1-4 weeks |
| OpEx dates (monthly/weekly) | CBOE calendar | Monthly | 1-4 weeks |
| Quarter-end dates | Calendar (fixed) | Yearly | 1-12 weeks |
| Index rebalancing | S&P/Russell announcements | As-needed | 1-4 weeks |
| Lockup expirations | SEC Form S-1, IPO filings | One-time | 180 days post-IPO |
| Major earnings (mega-cap) | Zacks/Finnhub | Weekly | 1-4 weeks |

**Implementation**: `scripts/event_calendar_scanner.sh`
- Fetches IPO calendar from NASDAQ public API
- Checks SEC EDGAR for new S-1/424B4 filings (mega deals)
- FOMC/economic calendar from FRED/TradingEconomics
- OpEx dates computed locally (standard CBOE schedule)
- Quarter-end dates hardcoded (Mar/Jun/Sep/Dec last trading day)
- Stores in SQLite: `data/events.db` table `upcoming_events`

**Event Scoring**:
```
event_magnitude = deal_size_or_impact_score × market_sensitivity
event_urgency = days_until_event (inverse)
event_confidence = data_quality × source_reliability
structural_score = event_magnitude × event_urgency × event_confidence
```

### Layer 2: Structural Force Deduction Engine

**Purpose**: For each upcoming event, deduce WHAT structural forces exist and WHICH DIRECTION they push.

**7 Structural Forces**:

#### Force 1: IPO Underwriter Stabilization (THE SPACEX PLAY)
```
IF:
  mega_ipo (>$5B) IN next_5_trading_days
  AND market_declining (SPY < -2% over 5d)
  AND VIX_elevated (>20)
THEN:
  structural_force = "underwriter_buy_support"
  direction = BULLISH
  target = SPY/QQQ/index_calls
  confidence = 0.7 (if deal >$5B) to 0.85 (if deal >$10B)
  timing_window = T-3 to T-1 (entry at deepest dip)
  exit = T+0 or T+1 (IPO pricing day)
```

**Validation**:
- First Principles: Underwriters profit from successful IPOs; failed IPOs destroy future business. They have both capital and incentive to stabilize.
- Induction: VIX drops 8.3% before successful mega-IPOs vs rises 12.7% before failures. SPY volume +18%.
- Deduction: If market is down 3% and a $10B IPO is in 3 days, underwriters MUST either: (a) support market, (b) delay IPO (reputation hit), or (c) accept lower pricing (money left on table). Option (a) is structurally most likely.

#### Force 2: Gamma Dealer Hedging (GEX)
```
IF:
  OpEx IN next_5_trading_days
  AND net_GEX > 0 (long gamma)
  AND price_near_key_strike
THEN:
  structural_force = "gamma_pinning"
  direction = MEAN-REVERTING toward key strike
  confidence = 0.6

IF:
  net_GEX < 0 (short gamma)
  AND market_trending
THEN:
  structural_force = "gamma_acceleration"  
  direction = TREND-AMPLIFYING
  confidence = 0.55
  WARNING: high risk, trend can exhaust
```

**Data Pipeline**: `scripts/gex_calculator.sh`
- Fetches CBOE open interest data (daily delayed, free)
- Computes net GEX per strike using pygex or inline Python
- Identifies key gamma levels (largest absolute GEX strikes)
- Stores in `cache/gex_data.json`

#### Force 3: Quarter-End Window Dressing
```
IF:
  quarter_end IN next_5_trading_days
  AND quarter_performance_extreme (top/bottom decile stocks)
THEN:
  structural_force = "window_dressing"
  direction = BUY winners, SELL losers
  for_top_decile: BULLISH bias (+30-50bps)
  for_bottom_decile: BEARISH bias (-30-50bps)
  confidence = 0.65 (Q4) to 0.55 (Q1-Q3)
  REVERSAL: first week of new quarter, opposite direction
```

#### Force 4: Short Squeeze Setup
```
IF:
  short_interest > 25%
  AND borrow_fee > 50%
  AND days_to_cover > 5
  AND catalyst_approaching (earnings/positive news)
THEN:
  structural_force = "short_squeeze_setup"
  direction = EXPLOSIVELY BULLISH on catalyst
  confidence = 0.45 (high R:R compensates)
  risk = 50%+ if wrong (time decay)
```

#### Force 5: FOMC Vol Compression/Expansion
```
IF:
  FOMC IN next_2_trading_days
THEN:
  structural_force = "vol_compression"
  direction = DECLINING VIX (pre-meeting)
  confidence = 0.60

IF:
  FOMC_outcome = surprise (vs consensus)
THEN:
  structural_force = "vol_expansion"
  direction = TRENDING (follows surprise direction)
  confidence = 0.55
```

#### Force 6: Index Rebalancing
```
IF:
  stock_added_to_sp500
  AND effective_date IN next_5_trading_days
THEN:
  structural_force = "index_buy_pressure"
  direction = BULLISH (mechanical buying from passive funds)
  confidence = 0.75
  magnitude = 3-8% (historical average)
```

#### Force 7: Lockup Expiration
```
IF:
  lockup_expiration IN next_5_trading_days
  AND insider_ownership > 30%
  AND post_ipo_performance > +50%
THEN:
  structural_force = "lockup_selling_pressure"
  direction = BEARISH
  confidence = 0.65
  magnitude = 2-5%
```

### Layer 3: Alpha Signal Generator

**Purpose**: Combine event calendar + structural forces into actionable trading signals.

**Signal Fusion Logic**:
```
For each upcoming event:
  1. Identify applicable structural forces
  2. Score each force (direction, confidence, magnitude)
  3. Check for CONFLUENCE (multiple forces same direction)
  4. If confluence ≥ 2 forces same direction:
     → ALPHA_SIGNAL with boosted confidence
  5. Check for CONFLICT (forces opposing)
     → REDUCED confidence, flag as complex
  6. Generate entry/exit/timing recommendations

Signal Output Format:
{
  "signal_id": "ESAD-20260612-001",
  "event": "SpaceX Starlink IPO",
  "event_date": "2026-06-12",
  "structural_forces": [
    {"force": "underwriter_buy_support", "direction": "bullish", "confidence": 0.80},
    {"force": "quarter_end_window_dressing", "direction": "bullish", "confidence": 0.60}
  ],
  "confluence": 2,
  "composite_direction": "STRONGLY_BULLISH",
  "composite_confidence": 0.85,
  "entry_condition": "SPY dip >1.5% within T-3 to T-1",
  "entry_instrument": "SPY ATM calls, 7-14 DTE",
  "exit_condition": "IPO pricing day close, or +3% profit",
  "stop_loss": "-2% from entry",
  "risk_reward": "3:1",
  "timing_window": "2026-06-09 to 2026-06-12"
}
```

**Confluence Boost Table**:

| Forces Aligned | Confidence Multiplier | Signal Strength |
|----------------|----------------------|-----------------|
| 1 force | 1.0x | WATCH |
| 2 forces | 1.3x | ALERT |
| 3 forces | 1.6x | ACTION |
| 4+ forces | 1.8x | STRONG ACTION |

---

## 4. Data Pipeline

### Daily Data Collection (Shell Scripts)

```
scripts/
├── 01_fetch_ipo_calendar.sh      # NASDAQ/NYSE upcoming IPOs
├── 02_fetch_sec_filings.sh       # S-1, 424B4 new filings  
├── 03_fetch_fomc_calendar.sh     # Fed meeting schedule
├── 04_fetch_econ_calendar.sh     # Economic releases
├── 05_fetch_opex_dates.sh        # CBOE expiration calendar
├── 06_fetch_short_interest.sh    # Ortex/Finviz high SI stocks
├── 07_fetch_gex_data.sh          # CBOE OI → GEX calculation
├── 08_fetch_index_changes.sh     # S&P/Russell additions/deletions
├── 09_compute_structural_forces.sh  # Layer 2 deduction engine
├── 10_generate_alpha_signals.sh  # Layer 3 signal generation
├── 11_format_report.sh           # Telegram-ready report
└── run_daily_scan.sh             # Master orchestrator
```

### Data Sources (Free/Paid Tier)

| Source | Data | Cost | API Type |
|--------|------|------|----------|
| NASDAQ IPO Calendar | Upcoming IPOs, deal sizes | Free | HTTP JSON |
| SEC EDGAR | S-1, 424B4 filings | Free | REST/JSON |
| FRED | FOMC dates, economic data | Free | REST API |
| CBOE | Options OI, expiration dates | Free (delayed) | CSV/HTTP |
| TradingEconomics | Economic calendar | Free tier | REST API |
| Finviz | Short interest screener | Free | Web scrape |
| Yahoo Finance | Market data, VIX, SPY | Free | yfinance |
| Squeezemetrics | GEX daily data | Free | HTTP |
| Finnhub | Earnings calendar | Free tier | REST API |
| IPOScoop | IPO ratings, performance | Free | Web scrape |

### Cache Strategy

```
cache/
├── ipo_calendar.json        # TTL: 24h
├── sec_filings.json         # TTL: 12h  
├── fomc_calendar.json       # TTL: 7d
├── econ_calendar.json       # TTL: 24h
├── opex_dates.json          # TTL: 30d (computed)
├── short_interest.json      # TTL: 24h
├── gex_data.json            # TTL: 24h
├── index_changes.json       # TTL: 7d
└── structural_forces.json   # TTL: computed on scan
```

---

## 5. Integration with Alpha Finder V4

### Signal Feed
ESAD signals are written to a shared location that Alpha Finder V4 can read:

```
data/esad_signals.json  →  Alpha Finder V4 reads this in Phase 0
```

### New Fusion Dimension
Add to Alpha Finder V4's fusion scoring:

```
Current: tech(0.45) + social(0.30) + tv(0.15) + insider(0.10)
New:     tech(0.40) + social(0.25) + tv(0.15) + insider(0.10) + structural(0.10)
```

When `esad_signals.json` contains a signal for a ticker in the scan pool:
- `structural_score` = confidence × direction_alignment (0-100)
- Bullish structural signal + bullish tech = BOOSTED fused_score
- Bearish structural signal + bullish tech = PENALTY (divergence warning)

### Alpha Type Enrichment
ESAD signals add new alpha_type classifications:
- `ipo_play` — Stock benefits from pre-IPO market support
- `gamma_pin` — Stock near key gamma strike at OpEx
- `window_dressing_winner` — Top decile stock entering quarter-end
- `squeeze_setup` — High SI + catalyst approaching
- `index_addition` — Stock being added to major index

---

## 6. Cron Schedule

| Job | Schedule | Duration | Purpose |
|-----|----------|----------|---------|
| Event Calendar Scan | 0 6 * * 1-5 | ~60s | Fetch all event data |
| Structural Force Update | 0 7 * * 1-5 | ~30s | Compute forces from events |
| Alpha Signal Generation | 30 7 * * 1-5 | ~30s | Generate + filter signals |
| GEX Data Update | 0 16 * * 1-5 | ~120s | Post-market OI data |
| Telegram Alert | 0 8 * * 1-5 | ~10s | Send daily ESAD report |
| Pre-IPO Monitor | 0 */4 * * 1-5 | ~30s | Check for new IPO filings |

---

## 7. Report Format (Telegram)

```
🔍 ESAD Daily Structural Alpha Report
━━━━━━━━━━━━━━━━━━━━━━━
📅 2026-06-11 (Thu)

🔴 MEGA-IPO WATCH
├ SpaceX Starlink IPO: T-1 day (Jun 12)
├ Deal Size: ~$10B (Mega)
├ Structural Force: Underwriter Buy Support
├ Market Condition: SPY -2.3% (5d), VIX 22.5 ↑
├ 🔥 CONFLUENCE: 2 forces aligned BULLISH
│  ├ Underwriter stabilization (conf: 0.80)
│  └ Quarter-end window dressing (conf: 0.60)
├ ⏰ Entry Window: TODAY if SPY dips >1.5%
├ 🎯 Instrument: SPY 595C 06/20 (7 DTE)
└ 📊 Composite: STRONGLY BULLISH (0.85)

🟡 OPEX GAMMA MAP
├ SPX Key Gamma Strike: 5900 (call wall)
├ Net GEX: +$850M (long gamma)
├ Effect: Price pinning toward 5900
└ Confidence: 0.60

🟢 QUARTER-END FLOWS (T-4 days)
├ Top winners likely supported: NVDA, META, AVGO
├ Bottom losers likely sold: NKE, PFE, INTC
└ Reversal expected: Jul 1-5

⚪ NO SIGNAL
├ Short squeeze: No new setups
├ Index changes: No pending additions
└ Lockup expirations: None this week

━━━━━━━━━━━━━━━━━━━━━━━
💡 KEY INSIGHT: SpaceX IPO tomorrow + market dip = underwriters MUST stabilize. Today's dip is the opportunity.
```

---

## 8. Implementation Phases

### Phase 1: Event Calendar + IPO Force (Week 1)
- [ ] Project structure + SQLite schema
- [ ] IPO calendar fetcher (NASDAQ API)
- [ ] SEC EDGAR S-1/424B4 monitor
- [ ] FOMC/economic calendar fetcher
- [ ] OpEx date calculator
- [ ] IPO underwriter force deduction
- [ ] Basic Telegram report
- [ ] Cron setup (daily 6AM + pre-IPO monitor)
- **Deliverable**: Can detect mega-IPOs and alert on underwriter buy-support setup

### Phase 2: GEX + OpEx Forces (Week 2)
- [ ] CBOE OI data fetcher
- [ ] GEX calculator (Python helper for math, Shell orchestrator)
- [ ] Gamma pinning force deduction
- [ ] OpEx signal generation
- [ ] GEX map in daily report
- **Deliverable**: Can detect gamma-driven opportunities at OpEx

### Phase 3: Window Dressing + Squeeze + Lockup (Week 3)
- [ ] Quarter-end window dressing detector
- [ ] Short interest fetcher (Finviz scrape)
- [ ] Short squeeze setup detector
- [ ] Lockup expiration tracker
- [ ] Index rebalancing monitor
- [ ] All 7 forces operational
- **Deliverable**: Full 7-force structural alpha detection

### Phase 4: Alpha Finder V4 Integration (Week 4)
- [ ] Signal feed to Alpha Finder V4 (esad_signals.json)
- [ ] New fusion dimension (structural 0.10)
- [ ] Alpha type enrichment (ipo_play, gamma_pin, etc.)
- [ ] Backward compatibility verification
- [ ] Joint report (Alpha V4 + ESAD combined)
- **Deliverable**: Alpha Finder V4 enhanced with structural alpha signals

### Phase 5: Backtesting + Optimization (Week 5)
- [ ] Historical signal validation (2020-2026 IPOs, OpEx events)
- [ ] Confidence score calibration
- [ ] Entry/exit timing optimization
- [ ] Win rate tracking per force type
- [ ] Adaptive confidence adjustment
- **Deliverable**: Validated, calibrated system with tracked performance

---

## 9. File Structure

```
~/.hermes/cron/event-driven-alpha/
├── docs/
│   ├── RESEARCH_SUMMARY.md      # This file's companion: research findings
│   ├── SYSTEM_DESIGN.md         # This design document  
│   ├── SYSTEM_DESIGN_CN.md      # Chinese version
│   └── FORCE_CATALOG.md         # Detailed force specifications
├── scripts/
│   ├── 01_fetch_ipo_calendar.sh
│   ├── 02_fetch_sec_filings.sh
│   ├── 03_fetch_fomc_calendar.sh
│   ├── 04_fetch_econ_calendar.sh
│   ├── 05_fetch_opex_dates.sh
│   ├── 06_fetch_short_interest.sh
│   ├── 07_fetch_gex_data.sh
│   ├── 08_fetch_index_changes.sh
│   ├── 09_compute_structural_forces.sh
│   ├── 10_generate_alpha_signals.sh
│   ├── 11_format_report.sh
│   ├── run_daily_scan.sh        # Master orchestrator
│   └── gex_calculator.py        # Python math helper (GEX only)
├── data/
│   ├── events.db                # SQLite: upcoming_events table
│   ├── signals.db               # SQLite: generated_signals table
│   └── esad_signals.json        # Feed to Alpha Finder V4
├── cache/
│   ├── ipo_calendar.json
│   ├── sec_filings.json
│   ├── fomc_calendar.json
│   ├── econ_calendar.json
│   ├── opex_dates.json
│   ├── short_interest.json
│   ├── gex_data.json
│   └── index_changes.json
├── logs/
│   └── esad_$(date).log
├── CHECKLIST.md                 # Implementation tracking
├── WORKLOG.md                   # Change log
└── PLAN.md                      # Phase plan
```

---

## 10. Three-Validation Summary

### First Principles ✅
Each structural force derives from the self-interest of market participants:
- Underwriters stabilize because failed IPOs = lost future business
- Market makers hedge because delta-neutral = risk management mandate
- Institutions window-dress because quarterly reports = client perception
- Short sellers cover because borrow costs compound and squeezes are existential

### Induction ✅
- Pre-IPO VIX compression: -8.3% before successful IPOs (Aggarwal 2000)
- Gamma pinning: Empirically documented by SpotGamma, CBOE data
- Window dressing: 30-50bps effect confirmed by Lakonishok, Musto, Ng & Wang
- Index additions: 3-8% pop on mechanical buying (70%+ win rate)

### Deduction ✅
- If a $10B IPO must succeed, and market is down, underwriters MUST buy → recovery is structurally guaranteed
- If dealers are long gamma at a strike, their hedging mathematically compresses price toward that strike
- If quarter-end is in 3 days and a stock is top-decile performer, funds MUST buy it for reporting
- If short interest >25% and a positive catalyst hits, shorts MUST cover → explosive upward move

---

## 11. Risk & Limitations

1. **Underwriter force can fail** (Uber 2019): If macro event overwhelms structural force (trade war, black swan), underwriters may not have enough capital. Risk mitigation: never exceed 5% portfolio on any single structural alpha bet.
2. **GEX data is delayed**: CBOE OI data is T+1, real-time GEX is estimated. SpotGamma/real-time data requires paid subscription.
3. **Window dressing reversal**: The quarter-end boost reverses in the first week of new quarter. Must time exits precisely.
4. **Short squeeze timing**: Catalyst is unpredictable. Setup detection is easy, timing is hard.
5. **Data source reliability**: Free APIs (NASDAQ IPO calendar, Finviz scrape) may change format or rate-limit. Need fallback sources.
6. **Overconfidence in structural forces**: Just because a force exists doesn't mean it will dominate. Always check if competing forces are stronger.
