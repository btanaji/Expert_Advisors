# Testing EA31337-strategies in MetaTrader 5

This directory is a vendored, flattened snapshot of
[EA31337/EA31337-strategies](https://github.com/EA31337/EA31337-strategies)
(all git submodules resolved into plain files, so it's ready to copy straight
into a MetaTrader 5 data folder — no `git submodule` step needed on your end).

## What this repo actually is

This is **not** a set of ready-to-run `.mq5` Expert Advisors. It's a
collection of ~70 strategy *modules* (`AC/`, `ADX/`, `MACD/`, `RSI/`, ...),
each providing a `Stg_<Name>.mqh` include file that defines one trading
strategy's logic (signal open/close conditions, price-stop levels, indicator
params). They only become compilable, runnable EAs when combined with:

1. **[EA31337-classes](https://github.com/EA31337/EA31337-classes)** — the
   core framework (`EA.mqh`, `Strategy.mqh`, `Indicator` base classes, order
   management, etc.). Referenced via `#include <EA31337-classes/...>` in
   `.github/Test.mq5`, so it must be installed under
   `MQL5/Include/EA31337-classes/`.
2. Optionally **EA31337-Indicators-Common** / **EA31337-Indicators-Other**
   for indicators not built into MT5.
3. One of the top-level "assembler" EA projects that actually `#include`s a
   `Stg_*.mqh` file inside an `OnInit`/`OnTick` EA shell — e.g.
   `.github/Test.mq5` in this repo (a minimal single-strategy test harness)
   or the full multi-strategy **[EA31337](https://github.com/EA31337/EA31337)**
   / **EA31337-Libre** robot.

So "testing a strategy in MT5" means: get the framework installed, then
compile a small `.mq5` file that includes both the framework and the one
`Stg_*.mqh` you want to test.

## Step-by-step: backtest a single strategy (e.g. RSI) in the Strategy Tester

1. **Install MetaTrader 5** and open `File > Open Data Folder` to find your
   `MQL5/` directory.

2. **Get the framework.** Clone the classes repo into
   `MQL5/Include/EA31337-classes/`:
   ```
   git clone https://github.com/EA31337/EA31337-classes.git \
     "<data folder>/MQL5/Include/EA31337-classes"
   ```
   (Pin the version to match the `Tag/Framework` compatibility table in the
   original repo's `README.md` if you hit compile errors — the strategies
   repo README lists which framework tag goes with which strategies tag.)

3. **Copy the strategy files.** Copy this whole `EA31337-strategies/`
   directory (or just the one strategy folder you want, e.g. `RSI/`, plus
   `enum.h`, `includes.h`, `manager.h`) into
   `MQL5/Experts/EA31337-strategies/`.

4. **Create a test EA.** The simplest path is to reuse `.github/Test.mq5`
   from this repo as a template: copy it into
   `MQL5/Experts/EA31337-strategies/Test_RSI.mq5` and edit the strategy
   include near the bottom to point at the strategy you want, e.g.:
   ```mql5
   #include "RSI/Stg_RSI.mqh"
   ```
   (swap the `#include "../Demo/Stg_Demo.mqh"` line for your target
   strategy's `Stg_*.mqh`). Multiple `#include`s can be added if you want to
   test several strategies from one EA.

5. **Compile.** Open `Test_RSI.mq5` in MetaEditor and press F7 (Compile).
   Fix any missing-include errors by checking the framework version pin
   mentioned in step 2 — version mismatches between `EA31337-classes` and
   `EA31337-strategies` are the most common compile failure.

6. **Run the Strategy Tester.**
   - Open MT5 → `View > Strategy Tester` (Ctrl+R).
   - Expert Advisor: select `EA31337-strategies\Test_RSI`.
   - Symbol/Period: pick a symbol with good historical data (e.g.
     `EURUSD`, `H1`).
   - Date range: choose a multi-month/year window.
   - Model: "Every tick based on real ticks" for the most accurate results
     (slower); "1 minute OHLC" for quick iteration.
   - Inputs tab: tune the `<Strategy>_*` parameters (lot size, signal open
     method, price-stop levels, max spread, etc.) that the strategy exposes
     as `INPUT` variables — visible in the `Stg_*.mqh` file.
   - Click **Start**. Review the Results/Graph/Report tabs for win rate,
     drawdown, profit factor, etc.

7. **Optimize (optional).** Use the Tester's "Optimization" mode to sweep
   the strategy's INPUT parameters (the repo's own CI does this via the
   `optimize-*.yml` GitHub workflows in each strategy folder, which is a
   good reference for which params are worth sweeping and over what range).

## Testing multiple strategies together / the full multi-strategy robot

The strategy modules here are designed to be assembled by the actual
**EA31337** or **EA31337-Libre** trading robot, which loads many strategies
at once and manages capital allocation between them. If the goal is to test
the full portfolio rather than one strategy in isolation:

1. Clone `EA31337/EA31337` (or `EA31337-Libre`) instead of hand-rolling a
   test EA.
2. Point its build/config at this `EA31337-strategies` checkout (or let it
   pull its own submodules) plus `EA31337-classes`.
3. Compile the robot's main `.mq5` and backtest that instead — it exposes
   per-strategy enable/weight inputs so you can turn strategies on/off in
   the Tester's Inputs tab.

## Practical tips

- **MQL4 vs MQL5**: each strategy folder also ships an MQL4-flavored
  `.mqh` where applicable — the framework is designed for code parity across
  both, but for MT5 always include the MQL5 path (`EA31337-classes`, not an
  MQL4 fork).
- **Missing indicators**: some strategies wrap custom indicators (e.g.
  SVE Bollinger Bands, TMA_True). If MetaEditor complains about a missing
  custom indicator `.mq5`/`.ex5`, pull it from
  `EA31337/EA31337-Indicators-Other` (or `-Common`) into
  `MQL5/Indicators/`.
- **Version pinning matters more than usual** here because the strategies
  and the framework are versioned in lock-step (see the Tag/Framework table
  in the upstream README). If you cloned `main` for both, you're usually
  fine; mixing an old strategies tag with a new classes tag is the most
  common source of confusing compile errors.
- **CI as a reference**: every strategy folder has its own
  `.github/workflows/{check,compile,backtest,optimize-*}.yml` — these show
  exactly which command-line Strategy Tester invocations and parameter
  ranges the upstream project itself uses for backtesting/optimizing that
  strategy, which is useful as a starting config instead of guessing input
  ranges from scratch.
