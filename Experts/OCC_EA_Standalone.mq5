//+------------------------------------------------------------------+
//|                                       OCC_EA_Standalone.mq5      |
//|  Self-contained Expert Advisor implementing the Open-Close Cross |
//|  (OCC) strategy. Unlike OCC_EA.mq5, this version does NOT depend |
//|  on the separate OCC_Alert.mq5 indicator / iCustom() at all -    |
//|  the OCC line is computed internally every bar. This avoids the  |
//|  "indicator file read error" / version-sync issues that iCustom  |
//|  can hit in the Strategy Tester when the indicator .ex5 is       |
//|  missing, stale, or out of sync with the EA.                     |
//|                                                                    |
//|  Visual representation on the chart is built directly into the   |
//|  EA (no indicator subwindow needed):                              |
//|   - a live label (top-left) showing the current OCC value + trend|
//|   - up/down arrow markers on bars where a Buy/Sell was triggered  |
//|                                                                    |
//|  Trading rules (same as OCC_EA.mq5):                              |
//|   BUY : OCC line below 0. On candle close, if current closed-bar  |
//|         OCC value > previous closed-bar OCC value -> go long.     |
//|   SELL: OCC line above 0. On candle close, if current closed-bar  |
//|         OCC value < previous closed-bar OCC value -> go short.    |
//|   SL  : placed InpSlBufferPoints points beyond entry, on the side |
//|         appropriate to trade direction.                            |
//|   Trailing (optional, InpTrailEnabled): trail SL by the buffer    |
//|         distance once price has moved InpTrailPips in favor, in   |
//|         InpTrailPips increments.                                   |
//|   If trailing is disabled, exit only on an opposite OCC signal.    |
//+------------------------------------------------------------------+
#property copyright "Custom EA - standalone (no indicator dependency)"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

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

//--- OCC line calculation params
input bool             InpUseAltTF     = true;             // Use Alternate (higher) Timeframe?
input ENUM_TIMEFRAMES  InpAltTF        = PERIOD_H1;         // Alternate Timeframe (if enabled)
input ENUM_MA_TYPE     InpMAType       = MA_SMMA;           // MA Type
input int              InpMAPeriod     = 8;                 // MA Period
input int              InpOffsetSigma  = 6;                 // Offset for LSMA / Sigma for ALMA
input double           InpOffsetALMA   = 0.85;              // Offset for ALMA
input int              InpDelayOffset  = 0;                 // Delay Open/Close source (bars)

//--- trading params
input double           InpLots           = 0.10;            // Trade volume (lots)
input int              InpSlBufferPoints = 200;              // SL buffer, points beyond entry
input bool              InpTrailEnabled   = true;             // Enable SL trailing (else exit on reversal only)
input double            InpTrailPips      = 15;               // Trail step, in pips
input ulong             InpMagic          = 20260819;         // Magic number
input int               InpSlippage       = 30;               // Max slippage, points

//--- visual params
input bool              InpShowLabel      = true;              // Show live OCC value label on chart
input bool              InpShowMarkers    = true;               // Show Buy/Sell signal arrows on chart

CTrade trade;
datetime lastBarTime = 0;
string   labelName  = "OCC_EA_Label";

//+------------------------------------------------------------------+
//| Generic MA computation over a price array (index 0 = oldest)     |
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
//| Compute OCC (pcd) values for the last N chart bars.               |
//| Returns arrays occVal[] / occTime[] aligned oldest->newest,       |
//| covering 'chartBarsNeeded' most recent closed bars.                |
//+------------------------------------------------------------------+
bool ComputeOCC(const int chartBarsNeeded, double &occVal[], datetime &occTime[])
  {
   ENUM_TIMEFRAMES srcTF = InpUseAltTF ? InpAltTF : Period();
   if(InpUseAltTF && PeriodSeconds(srcTF) < PeriodSeconds(Period()))
      srcTF = Period();

   // enough source-TF bars to cover the requested chart bars, plus MA warm-up
   int ratio = MathMax(1, (int)(PeriodSeconds(srcTF) / PeriodSeconds(Period())));
   int srcBarsNeeded = chartBarsNeeded / MathMax(1, ratio) + InpMAPeriod*6 + 50;
   int availSrc = Bars(_Symbol, srcTF);
   if(availSrc < InpMAPeriod + 5)
      return(false);
   srcBarsNeeded = MathMin(srcBarsNeeded, availSrc);
   srcBarsNeeded = MathMin(srcBarsNeeded, 5000);

   double srcClose[], srcOpen[];
   datetime srcTimes[];
   ArraySetAsSeries(srcClose, false);
   ArraySetAsSeries(srcOpen,  false);
   ArraySetAsSeries(srcTimes, false);
   if(CopyClose(_Symbol, srcTF, 0, srcBarsNeeded, srcClose) <= 0) return(false);
   if(CopyOpen (_Symbol, srcTF, 0, srcBarsNeeded, srcOpen)  <= 0) return(false);
   if(CopyTime (_Symbol, srcTF, 0, srcBarsNeeded, srcTimes) <= 0) return(false);

   if(InpDelayOffset > 0)
     {
      for(int i = ArraySize(srcClose)-1; i >= InpDelayOffset; i--)
        {
         srcClose[i] = srcClose[i-InpDelayOffset];
         srcOpen[i]  = srcOpen[i-InpDelayOffset];
        }
     }

   double maClose[], maOpen[];
   ComputeMA(InpMAType, srcClose, InpMAPeriod, InpOffsetSigma, InpOffsetALMA, maClose);
   ComputeMA(InpMAType, srcOpen,  InpMAPeriod, InpOffsetSigma, InpOffsetALMA, maOpen);

   int srcTotal = ArraySize(srcTimes);

   double chClose[], chOpen[];
   datetime chTimes[];
   ArraySetAsSeries(chClose, false);
   ArraySetAsSeries(chTimes, false);
   int chBars = MathMin(chartBarsNeeded, Bars(_Symbol, Period()));
   if(CopyTime(_Symbol, Period(), 0, chBars, chTimes) <= 0) return(false);

   ArrayResize(occVal,  chBars);
   ArrayResize(occTime, chBars);

   int srcIdx = 0;
   for(int i = 0; i < chBars; i++)
     {
      while(srcIdx + 1 < srcTotal && srcTimes[srcIdx+1] <= chTimes[i])
         srcIdx++;

      double cs = maClose[srcIdx];
      double os = maOpen[srcIdx];
      double avg = (cs + os) / 2.0;
      double diff = cs - os;
      occVal[i]  = (avg != 0.0) ? 50000.0 * diff / avg : 0.0;
      occTime[i] = chTimes[i];
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
   ObjectsDeleteAll(0, "OCC_EA_sig_");
  }

void UpdateLabel(double pcd1, double pcd2)
  {
   if(!InpShowLabel) return;
   bool below = pcd1 < 0.0;
   bool rising = pcd1 > pcd2;
   color clr = below ? (rising ? clrLime : clrOrange) : (rising ? clrOrange : clrRed);
   string txt = StringFormat("OCC: %.2f  [%s zero, %s]", pcd1,
                              below ? "below" : "above",
                              rising ? "rising" : "falling");
   ObjectSetString(0, labelName, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, labelName, OBJPROP_COLOR, clr);
  }

void DrawSignalMarker(datetime t, bool isBuy)
  {
   if(!InpShowMarkers) return;
   string name = "OCC_EA_sig_" + TimeToString(t, TIME_DATE|TIME_SECONDS) + (isBuy ? "_B" : "_S");
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
   trade.PositionOpen(_Symbol, ORDER_TYPE_BUY, InpLots, ask, sl, 0.0, "OCC EA Buy");
  }

void OpenSell()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double sl = bid + InpSlBufferPoints*point;
   trade.PositionOpen(_Symbol, ORDER_TYPE_SELL, InpLots, bid, sl, 0.0, "OCC EA Sell");
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

   double occVal[];
   datetime occTime[];
   // only need a small recent window for signal + label purposes
   if(!ComputeOCC(10, occVal, occTime))
      return;

   int n = ArraySize(occVal);
   if(n < 2)
      return;

   double pcd1 = occVal[n-1]; // last closed bar (index 1 in MT5 series terms)
   double pcd2 = occVal[n-2]; // bar before that

   UpdateLabel(pcd1, pcd2);

   bool buySignal  = (pcd1 < 0.0) && (pcd1 > pcd2);
   bool sellSignal = (pcd1 > 0.0) && (pcd1 < pcd2);

   if(buySignal)  DrawSignalMarker(occTime[n-1], true);
   if(sellSignal) DrawSignalMarker(occTime[n-1], false);

   ENUM_POSITION_TYPE posType;
   bool hasPos = HasOpenPosition(posType);

   if(hasPos)
     {
      if(!InpTrailEnabled)
        {
         if(posType == POSITION_TYPE_BUY && sellSignal)
           {
            ClosePosition();
            hasPos = false;
           }
         else if(posType == POSITION_TYPE_SELL && buySignal)
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
