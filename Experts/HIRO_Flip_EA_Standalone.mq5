//+------------------------------------------------------------------+
//|                                 HIRO_Flip_EA_Standalone.mq5      |
//|  Self-contained Expert Advisor based on the "AP Capital - HIRO   |
//|  Proxy (Flow Pressure)" Pine Script indicator (v6). No iCustom / |
//|  external indicator dependency - the HIRO pseudo-candle series   |
//|  (z-score of smoothed, ATR-filtered, volume-weighted directional |
//|  pressure) is computed internally each bar. Plain AP logic only  |
//|  - no trend filter.                                                |
//|                                                                    |
//|  Entry rules:                                                     |
//|   BUY : the HIRO pseudo-candle flips from red to green            |
//|         (previous closed bar bearish, current closed bar bullish).|
//|   SELL: the HIRO pseudo-candle flips from green to red.           |
//|                                                                    |
//|  SL: placed InpSlBufferPoints points beyond entry, on the side    |
//|      appropriate to trade direction.                               |
//|  Trailing (optional, InpTrailEnabled): trail SL by the buffer     |
//|      distance once price has moved InpTrailPips in favor, in      |
//|      InpTrailPips increments.                                      |
//|  If trailing is disabled, exit only on an opposite flip signal.    |
//|                                                                    |
//|  Visual representation is drawn directly by the EA (no separate   |
//|  indicator/sub-window needed): a live label (top-left) showing    |
//|  the current HIRO z-value / candle color, and up/down arrow        |
//|  markers on bars where a Buy/Sell was triggered.                   |
//+------------------------------------------------------------------+
#property copyright "Custom EA - standalone (no indicator dependency)"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//====================================================================
// HIRO Proxy (Flow Pressure) inputs
//====================================================================
input int    InpLenSmooth   = 14;     // Smoothing length (EMA of cumulative pressure)
input int    InpLenZ        = 200;    // Z-score lookback
input bool   InpUseLogVol   = true;   // Use log(volume) weighting
input bool   InpResetDaily  = true;   // Reset cumulative pressure each day
input double InpMinAtrMult  = 0.0;    // Min ATR filter (0 = off)
input int    InpAtrLen      = 14;     // ATR length

//====================================================================
// Trading params
//====================================================================
input double  InpLots            = 0.10;        // Trade volume (lots)
input int     InpSlBufferPoints  = 200;          // SL buffer, points beyond entry
input bool    InpTrailEnabled    = true;         // Enable SL trailing (else exit on reversal only)
input double  InpTrailPips       = 15;           // Trail step, in pips
input ulong   InpMagic           = 20260820;     // Magic number
input int     InpSlippage        = 30;           // Max slippage, points

//====================================================================
// Visual params
//====================================================================
input bool InpShowLabel   = true;   // Show live HIRO/trend label on chart
input bool InpShowMarkers = true;   // Show Buy/Sell flip arrows on chart

CTrade   trade;
datetime lastBarTime = 0;
string   labelName = "HIRO_EA_Label";

//+------------------------------------------------------------------+
//| HIRO Proxy (Flow Pressure) computation for the last N chart bars |
//| Returns bull[] (candle color, true=green) and time[] aligned      |
//| oldest -> newest.                                                  |
//+------------------------------------------------------------------+
bool ComputeHiro(const int chartBarsNeeded, bool &bullOut[], double &zOut[], datetime &timeOut[])
  {
   int lookback = MathMax(chartBarsNeeded, InpLenZ + InpLenSmooth + 50);
   lookback = MathMin(lookback, MathMin(5000, Bars(_Symbol, Period())));
   if(lookback < InpLenZ + 5)
      return(false);

   double o[], h[], l[], c[];
   long   tv[];
   datetime t[];
   ArraySetAsSeries(o, false);
   ArraySetAsSeries(h, false);
   ArraySetAsSeries(l, false);
   ArraySetAsSeries(c, false);
   ArraySetAsSeries(tv, false);
   ArraySetAsSeries(t, false);
   if(CopyOpen(_Symbol, Period(), 0, lookback, o)  <= 0) return(false);
   if(CopyHigh(_Symbol, Period(), 0, lookback, h)  <= 0) return(false);
   if(CopyLow (_Symbol, Period(), 0, lookback, l)  <= 0) return(false);
   if(CopyClose(_Symbol, Period(), 0, lookback, c) <= 0) return(false);
   if(CopyTickVolume(_Symbol, Period(), 0, lookback, tv) <= 0) return(false);
   if(CopyTime(_Symbol, Period(), 0, lookback, t)  <= 0) return(false);

   int n = ArraySize(c);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   //--- ATR (Wilder smoothed true range)
   double atr[];
   ArrayResize(atr, n);
   double trPrev = 0;
   for(int i = 0; i < n; i++)
     {
      double tr;
      if(i == 0)
         tr = h[i] - l[i];
      else
         tr = MathMax(h[i]-l[i], MathMax(MathAbs(h[i]-c[i-1]), MathAbs(l[i]-c[i-1])));
      if(i < InpAtrLen)
         atr[i] = (i==0) ? tr : (atr[i-1]*i + tr)/(i+1); // simple warm-up average
      else
         atr[i] = (atr[i-1]*(InpAtrLen-1) + tr) / InpAtrLen;
     }

   //--- raw pressure + cumulative (with optional daily reset)
   double cum[];
   ArrayResize(cum, n);
   MqlDateTime dtCur, dtPrev;
   for(int i = 0; i < n; i++)
     {
      double rng = h[i] - l[i];
      double safeRng = MathMax(rng, point);
      bool atrOk = (InpMinAtrMult <= 0.0) ? true : (rng >= atr[i]*InpMinAtrMult);
      double eff = (c[i] - o[i]) / safeRng;
      double vol = (double)tv[i];
      double vw = InpUseLogVol ? MathLog(MathMax(vol, 1.0)) : vol;
      double rawPressure = atrOk ? (eff * vw) : 0.0;

      bool newDay = false;
      if(i > 0)
        {
         TimeToStruct(t[i], dtCur);
         TimeToStruct(t[i-1], dtPrev);
         newDay = (dtCur.day != dtPrev.day || dtCur.mon != dtPrev.mon || dtCur.year != dtPrev.year);
        }

      if(i == 0)
         cum[i] = rawPressure;
      else if(InpResetDaily && newDay)
         cum[i] = rawPressure;
      else
         cum[i] = cum[i-1] + rawPressure;
     }

   //--- smooth (EMA)
   double sm[];
   ArrayResize(sm, n);
   double k = 2.0 / (InpLenSmooth + 1.0);
   for(int i = 0; i < n; i++)
      sm[i] = (i==0) ? cum[i] : cum[i]*k + sm[i-1]*(1-k);

   //--- z-score vs rolling mean/stdev of sm over InpLenZ
   double zArr[];
   ArrayResize(zArr, n);
   for(int i = 0; i < n; i++)
     {
      if(i < InpLenZ - 1) { zArr[i] = 0.0; continue; }
      double mean = 0;
      for(int j = i-InpLenZ+1; j <= i; j++) mean += sm[j];
      mean /= InpLenZ;
      double var = 0;
      for(int j = i-InpLenZ+1; j <= i; j++) var += (sm[j]-mean)*(sm[j]-mean);
      var /= InpLenZ;
      double stdev = MathSqrt(var);
      zArr[i] = (stdev == 0.0) ? 0.0 : (sm[i]-mean)/stdev;
     }

   ArrayResize(bullOut, n);
   ArrayResize(zOut, n);
   ArrayResize(timeOut, n);
   for(int i = 0; i < n; i++)
     {
      double zOpen  = (i>0) ? zArr[i-1] : 0.0;
      double zClose = zArr[i];
      bullOut[i] = (zClose >= zOpen);
      zOut[i]    = zClose;
      timeOut[i] = t[i];
     }

   return(true);
  }

int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpShowLabel)
     {
      if(ObjectFind(0, labelName) < 0)
         ObjectCreate(0, labelName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, labelName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, labelName, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, labelName, OBJPROP_YDISTANCE, 15);
      ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 10);
     }

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   ObjectDelete(0, labelName);
   ObjectsDeleteAll(0, "HIRO_EA_sig_");
  }

void UpdateLabel(double z, bool bull)
  {
   if(!InpShowLabel) return;
   color clr = bull ? clrTeal : clrRed;
   string txt = StringFormat("HIRO z: %.2f [%s]", z, bull ? "green" : "red");
   ObjectSetString(0, labelName, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, labelName, OBJPROP_COLOR, clr);
  }

void DrawSignalMarker(datetime t, bool isBuy)
  {
   if(!InpShowMarkers) return;
   string name = "HIRO_EA_sig_" + TimeToString(t, TIME_DATE|TIME_SECONDS) + (isBuy ? "_B" : "_S");
   int shift = iBarShift(_Symbol, Period(), t);
   double price = isBuy ? iLow(_Symbol, Period(), shift) : iHigh(_Symbol, Period(), shift);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   price += isBuy ? -20*point*10 : 20*point*10;

   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, isBuy ? OBJ_ARROW_UP : OBJ_ARROW_DOWN, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, isBuy ? clrLime : clrRed);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
  }

double PipSize()
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return (digits == 3 || digits == 5) ? point*10 : point;
  }

bool HasOpenPosition(ENUM_POSITION_TYPE &type)
  {
   if(!PositionSelect(_Symbol))
      return(false);
   if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
      return(false);
   type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   return(true);
  }

void OpenBuy()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double sl = ask - InpSlBufferPoints*point;
   trade.PositionOpen(_Symbol, ORDER_TYPE_BUY, InpLots, ask, sl, 0.0, "HIRO EA Buy");
  }

void OpenSell()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double sl = bid + InpSlBufferPoints*point;
   trade.PositionOpen(_Symbol, ORDER_TYPE_SELL, InpLots, bid, sl, 0.0, "HIRO EA Sell");
  }

void ClosePosition()
  {
   trade.PositionClose(_Symbol);
  }

void TrailStop()
  {
   if(!InpTrailEnabled) return;
   if(!PositionSelect(_Symbol)) return;
   if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pip   = PipSize();
   double trailDist = InpTrailPips*pip;
   double bufDist    = InpSlBufferPoints*point;

   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL      = PositionGetDouble(POSITION_SL);
   double curTP       = PositionGetDouble(POSITION_TP);

   if(type == POSITION_TYPE_BUY)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double profit = bid - openPrice;
      if(profit >= trailDist)
        {
         double steps = MathFloor(profit / trailDist);
         double newSL = openPrice + steps*trailDist - bufDist;
         if(newSL > curSL + point)
            trade.PositionModify(_Symbol, newSL, curTP);
        }
     }
   else if(type == POSITION_TYPE_SELL)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profit = openPrice - ask;
      if(profit >= trailDist)
        {
         double steps = MathFloor(profit / trailDist);
         double newSL = openPrice - steps*trailDist + bufDist;
         if(curSL == 0.0 || newSL < curSL - point)
            trade.PositionModify(_Symbol, newSL, curTP);
        }
     }
  }

bool IsNewBar()
  {
   datetime t[];
   ArraySetAsSeries(t, true);
   if(CopyTime(_Symbol, Period(), 0, 1, t) <= 0)
      return(false);
   if(t[0] != lastBarTime)
     {
      lastBarTime = t[0];
      return(true);
     }
   return(false);
  }

void OnTick()
  {
   TrailStop();

   if(!IsNewBar())
      return;

   bool bullArr[];
   double zArr[];
   datetime timeArr[];
   if(!ComputeHiro(10, bullArr, zArr, timeArr))
      return;

   int n = ArraySize(bullArr);
   if(n < 2)
      return;

   bool bullNow  = bullArr[n-1]; // last closed bar
   bool bullPrev = bullArr[n-2]; // bar before that

   bool flipToGreen = (!bullPrev && bullNow);
   bool flipToRed   = (bullPrev && !bullNow);

   bool buySignal  = flipToGreen;
   bool sellSignal = flipToRed;

   UpdateLabel(zArr[n-1], bullNow);

   if(flipToGreen) DrawSignalMarker(timeArr[n-1], true);
   if(flipToRed)   DrawSignalMarker(timeArr[n-1], false);

   ENUM_POSITION_TYPE posType;
   bool hasPos = HasOpenPosition(posType);

   if(hasPos)
     {
      if(!InpTrailEnabled)
        {
         if(posType == POSITION_TYPE_BUY && flipToRed)
           {
            ClosePosition();
            hasPos = false;
           }
         else if(posType == POSITION_TYPE_SELL && flipToGreen)
           {
            ClosePosition();
            hasPos = false;
           }
        }
     }

   if(!hasPos)
     {
      if(buySignal)
         OpenBuy();
      else if(sellSignal)
         OpenSell();
     }
  }
//+------------------------------------------------------------------+
