# Building and testing EA31337 in MetaTrader 5

This directory is a **self-contained vendored snapshot** of
[EA31337/EA31337](https://github.com/EA31337/EA31337) — the actual
multi-strategy trading robot — with every one of its git submodules already
resolved and flattened into plain files:

```
EA31337/
├── Makefile                    # build entrypoint (make Lite / Advanced / Rider ...)
├── src/
│   ├── EA31337.mq5             # the EA — includes everything below
│   ├── include/
│   │   ├── classes/            # <- EA31337-classes   (core framework)
│   │   ├── common/, ea.h, includes.h, inputs.h
│   ├── strategies/              # <- EA31337-strategies (~70 Stg_*.mqh modules)
│   ├── strategies-meta/         # <- EA31337-strategies-meta (Mirror/Multi meta-strategies)
│   └── indicators/              # <- EA31337-indicators
├── sets/                        # ready-made .set input presets per mode/symbol
└── docker/                      # containerized MetaEditor/Wine build tooling
```

Nothing here needs to be fetched separately — `src/include/classes`,
`src/strategies`, `src/strategies-meta`, and `src/indicators` are ordinary
files in this repo (not git submodules), so cloning/copying this one
`EA31337/` directory is the **single, self-sufficient starting point**: no
other repository needs to be cloned or wired up to compile or backtest it.

`src/strategies/` here is the same content previously vendored separately as
`EA31337-strategies/` at the repo root — it now lives in the one place the
actual EA expects it (`src/include/includes.h` does
`#include "../strategies/includes.h"`), so there's a single copy instead of
two drifting ones.

## Quick path: compile & backtest directly in MetaTrader 5

1. **Locate your MT5 data folder**: in MetaTrader 5, `File > Open Data
   Folder` → note the `MQL5/` directory it opens.

2. **Copy the whole `EA31337/src/` tree** into
   `MQL5/Experts/EA31337/` (i.e. `MQL5/Experts/EA31337/EA31337.mq5`,
   `MQL5/Experts/EA31337/include/...`, `MQL5/Experts/EA31337/strategies/...`,
   etc. — keep the relative layout intact since the `#include`s use relative
   paths like `../strategies/...`).

3. **Open `EA31337.mq5` in MetaEditor** and press **F7** to compile.
   - The EA compiles in one of three modes — **Lite**, **Advanced**, or
     **Rider** — controlled by `src/include/common/mode.h`. Lite is the
     simplest/fastest to get compiling first; Advanced/Rider expose more
     strategies and features. Edit `mode.h` (or use the Makefile — see
     below) to pick a mode before compiling if the default doesn't suit you.
   - If MetaEditor reports a missing symbol, it's almost always a
     mode/version mismatch between the vendored `classes`, `strategies`,
     `strategies-meta`, and `indicators` folders — since all four are
     snapshotted from `main` together in this vendoring pass, a plain
     recompile should work; only re-sync if you've since edited one folder
     independently of the others.

4. **Run it in the Strategy Tester** (`Ctrl+R`):
   - Expert Advisor: `EA31337\EA31337`.
   - Symbol/Period: the project's defaults are tuned for **EURUSD**; any
     other symbol/timeframe works but expect to re-tune inputs.
   - Load a **preset** from `sets/` (via the Tester's "Load" button on the
     Inputs tab) instead of hand-configuring — these `.set` files are the
     project's own known-good starting configurations per mode/symbol.
   - In the Inputs tab, use `__Strategies_Active__` and the per-strategy
     `Stg_<Name>_Active`-style flags to enable/disable individual strategies
     (e.g. RSI, MACD, ATR) within the single multi-strategy EA, and adjust
     each one's lot size / signal / price-stop parameters.
   - Choose a multi-month/year date range and "Every tick based on real
     ticks" for accurate results (slower), or "1 minute OHLC" for fast
     iteration.
   - Click **Start** and review Results/Graph/Report.

5. **Optimize (optional)**: use the Tester's Optimization mode over the
   inputs of one or more active strategies. The repo's own CI
   (`.github/workflows/`, and per-strategy `optimize-*.yml` under
   `src/strategies/<Name>/.github/workflows/`) shows the parameter ranges
   upstream itself optimizes over — a good starting point instead of
   guessing ranges from scratch.

## Alternative: build with the provided `Makefile` (headless / CI-style)

The `Makefile` automates compiling release/backtest/optimize variants of all
three modes via MetaEditor run through Wine (`metaeditor64.exe`), the same
way upstream CI builds it. Useful if you want reproducible headless builds
rather than compiling by hand in the MetaEditor GUI:

```sh
# From inside EA31337/, with wine64 + a copy of MetaEditor's metaeditor64.exe
# available (see docker/ for a containerized version of this toolchain):
make set-lite && make compile-mql5   # compile the Lite mode EA
make Lite-Backtest                   # produce a backtest-oriented build
```

See `docker/` for a ready-made container that has Wine + MetaEditor
preinstalled if you'd rather not install them on the host — that's the
lowest-friction way to reproduce upstream's own build/test pipeline exactly.

## Single strategy in isolation vs. the full robot

- **Testing one strategy module in isolation** (e.g. just RSI, without the
  rest of the robot) — see the strategy-level guide that shipped with the
  strategies before they were merged in here: the same technique applies,
  just point the `#include` at `EA31337/src/strategies/<Name>/Stg_<Name>.mqh`
  and `EA31337/src/include/classes` for the framework instead of separate
  repos.
- **Testing the full multi-strategy portfolio** — that's what `EA31337.mq5`
  in this folder already is. It's the recommended path once you've validated
  individual strategies, since it lets you enable a combination of them and
  see the Tester's Portfolio-level results (capital allocation across
  strategies, combined drawdown, etc.) rather than one strategy's isolated
  numbers.

## Practical tips

- **Version pinning**: this vendored snapshot pins `classes`, `strategies`,
  `strategies-meta`, and `indicators` to the commits their respective
  `main` branches were at when cloned together, so they're mutually
  compatible as-is. If you update any one of these folders in place from
  upstream later, re-check the Tag/Framework compatibility table in
  upstream `EA31337-strategies`' README before assuming it still compiles.
- **MQL4 vs MQL5**: `src/EA31337.mq4` and `src/EA31337.mq5` both exist for
  code parity across MT4/MT5 — for MetaTrader 5 always compile the `.mq5`
  entrypoint.
- **`sets/` presets** are the fastest way to get a working backtest without
  hand-tuning dozens of per-strategy inputs — load one first, then tweak.
