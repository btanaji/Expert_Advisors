# Analysis: Nyao Scalper v43.0

Vendored from [elrizwiraswara/nyao_scalper_mt5](https://github.com/elrizwiraswara/nyao_scalper_mt5)
(BSD-3-Clause). This is a single self-contained `.mq5` Expert Advisor — no
external framework or submodules, unlike `EA31337/` elsewhere in this repo.

## What it is

A **scalping EA for M1/M5** (built and tuned specifically for XAUUSD, works
on EURUSD too) that trades off a **weighted 0–10 "Signal Score"** rather than
a single indicator crossover. One file, ~5,870 lines, `#property strict`.
Five ready-made input profiles ship in `settings/*.set`
(`aggressive`, `safe-aggressive`, `default`, `balanced`, `safe`) — same code,
different risk/frequency dials.

## Core entry logic

Every new closed bar (by default — see "New-bar gate" below), the EA computes
a **Buy score** and a **Sell score**, each built from:

| Component | Max pts | What it checks |
|---|---|---|
| Trend alignment | 1.5 | Fast EMA (5) vs Slow EMA (12) on the correct side |
| Trend slope | 1.5 | Fast EMA rising/falling over `SlopeLookback` bars (not just 1 bar — reduces M1 whipsaw) |
| RSI sweet spot | 1.0 | RSI(8) in 50–80 for buys / 20–50 for sells |
| RSI breakout | 0.5 | RSI just crossed 60 (buy) / 40 (sell) |
| Body momentum | 1.5 | Current candle body > recent average, boosted further by an "impulse" multiplier (body acceleration + range expansion + consecutive same-direction candles) |
| Chop filter | 2.0 | ATR ratio classifies trending vs. choppy; chop regime now scores **0**, not free points |
| Volatility | 1.0 | Expanding ATR (ratio > 1.2) adds; quiet market adds 0 |
| Peak breakout | 1.0 | Price breaking a recent 5-bar high/low |
| Wick rejection | −(penalty) | Long opposing wick subtracts, scaled by wick/body ratio |

A **Dead-Market Filter** hard-zeroes the whole score if
`ATR / AvgATR < MinVolRatioToTrade` — the EA refuses to trade a market too
quiet to cover costs, regardless of how the other components score.

**Entry condition**: `TotalScore >= MinSignalScore` (profile-dependent,
4.5 in `default`). Score is smoothed via a **blended weighted average**
(recent closed candles + a dampened contribution from the still-forming
candle) to avoid intrabar repaint.

### New-bar gate (important for backtest fidelity)

`EnableNewBarEntryOnly = true` by default: **new entries** are only evaluated
once per closed bar. Position *management* (trailing, health checks, hedge
chain) still runs every tick. The README explicitly calls this out as what
makes Strategy Tester results representative of live behavior — the flip
side is: **virtual-SL re-entries fire intrabar by default**, bypassing this
gate unless you also set `ReentryRespectsNewBarGate = true`.

## Order sizing

Three optional lot-scaling modes, stackable:
- **Recovery mode**: increases lot after equity drawdown, capped at
  `MaxEquityDropLotSteps`, and disabled during cooldown / while the basket is
  floating a loss (so it never scales up while actively bleeding).
- **Confidence mode**: larger lot for high-confidence signals (score > 8.0).
- **Velocity boost**: small size bump when signal momentum is accelerating.

## Exit / risk management — several independent layers

1. **Manual TP/SL** (`SLValue`/`TPValue`, default) *or* **Independent
   Risk:Reward mode** (`EnableRiskReward`) — the latter derives SL from ATR
   (or a manual distance) and sets TP as a fixed multiple
   (`RiskRewardRatio`, default 1.5×), locked at entry so trailing never
   overwrites the target.
2. **Adaptive trailing** — standard trailing plus a signal-based variant that
   tightens/loosens TP/SL as the live Signal Score changes.
3. **Position health revalidation** — a running weighted score from trend
   alignment, RSI zone, adverse ATR excursion, and swing structure; below a
   threshold, the EA scales out (75%→25% closed, 50%→50%, 25%→full exit)
   rather than binary hold/exit.
4. **Break-even lock** once profit clears spread cost.
5. **Virtual SL + re-entry**: closes a losing position at the health
   threshold, then immediately re-opens at the (better) current price if the
   signal is still valid — a soft-stop rather than a hard stop-out.
6. **Basket stop** — portfolio-level: closes **all** positions and pauses if
   total floating loss exceeds `MaxBasketLossPct` of equity, independent of
   per-position stops.
7. **Equity guards**: min-equity hard stop, max-drawdown-from-peak stop,
   optional daily profit target that halts trading for the day.
8. **News filter**: pauses around high-impact calendar events — **but does
   not work in the Strategy Tester** (`CalendarValueHistory` returns nothing
   there per the README) — backtests are optimistic around news vs. live.
9. **Trading-hours window** and a **leverage-change guard** (pauses if
   account leverage changes unexpectedly mid-session).
10. **Max-spread filter** — blocks new entries above a fixed points value or
    an ATR-derived ratio; the README flags this as critical on M1 gold where
    spread dominates cost.

## Hedge Chain Recovery — optional martingale (off in `safe` profile)

When a position is losing by `HedgeTriggerATR × ATR` **and** the opposite
side's signal score confirms (`HedgeMinSignalScore` — an anti-spike filter
so a single wick doesn't trigger it), the EA opens a reverse "hedge" leg and
manages the pair as a bounded rolling chain (max 2 legs open at once):
- **Covered**: hedge profit covers the older leg's loss → close the older
  leg, let the hedge graduate and trail (with a recovery-locked SL floor and
  ATR-based trailing, since the hedge typically carries a much larger lot).
- **Roll**: hedge losing but older leg back to break-even → close the older
  leg free, open a bigger reverse hedge. Repeats up to `HedgeCycleLevels`.
- **Reseed**: at cycle/lot limits, partial-close the deepest leg and start a
  smaller fresh cycle (up to `HedgeMaxCycles`), capping lot growth instead of
  compounding it indefinitely.
- **Exhausted → released**, not force-closed: once limits are hit, legs hand
  back to normal trailing/health-management/basket-stop coverage.
- An optional hard loss cap (`HedgeMaxChainLossPct`/`USD`) exists but ships
  **off** in every profile — genuine ruin risk is architecturally bounded by
  cycles+lot, not by a hard stop, unless you turn that cap on yourself.

This is the single riskiest feature in the EA and is explicitly labeled as
such in the upstream README — evaluate it separately from the base scoring
system before trusting a backtest that includes it.

## Notable operational detail: local password gate

`nyao_scalper.mq5` includes an optional on-chart password dialog
(`EA_PASSWORD` constant, empty/disabled by default) that blocks `OnTick()`
entirely until submitted. It's off out of the box, but **if you set it**,
be aware it uses `CDialog`/chart controls — this can interfere with
**headless/optimization runs** in the Strategy Tester (no chart UI to click
"Submit" against), so leave it empty for any automated backtest/optimization
pass.

## Settings profiles (from `settings/*.set`)

| Profile | Threshold | Base/Max Lot | Basket Stop | Hedge Chain |
|---|---|---|---|---|
| aggressive | 3.5 | 0.03 / 0.10 | 12% equity | On |
| safe-aggressive | 4.0 | 0.01 / 0.03 | 7% equity | On |
| default | 4.5 | 0.01 / 0.05 | 8% equity | On |
| balanced | 5.0 | 0.01 / 0.05 | 6% equity | On |
| safe | 6.0 | 0.01 / 0.01 | 3% equity | **Off** |

Per the README's account-size guidance: `safe-aggressive` for $100–500
accounts, `default`/`balanced` for $500–1000, any profile viable above
$1000 (bigger accounts can absorb aggressive-profile drawdowns).

## How to test it in MT5 (per its own README)

1. Copy `nyao_scalper.mq5` into `MQL5/Experts/`, compile (F7).
2. Load a `.set` profile in the Strategy Tester's Inputs tab ("Load").
3. **Use "Every tick based on real ticks"** modeling — the README is explicit
   that lower-fidelity modes misrepresent this EA's intrabar behavior; "1
   Minute OHLC" is only acceptable for a fast first pass since
   `EnableNewBarEntryOnly` means entries are bar-close-decided anyway.
4. **Set realistic commission and spread** in the Tester — the README calls
   an M1 XAUUSD backtest without both "meaningless," since spread+commission
   dominate cost at this timeframe.
5. Remember the news filter is inert in the Tester — treat backtest drawdown
   around news events as optimistic vs. live.
6. **Validate out-of-sample**: given the large input surface, tune on one
   period and confirm on a separate untouched period (or walk-forward)
   before trusting a profile — the README explicitly warns in-sample
   optimization overfits easily here.
7. Check the Experts/journal log to confirm entries only fire on bar close,
   spread/ATR guards are actually skipping trades when expected, and the
   basket stop fires at the configured threshold.

## How this compares to the other project in this repo (`EA31337/`)

| | EA31337 | Nyao Scalper |
|---|---|---|
| Architecture | Multi-strategy framework, ~70 pluggable strategy modules + submodule dependencies | Single self-contained file, one scoring strategy |
| Signal model | Per-strategy indicator condition (binary-ish, per strategy) | One continuous weighted score (0–10) combining many factors at once |
| Timeframe design | One strategy per timeframe slot, all running concurrently | Single timeframe (M1/M5), scalping-focused |
| Risk layers | Per-strategy SL/TP, tick/signal filters, suspension on margin failure | Much deeper stack: basket stop, equity/drawdown guards, health revalidation, optional martingale hedge chain |
| Dependencies | Requires `EA31337-classes` framework + other submodules | None — compiles standalone |
| Best fit | Comparing/combining many classic TA strategies systematically | A single highly-tuned scalping system with heavy built-in risk management |
