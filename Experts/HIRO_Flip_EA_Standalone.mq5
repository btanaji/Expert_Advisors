//+------------------------------------------------------------------+
//|                                 HIRO_Flip_EA_Standalone.mq5      |
//|  Self-contained Expert Advisor based on the "AP Capital - HIRO   |
//|  Proxy (Flow Pressure)" Pine Script indicator (v6). No iCustom / |
//|  external indicator dependency - the HIRO pseudo-candle series   |
//|  (z-score of smoothed, ATR-filtered, volume-weighted directional |
//|  pressure) is computed internally each bar, and the OCC line     |
//|  (from the earlier Open-Close-Cross strategy) used as an OPTIONAL|
//|  trend filter is also computed internally, in this same file.    |
//|  Nothing here depends on OCC_Alert.mq5 / OCC_EA*.mq5.            |
//|                                                                    |
//|  Entry rules:                                                     |
//|   BUY : the HIRO pseudo-candle flips from red to green            |
//|         (previous closed bar bearish, current closed bar bullish).|
//|   SELL: the HIRO pseudo-candle flips from green to red.           |
//|                                                                    |
//|  Optional trend filter (InpUseTrendFilter):                       |
//|   When enabled, trades are only taken in the direction allowed by |
//|   the OCC line: OCC above zero (green/uptrend) -> only BUY;       |
//|   OCC below zero (red/downtrend) -> only SELL.                    |
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
//|  the current HIRO z-value / candle color / trend-filter state,    |
//|  and up/down arrow markers on bars where a Buy/Sell was triggered.|
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
// Optional trend filter - OCC line (Open/Close Cross), computed
// internally, no dependency on OCC_Alert.mq5 / OCC_EA*.mq5
//====================================================================
enum ENUM_MA_TYPE
  {
   MA_SMA = 0,
   MA_EMA,
   MA_DEMA,
   MA_TEMA,
   MA_LWMA,
   MA_SMMA,
   MA_HULL,
   MA_LSMA,
   MA_ALMA,
   MA_SSMA,
   MA_TMA
  };

input bool             InpUseTrendFilter = false;          // Use OCC trend filter? (OCC>0 = buy only, OCC<0 = sell only)
input bool             InpOccUseAltTF    = true;            // OCC: Use Alternate (higher) Timeframe?
input ENUM_TIMEFRAMES  InpOccAltTF       = PERIOD_H1;        // OCC: Alternate Timeframe
input ENUM_MA_TYPE     InpOccMAType      = MA_SMMA;          // OCC: MA Type
input int               InpOccMAPeriod    = 8;                // OCC: MA Period
input int               InpOccOffsetSigma = 6;                // OCC: Offset for LSMA / Sigma for ALMA
input double            InpOccOffsetALMA  = 0.85;             // OCC: Offset for ALMA
input int               InpOccDelayOffset = 0;                // OCC: Delay Open/Close source (bars)

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
//| Generic MA computation (used only for the optional OCC filter)   |
//| over a price array (index 0 = oldest)                             |
//+------------------------------------------------------------------+
void ComputeMA(const ENUM_MA_TYPE type, const double &price[], const int period,
                const int offSig, const double offALMA, double &out[])
  {
   int total = ArraySize(price);
   ArrayResize(out, total);
   ArrayInitialize(out, 0.0);
   if(total == 0 || period <= 0)
      return;

   switch(type)
     {
      case MA_SMA:
        {
         for(int i = 0; i < total; i++)
           {
            if(i < period - 1) { out[i] = price[i]; continue; }
            double s = 0;
            for(int k = i - period + 1; k <= i; k++) s += price[k];
            out[i] = s / period;
           }
         break;
        }
      case MA_EMA:
        {
         double k = 2.0 / (period + 1.0);
         for(int i = 0; i < total; i++)
            out[i] = (i == 0) ? price[i] : price[i]*k + out[i-1]*(1-k);
         break;
        }
      case MA_SMMA:
        {
         for(int i = 0; i < total; i++)
           {
            if(i == 0) { out[i] = price[i]; continue; }
            out[i] = (out[i-1]*(period-1) + price[i]) / period;
           }
         break;
        }
      case MA_LWMA:
        {
         for(int i = 0; i < total; i++)
           {
            if(i < period - 1) { out[i] = price[i]; continue; }
            double s = 0, wsum = 0;
            for(int k = 0; k < period; k++)
              {
               double w = (period - k);
               s += price[i-k]*w;
               wsum += w;
              }
            out[i] = s / wsum;
           }
         break;
        }
      case MA_DEMA:
        {
         double ema1[], ema2[];
         ComputeMA(MA_EMA, price, period, offSig, offALMA, ema1);
         ComputeMA(MA_EMA, ema1,  period, offSig, offALMA, ema2);
         for(int i = 0; i < total; i++)
            out[i] = 2*ema1[i] - ema2[i];
         break;
        }
      case MA_TEMA:
        {
         double ema1[], ema2[], ema3[];
         ComputeMA(MA_EMA, price, period, offSig, offALMA, ema1);
         ComputeMA(MA_EMA, ema1,  period, offSig, offALMA, ema2);
         ComputeMA(MA_EMA, ema2,  period, offSig, offALMA, ema3);
         for(int i = 0; i < total; i++)
            out[i] = 3*(ema1[i]-ema2[i]) + ema3[i];
         break;
        }
      case MA_HULL:
        {
         int half = MathMax(1, period/2);
         int sq   = MathMax(1, (int)MathRound(MathSqrt(period)));
         double wmaHalf[], wmaFull[], diff[];
         ComputeMA(MA_LWMA, price, half,   offSig, offALMA, wmaHalf);
         ComputeMA(MA_LWMA, price, period, offSig, offALMA, wmaFull);
         ArrayResize(diff, total);
         for(int i = 0; i < total; i++)
            diff[i] = 2*wmaHalf[i] - wmaFull[i];
         ComputeMA(MA_LWMA, diff, sq, offSig, offALMA, out);
         break;
        }
      case MA_LSMA:
        {
         for(int i = 0; i < total; i++)
           {
            if(i < period - 1) { out[i] = price[i]; continue; }
            double sumX=0,sumY=0,sumXY=0,sumX2=0;
            for(int k = 0; k < period; k++)
              {
               double x = k;
               double y = price[i - period + 1 + k];
               sumX += x; sumY += y; sumXY += x*y; sumX2 += x*x;
              }
            double n = period;
            double slope = (n*sumXY - sumX*sumY) / (n*sumX2 - sumX*sumX);
            double interc = (sumY - slope*sumX)/n;
            out[i] = interc + slope*(period-1);
           }
         break;
        }
      case MA_ALMA:
        {
         double sigma = MathMax(1, offSig);
         double m = offALMA*(period-1);
         double s = period/sigma;
         for(int i = 0; i < total; i++)
           {
            if(i < period - 1) { out[i] = price[i]; continue; }
            double wsum=0, sum=0;
            for(int k = 0; k < period; k++)
              {
               double w = MathExp(-((k-m)*(k-m))/(2*s*s));
               sum  += price[i-period+1+k]*w;
               wsum += w;
              }
            out[i] = sum / wsum;
           }
         break;
        }
      case MA_SSMA:
        {
         double a1 = MathExp(-1.414*M_PI/period);
         double b1 = 2*a1*MathCos(1.414*M_PI/period);
         double c2 = b1;
         double c3 = -a1*a1;
         double c1 = 1 - c2 - c3;
         for(int i = 0; i < total; i++)
           {
            double prev1 = (i>=1) ? out[i-1] : price[i];
            double prev2 = (i>=2) ? out[i-2] : price[i];
            double srcPrev = (i>=1) ? price[i-1] : price[i];
            out[i] = c1*(price[i]+srcPrev)/2 + c2*prev1 + c3*prev2;
           }
         break;
        }
      case MA_TMA:
        {
         double sma1[];
         ComputeMA(MA_SMA, price, period, offSig, offALMA, sma1);
         ComputeMA(MA_SMA, sma1,  period, offSig, offALMA, out);
         break;
        }
      default:
         ArrayCopy(out, price);
         break;
     }
  }

//+------------------------------------------------------------------+
//| OCC (pcd) trend-filter value for the last two closed chart bars  |
//+------------------------------------------------------------------+
bool ComputeOccLastTwo(double &pcd1, double &pcd2)
  {
   ENUM_TIMEFRAMES srcTF = InpOccUseAltTF ? InpOccAltTF : Period();
   if(InpOccUseAltTF && PeriodSeconds(srcTF) < PeriodSeconds(Period()))
      srcTF = Period();

   int srcBarsNeeded = MathMin(5000, MathMax(InpOccMAPeriod*6 + 50, Bars(_Symbol, srcTF)));
   if(Bars(_Symbol, srcTF) < InpOccMAPeriod + 5)
      return(false);

   double srcClose[], srcOpen[];
   datetime srcTimes[];
   ArraySetAsSeries(srcClose, false);
   ArraySetAsSeries(srcOpen,  false);
   ArraySetAsSeries(srcTimes, false);
   if(CopyClose(_Symbol, srcTF, 0, srcBarsNeeded, srcClose) <= 0) return(false);
   if(CopyOpen (_Symbol, srcTF, 0, srcBarsNeeded, srcOpen)  <= 0) return(false);
   if(CopyTime (_Symbol, srcTF, 0, srcBarsNeeded, srcTimes) <= 0) return(false);

   if(InpOccDelayOffset > 0)
     {
      for(int i = ArraySize(srcClose)-1; i >= InpOccDelayOffset; i--)
        {
         srcClose[i] = srcClose[i-InpOccDelayOffset];
         srcOpen[i]  = srcOpen[i-InpOccDelayOffset];
        }
     }

   double maClose[], maOpen[];
   ComputeMA(InpOccMAType, srcClose, InpOccMAPeriod, InpOccOffsetSigma, InpOccOffsetALMA, maClose);
   ComputeMA(InpOccMAType, srcOpen,  InpOccMAPeriod, InpOccOffsetSigma, InpOccOffsetALMA, maOpen);

   int srcTotal = ArraySize(srcTimes);

   datetime chTimes[];
   ArraySetAsSeries(chTimes, false);
   int chBars = MathMin(10, Bars(_Symbol, Period()));
   if(CopyTime(_Symbol, Period(), 0, chBars, chTimes) <= 0) return(false);

   double occVal[];
   ArrayResize(occVal, chBars);
   int srcIdx = 0;
   for(int i = 0; i < chBars; i++)
     {
      while(srcIdx + 1 < srcTotal && srcTimes[srcIdx+1] <= chTimes[i])
         srcIdx++;
      double cs = maClose[srcIdx];
      double os = maOpen[srcIdx];
      double avg = (cs + os) / 2.0;
      double diff = cs - os;
      occVal[i] = (avg != 0.0) ? 50000.0 * diff / avg : 0.0;
     }

   if(chBars < 2) return(false);
   pcd1 = occVal[chBars-1];
   pcd2 = occVal[chBars-2];
   return(true);
  }

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

void UpdateLabel(double z, bool bull, bool trendFilterOk, double occPcd)
  {
   if(!InpShowLabel) return;
   color clr = bull ? clrTeal : clrRed;
   string txt = StringFormat("HIRO z: %.2f [%s]", z, bull ? "green" : "red");
   if(InpUseTrendFilter)
      txt += StringFormat("  | OCC: %.2f (%s) filter=%s", occPcd, occPcd>0?"up":"down", trendFilterOk?"OK":"blocked");
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

   double occPcd1 = 0.0, occPcd2 = 0.0;
   bool trendUp = true, trendDown = true; // default: no restriction
   if(InpUseTrendFilter)
     {
      if(ComputeOccLastTwo(occPcd1, occPcd2))
        {
         trendUp   = (occPcd1 > 0.0);
         trendDown = (occPcd1 < 0.0);
        }
      else
        {
         trendUp = false;
         trendDown = false; // fail-safe: block trades if filter data unavailable
        }
     }

   bool buySignal  = flipToGreen && (!InpUseTrendFilter || trendUp);
   bool sellSignal = flipToRed   && (!InpUseTrendFilter || trendDown);

   UpdateLabel(zArr[n-1], bullNow, InpUseTrendFilter ? (buySignal||sellSignal||(bullNow?trendUp:trendDown)) : true, occPcd1);

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
