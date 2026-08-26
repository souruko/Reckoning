repo: souruko/RedBook
branch: main

## Last sync

date: 2026-08-20T08:22:19Z

### Updated in this project

- Recreated the current analysis window, live meter and death cause from the Lua source (`0a`–`0c`).
- Redesigned the analysis graph as a line-and-dot plot with morale as a background bar graph (`1a`).
- Added self-buff tracking (uptime table + charted lanes) and a two-handle time-range slider.
- Wrote `REDESIGN_SPEC.md`: the Lua-side changes (tokens, graph pools, `Session:Slice`, `Buffs.lua`, layout).

## Screen map

| Screen | Built from |
| --- | --- |
| `RedBook Analyzer.dc.html` — `0a` analysis (current) | `UI/Analysis.lua`, `UI/AnalysisGraph.lua`, `UI/Frame.lua`, `UI/Row.lua`, `UI/Bar.lua`, `Constants.lua` |
| `RedBook Analyzer.dc.html` — `0b` live meter | `UI/LiveMeter.lua`, `UI/Frame.lua`, `Constants.lua` |
| `RedBook Analyzer.dc.html` — `0c` death cause | `UI/DeathCause.lua`, `UI/Row.lua`, `UI/Bar.lua`, `Constants.lua` |
| `RedBook Analyzer.dc.html` — `1a` analysis (redesign) | `UI/Analysis.lua`, `UI/AnalysisGraph.lua`, `Session.lua`, `docs/DESIGN.md` |
| `RedBook Analyzer.dc.html` — `1b`/`1c` meter + death redesign | `UI/LiveMeter.lua`, `UI/DeathCause.lua` |
| Mock data in both sections | `reference/Combat_20260819_1.txt`, `reference/Enemy_20260819_1.txt` |
| `REDESIGN_SPEC.md` | `Session.lua`, `UI/Analysis.lua`, `UI/AnalysisGraph.lua`, `Constants.lua`, `docs/DESIGN.md`, `docs/IMPLEMENTATION_PLAN.md` |
