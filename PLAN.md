# ESAD Implementation Plan

## Project: Event-Driven Structural Alpha Detector

### Goal
Build a system that detects hidden market opportunities driven by structural forces (underwriter incentives, dealer hedging, institutional flows) — complementing Alpha Finder V4's reactive scanning with proactive event-driven signals.

### Key Deliverables
1. **Event Calendar Scanner** — Know what's coming before it happens
2. **Structural Force Deduction Engine** — Deduce market direction from participant incentives
3. **Alpha Signal Generator** — Convert forces into actionable trades
4. **Alpha Finder V4 Integration** — Feed structural signals into existing pipeline
5. **Telegram Alert System** — Daily structural alpha report

### Timeline: 5 weeks
- Week 1: Phase 1 (IPO + event calendar)
- Week 2: Phase 2 (GEX + OpEx)
- Week 3: Phase 3 (Window dressing + squeeze + lockup)
- Week 4: Phase 4 (Alpha Finder integration)
- Week 5: Phase 5 (Backtesting + optimization)

### Success Metrics
- Detect >80% of mega-IPO (>5B) pre-stabilization opportunities
- GEX signal accuracy >55% directional
- Quarter-end flow signals >60% accuracy
- Zero Alpha Finder V4 regression
- Daily Telegram report delivered by 8AM ET

### Constraints
- Shell-first implementation (Python only for GEX math)
- Free data sources primarily (paid as optional upgrade)
- Must not break existing Alpha Finder V4 cron schedule
- All signals pass three-validation framework
