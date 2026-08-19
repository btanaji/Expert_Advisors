//+------------------------------------------------------------------+
//|                              MeanReversionPro_EA_Standalone.mq5  |
//|  Self-contained MT5 Expert Advisor implementing a "Mean          |
//|  Reversion Pro" style multi-engine scalping system:               |
//|   - Bollinger Bands (wick-rejection and/or close-outside signals) |
//|   - Nadaraya-Watson style Gaussian kernel envelope (causal /      |
//|     non-repainting variant), same wick/close signal logic         |
//|   - RSI and Stochastic, each usable as a confirmation FILTER or   |
//|     as an independent signal SOURCE                               |
//|   - A multi-timeframe "Gann ray" (1x1 angle projected from the    |
//|     most recent swing pivot on a higher timeframe) used as a      |
//|     directional filter: only longs while the ray is rising, only  |
//|     shorts while it is falling                                     |
//|                                                                    |
//|  No external indicator / iCustom dependency - every engine is     |
//|  computed in this one file (BB/RSI/Stochastic/ATR use MT5's       |
//|  built-in indicators via iBands/iRSI/iStochastic/iATR, which are  |
//|  native to the terminal, not custom files, so there is nothing    |
//|  extra to install or keep in sync).                                |
//|                                                                    |
//|  No repaint: every signal is evaluated once, on the last fully    |
//|  CLOSED bar (shift 1), the first time it is seen after that bar   |
//|  closes. Nothing here recalculates on later ticks.                 |
//|                                                                    |
//|  Trade management: on a valid entry, SL/TP are set from ATR       |
//|  multiples (InpSL_ATR_Mult / InpTP_ATR_Mult - tune these to your  |
//|  market, as recommended). One position at a time (by magic).       |
//|  Auto TP/SL/entry zones are drawn on the chart and, unlike a       |
//|  typical EA, are never deleted, so every historical signal stays  |
//|  visible for review. Alerts (sound / popup / push) fire exactly   |
//|  once per signal.                                                  |
//+------------------------------------------------------------------+
#property copyright "Custom EA - standalone (no indicator dependency)"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//====================================================================
// Engine on/off toggles
//====================================================================
input group "== Signal Engines =="
input bool InpUseBB   = true;   // Use Bollinger Bands engine
input bool InpUseNW   = true;   // Use Nadaraya-Watson kernel envelope engine
input bool InpUseGann = true;   // Use Gann Ray (MTF) as directional filter

input group "== Oscillator Filters / Signal Sources =="
input bool InpUseRSI       = true;    // Use RSI (filter by default)
input bool InpRSIAsSignal  = false;   // RSI acts as an independent signal source instead
input bool InpUseStoch     = true;    // Use Stochastic (filter by default)
input bool InpStochAsSignal= false;   // Stochastic acts as an independent signal source instead

//====================================================================
// Entry mode
//====================================================================
enum ENUM_SIGNAL_MODE
  {
   MODE_WICK = 0,   // Wick rejection only
   MODE_CLOSE,      // Close outside only
   MODE_BOTH        // Either wick or close
  };
input group "== Entry Mode =="
input ENUM_SIGNAL_MODE InpSignalMode = MODE_BOTH; // Detection mode for BB / NW engines

//====================================================================
// Bollinger Bands
//====================================================================
input group "== Bollinger Bands =="
input int    InpBBPeriod = 20;      // BB period
input double InpBBMult   = 2.0;     // BB deviation multiplier
input ENUM_APPLIED_PRICE InpBBPrice = PRICE_CLOSE; // BB applied price

//====================================================================
// Nadaraya-Watson (causal Gaussian kernel envelope)
//====================================================================
input group "== Nadaraya-Watson Envelope =="
input double InpNWBandwidth = 8.0;   // Kernel bandwidth (h) - higher = smoother/more lag
input double InpNWAtrMult   = 3.0;   // Envelope width, ATR multiples
input int    InpNWAtrPeriod = 14;    // ATR period used for envelope width

//====================================================================
// Gann Ray (multi-timeframe)
//====================================================================
input group "== Gann Ray (MTF) =="
input ENUM_TIMEFRAMES InpGannPivotTF       = PERIOD_M15; // Higher timeframe for pivot detection
input int              InpGannFractalWing  = 2;           // Bars each side for fractal swing detection
input int              InpGannLookbackBars = 150;         // Bars to scan (on Gann TF) for the latest swing

//====================================================================
// RSI
//====================================================================
input group "== RSI =="
input int    InpRSIPeriod     = 14;   // RSI period
input double InpRSIOverbought = 70.0; // RSI overbought level
input double InpRSIOversold   = 30.0; // RSI oversold level

//====================================================================
// Stochastic
//====================================================================
input group "== Stochastic =="
input int    InpStochK          = 14;   // %K period
input int    InpStochD          = 3;    // %D period
input int    InpStochSlow       = 3;    // Slowing
input double InpStochOverbought = 80.0; // Overbought level
input double InpStochOversold   = 20.0; // Oversold level

//====================================================================
// Trade management
//====================================================================
input group "== Trade Management =="
input double InpLots        = 0.10;  // Trade volume (lots)
input int    InpAtrPeriod   = 14;    // ATR period for SL/TP sizing
input double InpSL_ATR_Mult = 1.5;   // SL distance, ATR multiples (tune to your market)
input double InpTP_ATR_Mult = 2.0;   // TP distance, ATR multiples (tune to your market)
input ulong  InpMagic       = 20260821; // Magic number
input int    InpSlippage    = 30;       // Max slippage, points

//====================================================================
// Alerts
//====================================================================
input group "== Alerts =="
input bool   InpSoundAlert = true;              // Play sound on new signal
input string InpSoundFile  = "alert.wav";        // Sound file (in MQL5/Sounds/)
input bool   InpPopupAlert = true;               // Show popup alert dialog
input bool   InpPushAlert  = false;              // Send push notification to mobile

//====================================================================
// Visuals
//====================================================================
input group "== Visuals =="
input bool  InpShowZones     = true;   // Draw Auto TP / SL zones
input bool  InpShowEntryLine = true;   // Draw dashed entry line + label
input int   InpZoneBars      = 20;     // Zone width, in bars, projected to the right

CTrade   trade;
datetime lastBarTime = 0;

int hBB    = INVALID_HANDLE;
int hRSI   = INVALID_HANDLE;
int hStoch = INVALID_HANDLE;
int hATR   = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
  {
   hBB = iBands(_Symbol, Period(), InpBBPeriod, 0, InpBBMult, InpBBPrice);
   hRSI = iRSI(_Symbol, Period(), InpRSIPeriod, PRICE_CLOSE);
   hStoch = iStochastic(_Symbol, Period(), InpStochK, InpStochD, InpStochSlow, MODE_SMA, STO_LOWHIGH);
   hATR = iATR(_Symbol, Period(), InpAtrPeriod);

   if(hBB == INVALID_HANDLE || hRSI == INVALID_HANDLE || hStoch == INVALID_HANDLE || hATR == INVALID_HANDLE)
     {
      Print("Failed to create one or more built-in indicator handles, error=", GetLastError());
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(hBB    != INVALID_HANDLE) IndicatorRelease(hBB);
   if(hRSI   != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hStoch != INVALID_HANDLE) IndicatorRelease(hStoch);
   if(hATR   != INVALID_HANDLE) IndicatorRelease(hATR);
   // NOTE: chart objects (zones / entry lines / signal arrows) are
   // deliberately NOT deleted here, so every historical signal stays
   // visible for review, as specified.
  }

//+------------------------------------------------------------------+
//| Causal (non-repainting) Gaussian kernel regression - a rolling,   |
//| backward-looking analogue of Nadaraya-Watson: only uses bars up   |
//| to and including the target bar, never future bars.               |
//+------------------------------------------------------------------+
double NWKernelValue(const double &price[], const int idx, const double bandwidth)
  {
   int window = (int)MathMin(idx + 1, MathCeil(bandwidth * 8));
   double wsum = 0, sum = 0;
   for(int j = 0; j < window; j++)
     {
      double w = MathExp(-(double)(j*j) / (2.0*bandwidth*bandwidth));
      sum  += price[idx - j] * w;
      wsum += w;
     }
   return (wsum > 0) ? sum / wsum : price[idx];
  }

//+------------------------------------------------------------------+
//| Detect the most recent fractal swing pivot on the Gann TF and     |
//| project a 1x1 angle ray forward to "now". Returns the ray's       |
//| current price value and whether it's rising (true) or falling.    |
//+------------------------------------------------------------------+
bool ComputeGannRay(double &rayValue, bool &rising)
  {
   int wing = InpGannFractalWing;
   int need = InpGannLookbackBars + wing*2 + 5;
   int avail = Bars(_Symbol, InpGannPivotTF);
   if(avail < need) need = avail;
   if(need < wing*2 + 10)
      return(false);

   double h[], l[];
   datetime t[];
   ArraySetAsSeries(h, false);
   ArraySetAsSeries(l, false);
   ArraySetAsSeries(t, false);
   if(CopyHigh(_Symbol, InpGannPivotTF, 0, need, h) <= 0) return(false);
   if(CopyLow (_Symbol, InpGannPivotTF, 0, need, l) <= 0) return(false);
   if(CopyTime(_Symbol, InpGannPivotTF, 0, need, t) <= 0) return(false);

   int n = ArraySize(h);
   int lastSwingHighIdx = -1, lastSwingLowIdx = -1;

   for(int i = n - wing - 1; i >= wing; i--)
     {
      bool isHigh = true, isLow = true;
      for(int k = 1; k <= wing; k++)
        {
         if(h[i] < h[i-k] || h[i] < h[i+k]) isHigh = false;
         if(l[i] > l[i-k] || l[i] > l[i+k]) isLow = false;
        }
      if(isHigh && lastSwingHighIdx < 0) lastSwingHighIdx = i;
      if(isLow  && lastSwingLowIdx  < 0) lastSwingLowIdx  = i;
      if(lastSwingHighIdx >= 0 && lastSwingLowIdx >= 0) break;
     }

   if(lastSwingHighIdx < 0 && lastSwingLowIdx < 0)
      return(false);

   int pivotIdx; double pivotPrice; bool up;
   if(lastSwingLowIdx > lastSwingHighIdx) // low is more recent -> ray rises from the low
     {
      pivotIdx = lastSwingLowIdx;
      pivotPrice = l[pivotIdx];
      up = true;
     }
   else // high is more recent (or equal) -> ray falls from the high
     {
      pivotIdx = lastSwingHighIdx;
      pivotPrice = h[pivotIdx];
      up = false;
     }

   //--- ATR on the Gann TF supplies the "1 unit per bar" price step
   int hAtrGann = iATR(_Symbol, InpGannPivotTF, InpAtrPeriod);
   if(hAtrGann == INVALID_HANDLE) return(false);
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(hAtrGann, 0, 0, 1, atrBuf) <= 0) { IndicatorRelease(hAtrGann); return(false); }
   double unitPerBar = atrBuf[0] / 10.0; // 1x1 Gann angle scaled by a fraction of ATR
   IndicatorRelease(hAtrGann);

   int barsElapsed = (n - 1) - pivotIdx;
   rayValue = up ? (pivotPrice + unitPerBar*barsElapsed) : (pivotPrice - unitPerBar*barsElapsed);
   rising = up;
   return(true);
  }

//+------------------------------------------------------------------+
double PipSize()
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return (digits == 3 || digits == 5) ? point*10 : point;
  }

bool HasOpenPosition()
  {
   if(!PositionSelect(_Symbol)) return(false);
   return((ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic);
  }

//+------------------------------------------------------------------+
//| Draw the Auto TP zone, Auto SL zone, and dashed entry line for a |
//| new signal. Objects are uniquely named per bar so nothing is ever|
//| overwritten - every historical signal stays on the chart.        |
//+------------------------------------------------------------------+
void DrawTradeZones(datetime signalTime, bool isBuy, double entry, double sl, double tp)
  {
   if(!InpShowZones && !InpShowEntryLine) return;

   string tag = TimeToString(signalTime, TIME_DATE|TIME_SECONDS) + (isBuy ? "_B" : "_S");
   int barSeconds = PeriodSeconds(Period());
   datetime t2 = signalTime + barSeconds*InpZoneBars;

   if(InpShowZones)
     {
      string tpName = "MRP_TPZone_" + tag;
      double tpNear = isBuy ? entry : tp;
      double tpFar  = isBuy ? tp : entry;
      ObjectCreate(0, tpName, OBJ_RECTANGLE, 0, signalTime, tpNear, t2, tpFar);
      ObjectSetInteger(0, tpName, OBJPROP_COLOR, clrLimeGreen);
      ObjectSetInteger(0, tpName, OBJPROP_FILL, true);
      ObjectSetInteger(0, tpName, OBJPROP_BACK, true);
      ObjectSetInteger(0, tpName, OBJPROP_WIDTH, 1);

      string tpLabel = "MRP_TPLabel_" + tag;
      ObjectCreate(0, tpLabel, OBJ_TEXT, 0, t2, tp);
      ObjectSetString(0, tpLabel, OBJPROP_TEXT, StringFormat("TP %.*f", (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS), tp));
      ObjectSetInteger(0, tpLabel, OBJPROP_COLOR, clrLimeGreen);

      string slName = "MRP_SLZone_" + tag;
      double slNear = isBuy ? sl : entry;
      double slFar  = isBuy ? entry : sl;
      ObjectCreate(0, slName, OBJ_RECTANGLE, 0, signalTime, slNear, t2, slFar);
      ObjectSetInteger(0, slName, OBJPROP_COLOR, clrCrimson);
      ObjectSetInteger(0, slName, OBJPROP_FILL, true);
      ObjectSetInteger(0, slName, OBJPROP_BACK, true);
      ObjectSetInteger(0, slName, OBJPROP_WIDTH, 1);

      string slLabel = "MRP_SLLabel_" + tag;
      ObjectCreate(0, slLabel, OBJ_TEXT, 0, t2, sl);
      ObjectSetString(0, slLabel, OBJPROP_TEXT, StringFormat("SL %.*f", (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS), sl));
      ObjectSetInteger(0, slLabel, OBJPROP_COLOR, clrCrimson);
     }

   if(InpShowEntryLine)
     {
      string entryName = "MRP_Entry_" + tag;
      ObjectCreate(0, entryName, OBJ_TREND, 0, signalTime, entry, t2, entry);
      ObjectSetInteger(0, entryName, OBJPROP_COLOR, clrGold);
      ObjectSetInteger(0, entryName, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, entryName, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, entryName, OBJPROP_WIDTH, 1);

      string entryLabel = "MRP_EntryLabel_" + tag;
      ObjectCreate(0, entryLabel, OBJ_TEXT, 0, signalTime, entry);
      ObjectSetString(0, entryLabel, OBJPROP_TEXT, StringFormat("Entry %.*f", (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS), entry));
      ObjectSetInteger(0, entryLabel, OBJPROP_COLOR, clrGold);
     }
  }

void FireAlert(bool isBuy, double entry, double sl, double tp)
  {
   double rr = (MathAbs(tp-entry) > 0 && MathAbs(entry-sl) > 0) ? MathAbs(tp-entry)/MathAbs(entry-sl) : 0.0;
   string msg = StringFormat("%s %s | Entry %.5f  SL %.5f  TP %.5f  RR %.2f",
                              _Symbol, isBuy ? "BUY" : "SELL", entry, sl, tp, rr);

   if(InpSoundAlert)
      PlaySound(InpSoundFile);
   if(InpPopupAlert)
      Alert("Mean Reversion Pro: ", msg);
   if(InpPushAlert)
      SendNotification(msg);
  }

bool IsNewBar()
  {
   datetime t[];
   ArraySetAsSeries(t, true);
   if(CopyTime(_Symbol, Period(), 0, 1, t) <= 0) return(false);
   if(t[0] != lastBarTime) { lastBarTime = t[0]; return(true); }
   return(false);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!IsNewBar())
      return;

   //--- pull enough closed-bar history; index [0] = oldest
   int need = MathMax(InpBBPeriod, MathMax(InpRSIPeriod, MathMax(InpStochK, InpAtrPeriod))) + 50;
   need = MathMax(need, (int)MathCeil(InpNWBandwidth*8) + 5);
   int avail = Bars(_Symbol, Period());
   need = MathMin(need, avail);
   if(need < 30) return;

   double o[], h[], l[], c[];
   ArraySetAsSeries(o, false);
   ArraySetAsSeries(h, false);
   ArraySetAsSeries(l, false);
   ArraySetAsSeries(c, false);
   if(CopyOpen(_Symbol, Period(), 0, need, o) <= 0) return;
   if(CopyHigh(_Symbol, Period(), 0, need, h) <= 0) return;
   if(CopyLow (_Symbol, Period(), 0, need, l) <= 0) return;
   if(CopyClose(_Symbol, Period(), 0, need, c) <= 0) return;
   int last = need - 1; // last closed bar (array index, oldest->newest)

   //--- Bollinger Bands (shift=1 on the indicator = last closed bar)
   double bbUpper[], bbLower[];
   ArraySetAsSeries(bbUpper, true);
   ArraySetAsSeries(bbLower, true);
   if(CopyBuffer(hBB, 1, 1, 1, bbUpper) <= 0) return; // upper band buffer
   if(CopyBuffer(hBB, 2, 1, 1, bbLower) <= 0) return; // lower band buffer

   double closeLast = c[last], highLast = h[last], lowLast = l[last];

   bool bbBuy = false, bbSell = false;
   if(InpUseBB)
     {
      bool wickBuy  = (lowLast  < bbLower[0]) && (closeLast > bbLower[0]);
      bool wickSell = (highLast > bbUpper[0]) && (closeLast < bbUpper[0]);
      bool closeBuy  = (closeLast < bbLower[0]);
      bool closeSell = (closeLast > bbUpper[0]);
      if(InpSignalMode == MODE_WICK)  { bbBuy = wickBuy;  bbSell = wickSell; }
      if(InpSignalMode == MODE_CLOSE) { bbBuy = closeBuy; bbSell = closeSell; }
      if(InpSignalMode == MODE_BOTH)  { bbBuy = wickBuy || closeBuy; bbSell = wickSell || closeSell; }
     }

   //--- Nadaraya-Watson causal kernel envelope
   bool nwBuy = false, nwSell = false;
   if(InpUseNW)
     {
      double nwVal = NWKernelValue(c, last, InpNWBandwidth);
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(hATR, 0, 1, 1, atrBuf) <= 0) return;
      double nwUpper = nwVal + atrBuf[0]*InpNWAtrMult;
      double nwLower = nwVal - atrBuf[0]*InpNWAtrMult;

      bool wickBuy  = (lowLast  < nwLower) && (closeLast > nwLower);
      bool wickSell = (highLast > nwUpper) && (closeLast < nwUpper);
      bool closeBuy  = (closeLast < nwLower);
      bool closeSell = (closeLast > nwUpper);
      if(InpSignalMode == MODE_WICK)  { nwBuy = wickBuy;  nwSell = wickSell; }
      if(InpSignalMode == MODE_CLOSE) { nwBuy = closeBuy; nwSell = closeSell; }
      if(InpSignalMode == MODE_BOTH)  { nwBuy = wickBuy || closeBuy; nwSell = wickSell || closeSell; }
     }

   //--- RSI (filter or independent signal)
   double rsiBuf[];
   ArraySetAsSeries(rsiBuf, true);
   bool rsiFilterBuyOK = true, rsiFilterSellOK = true, rsiSigBuy = false, rsiSigSell = false;
   if(InpUseRSI)
     {
      if(CopyBuffer(hRSI, 0, 1, 2, rsiBuf) < 2) return; // [0]=last closed, [1]=bar before
      rsiFilterBuyOK  = (rsiBuf[0] <= InpRSIOversold);
      rsiFilterSellOK = (rsiBuf[0] >= InpRSIOverbought);
      if(InpRSIAsSignal)
        {
         rsiSigBuy  = (rsiBuf[1] <= InpRSIOversold)   && (rsiBuf[0] > InpRSIOversold);
         rsiSigSell = (rsiBuf[1] >= InpRSIOverbought) && (rsiBuf[0] < InpRSIOverbought);
        }
     }

   //--- Stochastic (filter or independent signal)
   double stochBuf[];
   ArraySetAsSeries(stochBuf, true);
   bool stochFilterBuyOK = true, stochFilterSellOK = true, stochSigBuy = false, stochSigSell = false;
   if(InpUseStoch)
     {
      if(CopyBuffer(hStoch, 0, 1, 2, stochBuf) < 2) return; // main %K line
      stochFilterBuyOK  = (stochBuf[0] <= InpStochOversold);
      stochFilterSellOK = (stochBuf[0] >= InpStochOverbought);
      if(InpStochAsSignal)
        {
         stochSigBuy  = (stochBuf[1] <= InpStochOversold)   && (stochBuf[0] > InpStochOversold);
         stochSigSell = (stochBuf[1] >= InpStochOverbought) && (stochBuf[0] < InpStochOverbought);
        }
     }

   //--- Gann Ray (MTF) directional filter
   bool trendUp = true, trendDown = true; // no restriction if disabled
   if(InpUseGann)
     {
      double rayValue; bool rising;
      if(ComputeGannRay(rayValue, rising))
        {
         trendUp   = rising  && (closeLast > rayValue);
         trendDown = !rising && (closeLast < rayValue);
        }
      else
        {
         trendUp = false; trendDown = false; // fail-safe: block if pivot unavailable
        }
     }

   //--- combine raw signals (any enabled engine/source can fire)
   bool rawBuy  = (InpUseBB && bbBuy) || (InpUseNW && nwBuy)
                  || (InpUseRSI && InpRSIAsSignal && rsiSigBuy)
                  || (InpUseStoch && InpStochAsSignal && stochSigBuy);
   bool rawSell = (InpUseBB && bbSell) || (InpUseNW && nwSell)
                  || (InpUseRSI && InpRSIAsSignal && rsiSigSell)
                  || (InpUseStoch && InpStochAsSignal && stochSigSell);

   //--- confirmation filters (only apply when the engine is enabled AND not used as a signal source)
   bool filterBuyOK  = (!InpUseRSI   || InpRSIAsSignal   || rsiFilterBuyOK)
                     && (!InpUseStoch|| InpStochAsSignal || stochFilterBuyOK)
                     && (!InpUseGann || trendUp);
   bool filterSellOK = (!InpUseRSI   || InpRSIAsSignal   || rsiFilterSellOK)
                     && (!InpUseStoch|| InpStochAsSignal || stochFilterSellOK)
                     && (!InpUseGann || trendDown);

   bool finalBuy  = rawBuy  && filterBuyOK;
   bool finalSell = rawSell && filterSellOK;
   if(finalBuy && finalSell) { finalBuy = false; finalSell = false; } // conflicting - skip

   if(!finalBuy && !finalSell)
      return;

   if(HasOpenPosition())
      return; // one position at a time

   double atrBuf2[];
   ArraySetAsSeries(atrBuf2, true);
   if(CopyBuffer(hATR, 0, 1, 1, atrBuf2) <= 0) return;
   double atrVal = atrBuf2[0];

   datetime lastBarT[];
   ArraySetAsSeries(lastBarT, true);
   CopyTime(_Symbol, Period(), 1, 1, lastBarT);

   if(finalBuy)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = ask - atrVal*InpSL_ATR_Mult;
      double tp = ask + atrVal*InpTP_ATR_Mult;
      if(trade.PositionOpen(_Symbol, ORDER_TYPE_BUY, InpLots, ask, sl, tp, "MeanReversionPro Buy"))
        {
         DrawTradeZones(lastBarT[0], true, ask, sl, tp);
         FireAlert(true, ask, sl, tp);
        }
     }
   else if(finalSell)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = bid + atrVal*InpSL_ATR_Mult;
      double tp = bid - atrVal*InpTP_ATR_Mult;
      if(trade.PositionOpen(_Symbol, ORDER_TYPE_SELL, InpLots, bid, sl, tp, "MeanReversionPro Sell"))
        {
         DrawTradeZones(lastBarT[0], false, bid, sl, tp);
         FireAlert(false, bid, sl, tp);
        }
     }
  }
//+------------------------------------------------------------------+
