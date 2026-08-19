//+------------------------------------------------------------------+
//|                                              OCC_Alert.mq5       |
//|  Open-Close Cross Alert (R6.2) - ported from Pine Script         |
//|  Original Pine: "Open Close Cross Alert R6.2" by JayRogers /     |
//|  JustUncleL. This MQL5 port reproduces the core OCC line         |
//|  (Open/Close moving-average difference factor) used to drive     |
//|  the companion OCC_EA.mq5 Expert Advisor, plus a visual plot     |
//|  on the MT5 chart (separate sub-window, colored line + alert     |
//|  markers). Divergence detection from the original script is      |
//|  not ported since the trading rules only require the OCC line.   |
//+------------------------------------------------------------------+
#property copyright "Ported for MT5 EA use"
#property version   "1.00"
#property indicator_separate_window
#property indicator_buffers 4
#property indicator_plots   2

#property indicator_label1  "OCC Line"
#property indicator_type1   DRAW_COLOR_LINE
#property indicator_color1  clrLimeGreen, clrRed
#property indicator_width1  2
#property indicator_style1  STYLE_SOLID

#property indicator_label2  "OCC Alert"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrDodgerBlue
#property indicator_width2  1

#property indicator_level1  0.0
#property indicator_levelstyle STYLE_DASH
#property indicator_levelcolor clrGray

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

input bool           InpUseAltTF      = true;              // Use Alternate (higher) Timeframe?
input ENUM_TIMEFRAMES InpAltTF        = PERIOD_H1;          // Alternate Timeframe (if enabled)
input ENUM_MA_TYPE   InpMAType        = MA_SMMA;            // MA Type
input int            InpMAPeriod      = 8;                  // MA Period
input int            InpOffsetSigma   = 6;                  // Offset for LSMA / Sigma for ALMA
input double         InpOffsetALMA    = 0.85;               // Offset for ALMA
input int            InpDelayOffset   = 0;                  // Delay Open/Close source (bars)

double PcdBuffer[];
double PcdColor[];
double AlertBuffer[];
double AlertColor[];

int OnInit()
  {
   SetIndexBuffer(0, PcdBuffer,   INDICATOR_DATA);
   SetIndexBuffer(1, PcdColor,    INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2, AlertBuffer, INDICATOR_DATA);
   SetIndexBuffer(3, AlertColor,  INDICATOR_COLOR_INDEX);

   PlotIndexSetInteger(1, PLOT_ARROW, 159); // circle
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   IndicatorSetString(INDICATOR_SHORTNAME, "OCC Alert R6.2");
   return(INIT_SUCCEEDED);
  }

//--- generic MA computation over a price array (index 0 = oldest)
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
            // linear regression forecast (offset = offSig bars back subtracted, Pine linreg default offset 0 uses endpoint)
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

int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                 const double &open[], const double &high[], const double &low[], const double &close[],
                 const long &tick_volume[], const long &volume[], const int &spread[])
  {
   if(rates_total < InpMAPeriod + 5)
      return(0);

   ENUM_TIMEFRAMES srcTF = InpUseAltTF ? InpAltTF : Period();
   int srcTFmin = PeriodSeconds(srcTF);
   int curTFmin = PeriodSeconds(Period());
   if(InpUseAltTF && srcTFmin < curTFmin)
      srcTF = Period(); // never go lower than chart TF

   int srcBars = Bars(_Symbol, srcTF);
   if(srcBars < InpMAPeriod + 5)
      return(0);
   srcBars = MathMin(srcBars, 5000);

   double srcClose[], srcOpen[];
   ArraySetAsSeries(srcClose, false);
   ArraySetAsSeries(srcOpen,  false);
   if(CopyClose(_Symbol, srcTF, 0, srcBars, srcClose) <= 0) return(0);
   if(CopyOpen (_Symbol, srcTF, 0, srcBars, srcOpen)  <= 0) return(0);

   // apply delay offset (shift source series back by N bars)
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

   datetime srcTimes[];
   ArraySetAsSeries(srcTimes, false);
   CopyTime(_Symbol, srcTF, 0, srcBars, srcTimes);

   for(int i = 0; i < rates_total; i++)
     {
      // find the source-TF bar that covers this chart bar's time (map higher TF value onto chart bars)
      int srcIdx = -1;
      for(int j = ArraySize(srcTimes)-1; j >= 0; j--)
        {
         if(srcTimes[j] <= time[i]) { srcIdx = j; break; }
        }
      if(srcIdx < 0) { PcdBuffer[i] = EMPTY_VALUE; AlertBuffer[i] = EMPTY_VALUE; continue; }

      double cs = maClose[srcIdx];
      double os = maOpen[srcIdx];
      double avg = (cs + os) / 2.0;
      double diff = cs - os;
      double pcd = (avg != 0.0) ? 50000.0 * diff / avg : 0.0;

      PcdBuffer[i] = pcd;
      bool up = (cs > os);
      PcdColor[i] = up ? 0 : 1;

      bool xlong  = false, xshort = false;
      if(i > 0 && srcIdx > 0)
        {
         double csPrev = maClose[srcIdx-1];
         double osPrev = maOpen[srcIdx-1];
         xlong  = (csPrev <= osPrev) && (cs > os);
         xshort = (csPrev >= osPrev) && (cs < os);
        }
      if(xlong || xshort)
        {
         AlertBuffer[i] = pcd;
         AlertColor[i] = 0;
        }
      else
         AlertBuffer[i] = EMPTY_VALUE;
     }

   return(rates_total);
  }
//+------------------------------------------------------------------+
