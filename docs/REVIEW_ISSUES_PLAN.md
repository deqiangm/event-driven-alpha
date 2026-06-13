# ESAD Design Review — Issue Resolution Plan

> Generated from thorough review of SYSTEM_DESIGN.md v1.0, 2026-06-12

## Issue Cluster A: Structural Force Gaps (Design-level)

### A1. Add Force 8: ETF Fund Flow Momentum
- Large daily ETF flows (>3B) force passive fund mechanical buying/selling
- Data: etf.com daily flows (free), BlackRock/iShares weekly flows
- Need: define trigger conditions, confidence, direction, magnitude

### A2. Add Force 9: VIX Roll Yield Window
- VIX contango→backwardation shift forces VIX products to adjust
- Already mentioned in research (Volmageddon) but not a dedicated force
- Need: define trigger conditions, confidence, direction, magnitude

### A3. FOMC Force Too Thin — Split & Expand
- Current Force 5 only has vol compression/expansion (2 sub-scenarios)
- Missing: Fed Balance Sheet changes (QT/QE switch), dot plot shift detection, Forward Guidance direction
- Need: expand Force 5 into FOMC Vol + Fed Balance Sheet sub-forces with independent confidence scores

---

## Issue Cluster B: Data Pipeline Hard Issues (Implementation-critical)

### B1. Squeezemetrics Unreliable — Need GEX Backup Plan
- Squeezemetrics 503/unstable since 2024, cannot be primary GEX source
- Need: CBOE CSV + pygex self-calc as primary, Squeezemetrics as supplementary only
- Risk: entire Phase 2 (GEX) depends on this

### B2. SEC EDGAR Rate Limiting
- 10 requests/second hard limit, scanning full market S-1/424B4 will hit it
- Need: rate limiting in 02_fetch_sec_filings.sh + date range narrowing + caching strategy
- Risk: silent data gaps if throttled

### B3. NASDAQ IPO Calendar API May Have Changed
- NASDAQ redesigned site in 2025, old API endpoint may be broken
- Need: verify current endpoint, fallback to IPOScoop + Google Finance IPO
- Risk: Phase 1 IPO detection fails silently

---

## Issue Cluster C: Architecture & Confidence Gaps (Logic-critical)

### C1. Force Conflict Arbitration Missing
- Design mentions CONFLUENCE and CONFLICT but no arbitration rule when forces oppose
- Need: Force Priority Matrix — when opposing forces, rank by historical win rate to decide dominant direction
- Example: OpEx gamma pinning UP + FOMC surprise DOWN → who wins?

### C2. Signal-Event DB No Linkage
- events.db and signals.db created separately, no foreign key or mapping table
- Need: event_signal_mapping table or foreign key, so signals can trace back to source events for auditing

### C3. Confluence Boost Table Too Aggressive
- 4 forces at 0.55 each → 0.55×1.8=0.99 (near-certain), but correlated forces inflate real confidence
- Need: decorrelation adjustment — only truly independent forces get full boost; same-event-derived forces count as 1 source + N subordinate with reduced multiplier

### C4. Short Squeeze Threshold Too Low (0.45)
- 0.45 confidence below actionable threshold, unclear if user should act
- Need: either raise minimum confidence gate (filter out <0.5), or tighten squeeze conditions (borrow_fee>80%, SI>35%) to achieve higher confidence

---

## Issue Cluster D: Alpha Finder V4 Integration Risks

### D1. Static Weight Shift Wastes Alpha On No-Signal Days
- tech 0.45→0.40 loses weight when ESAD has no signal (most days)
- Need: dynamic weight — when esad_signals.json empty, revert to original weights; when signal present, add structural dimension

### D2. Structural Signals May Target Tickers Outside Alpha Finder Pool
- Alpha Finder scans 190 tickers; ESAD may generate signals for tickers not in pool
- Need: signal generation checks Alpha Finder V4 ticker pool, marks pool-matched signals specially

---

## Issue Cluster E: Report & Plan Polish

### E1. No-Signal Report Empty
- When no structural alpha, "KEY INSIGHT" section is empty
- Need: explicit "🟢 NO STRUCTURAL ALPHA" message + timestamp + version in all reports

### E2. 5-Week Timeline Too Aggressive
- 12 scripts + 7(→9) forces + GEX parsing + integration + backtest
- Need: realistic re-plan with dry-run phase after Phase 1

### E3. Missing Phase Dependencies
- Phase 3 window dressing needs quarter-end dates from Phase 1's opex script
- Need: explicit dependency map between phases

---

## Execution Order (by dependency & impact)

1. **B3** — Verify NASDAQ IPO API (blocks Phase 1, must know before coding)
2. **B1** — GEX backup plan (blocks Phase 2, foundational)
3. **C1** — Force conflict arbitration (core logic, must be in design before coding)
4. **C3** — Confluence boost fix (core logic, affects signal quality)
5. **C4** — Squeeze confidence threshold (core logic)
6. **A3** — FOMC force expansion (design-level, easy to add before coding)
7. **A1** + **A2** — Add Forces 8&9 (design-level, add before coding)
8. **C2** — DB linkage design (schema change, before Phase 1 coding)
9. **D1** + **D2** — Dynamic V4 integration (integration logic, before Phase 4)
10. **E1** — Report format polish (minor, can do with code)
11. **E2** + **E3** — Re-plan timeline (after all design fixes settled)
12. **B2** — SEC EDGAR rate limiting (implementation detail, with Phase 1 coding)
