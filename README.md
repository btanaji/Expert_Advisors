# MT5 Expert Advisors

MT5 port of the "Open Close Cross Alert R6.2" Pine Script indicator, plus an
Expert Advisor that trades its signals.

## Files

- `Indicators/OCC_Alert.mq5` — the ported indicator. Computes an MA (SMA, EMA,
  SMMA, LWMA, DEMA, TEMA, Hull, LSMA, ALMA, SSMA, TMA — matching the Pine
  script's `variant()` options) of open and close, optionally on a higher
  timeframe (`InpUseAltTF` / `InpAltTF`, replacing Pine's resolution
  multiplier), and plots the "OCC line" (the open/close MA difference factor,
  `pcd`) in a separate chart sub-window with a zero level line, green/red
  coloring by trend, and circle markers on crossover alerts — giving the same
  visual representation as the original indicator on the MT5 chart.
- `Experts/OCC_EA.mq5` — the Expert Advisor. Attaches `OCC_Alert` to the chart
  on init (`ChartIndicatorAdd`) so the indicator is visible while the EA
  trades, and reads its buffer via `iCustom`/`CopyBuffer`.
- `Experts/OCC_EA_Standalone.mq5` — **recommended for backtesting.** A fully
  self-contained version of the EA that has no dependency on
  `OCC_Alert.mq5`/`iCustom()` at all — it computes the OCC line internally
  every bar. This avoids the "indicator file read error" / stale-`.ex5`
  issues `iCustom` can hit in the Strategy Tester when the indicator isn't
  compiled or in sync with the EA. It still gives visual feedback on the
  chart without needing a separate indicator sub-window: a live label
  (top-left) showing the current OCC value/trend, and up/down arrow markers
  drawn on bars where a Buy/Sell was triggered.

## Strategy rules implemented

- **Buy**: OCC line below zero. On each new closed candle, if the OCC value of
  the just-closed bar is greater than the prior closed bar's value, open a
  long position.
- **Sell**: OCC line above zero. On each new closed candle, if the OCC value
  of the just-closed bar is less than the prior closed bar's value, open a
  short position.
- **Stop loss**: placed `InpSlBufferPoints` points beyond the entry price, on
  the side appropriate to trade direction (below for buys, above for sells).
- **Trailing** (`InpTrailEnabled`, optional): once price has moved
  `InpTrailPips` in the trade's favor, the SL trails behind price by the same
  buffer distance, in `InpTrailPips` increments.
- **Reversal exit**: when trailing is disabled, the only exit is an opposite
  OCC signal, which closes the open position.

## HIRO Proxy Flip EA (second strategy)

`Experts/HIRO_Flip_EA_Standalone.mq5` is a separate, fully self-contained EA
ported from the "AP Capital – HIRO Proxy (Flow Pressure)" Pine Script (v6).
It has no dependency on any other file — the HIRO pseudo-candle series
(z-scored, ATR-filtered, volume-weighted cumulative directional pressure) is
computed internally in this one file. Plain AP logic only, no trend filter.

**Entry rule (straddle)**: on any HIRO flip (red→green or green→red), the EA
opens **both** a Buy and a Sell simultaneously (equal `InpLots` each).

> **Requires a hedging-mode MT5 account.** Both legs must coexist on the same
> symbol at once — on a netting account they would simply cancel each other
> out. Check your account type before running this EA.

**Breakeven + close-the-other-leg (CTC)**: once *either* leg reaches
`InpBreakevenPips` profit, that leg's SL is moved to its own entry price
(breakeven) and the other, still-pending leg is closed immediately.

**Surviving leg management**: from that point it's managed exactly like a
single-position flip trade — optional pip-increment trailing
(`InpTrailEnabled` / `InpTrailPips`, same mechanics as before) beyond the
breakeven point, or if trailing is disabled, held until an opposite flip
signal closes it. A new straddle is only opened once any previous one has
fully resolved (both legs closed).

**Visual representation**: built into the EA itself (no separate indicator
needed) — a live label showing the current HIRO z-value and candle color,
plus up/down arrows on bars where a straddle was triggered.

## Installation

### Option A — Standalone EA (recommended, no indicator dependency)

1. Copy `Experts/OCC_EA_Standalone.mq5` (and/or `Experts/HIRO_Flip_EA_Standalone.mq5`)
   into your MT5 `MQL5/Experts/` folder.
2. Compile it in MetaEditor.
3. Attach it to a chart, or run it directly in the Strategy Tester — no other
   file is required.

### Option B — EA + separate indicator (indicator visible in its own sub-window)

1. Copy `Indicators/OCC_Alert.mq5` into your MT5 `MQL5/Indicators/` folder.
2. Copy `Experts/OCC_EA.mq5` into your MT5 `MQL5/Experts/` folder.
3. Compile both in MetaEditor (compile the indicator first).
4. Attach `OCC_EA` to a chart. It will automatically load `OCC_Alert` onto the
   chart for visual confirmation of signals.

Note: with Option B, both files must always be recompiled/kept in sync — if
you change the indicator's inputs or buffers, update the EA's `iCustom()`
call and buffer index to match, and make sure `OCC_Alert.ex5` is present and
current before backtesting `OCC_EA`. Option A avoids this entirely.

## Notes / deviations from the Pine script

- Divergence detection (the optional `uDiv`/regular/hidden divergence
  plotting in the Pine script) is not ported, since the trading rules only
  depend on the OCC line itself.
- Pine's "resolution multiplier" is replaced with a direct MT5
  `ENUM_TIMEFRAMES` selection (`InpAltTF`) for the alternate-timeframe MA
  calculation — pick whichever higher timeframe you'd like the MA computed
  on.
- Make sure the indicator inputs on the EA (`InpMAType`, `InpMAPeriod`,
  `InpUseAltTF`, `InpAltTF`, etc.) match the ones you use if you also attach
  `OCC_Alert` manually — the EA creates its own indicator handle with its own
  input values.
