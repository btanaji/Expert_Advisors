//+------------------------------------------------------------------+
//|                                                    OCC_EA.mq5    |
//|  Expert Advisor built on the OCC Alert (Open-Close Cross) line   |
//|  from Indicators/OCC_Alert.mq5. Also attaches that indicator to  |
//|  the chart on init for visual representation.                    |
//|                                                                    |
//|  Rules:                                                            |
//|   BUY : OCC line below 0. On candle close, if current closed-bar  |
//|         OCC value > previous closed-bar OCC value -> go long.     |
//|   SELL: OCC line above 0. On candle close, if current closed-bar  |
//|         OCC value < previous closed-bar OCC value -> go short.    |
//|   SL  : placed beyond entry by InpSlBufferPoints (points), on the |
//|         side appropriate to the trade direction.                  |
//|   Trailing (optional, InpTrailEnabled): once price has moved      |
//|         InpTrailPips in favor of the trade (in additional         |
//|         InpTrailPips increments), SL is trailed by the same       |
//|         buffer distance behind price.                             |
//|   If trailing is disabled, the only exit is an opposite (reversal)|
//|         OCC signal, which closes the open position.               |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
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

//--- indicator params (must mirror OCC_Alert.mq5 inputs)
input bool            InpUseAltTF     = true;             // Use Alternate (higher) Timeframe?
input ENUM_TIMEFRAMES InpAltTF        = PERIOD_H1;         // Alternate Timeframe (if enabled)
input ENUM_MA_TYPE    InpMAType       = MA_SMMA;           // MA Type
input int             InpMAPeriod     = 8;                 // MA Period
input int             InpOffsetSigma  = 6;                 // Offset for LSMA / Sigma for ALMA
input double          InpOffsetALMA   = 0.85;              // Offset for ALMA
input int             InpDelayOffset  = 0;                 // Delay Open/Close source (bars)

//--- trading params
input double          InpLots           = 0.10;            // Trade volume (lots)
input int              InpSlBufferPoints = 200;             // SL buffer, points beyond entry
input bool             InpTrailEnabled   = true;            // Enable SL trailing (else exit on reversal only)
input double           InpTrailPips      = 15;              // Trail step, in pips
input ulong            InpMagic          = 20260819;        // Magic number
input int              InpSlippage       = 30;              // Max slippage, points

CTrade trade;
int    handleOCC = INVALID_HANDLE;
datetime lastBarTime = 0;

double PipSize()
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return (digits == 3 || digits == 5) ? point*10 : point;
  }

int OnInit()
  {
   handleOCC = iCustom(_Symbol, Period(), "OCC_Alert",
                        InpUseAltTF, InpAltTF, InpMAType, InpMAPeriod,
                        InpOffsetSigma, InpOffsetALMA, InpDelayOffset);
   if(handleOCC == INVALID_HANDLE)
     {
      Print("Failed to create OCC_Alert indicator handle, error=", GetLastError());
      return(INIT_FAILED);
     }
   //--- attach indicator to chart for visual representation
   ChartIndicatorAdd(0, 0, handleOCC);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(handleOCC != INVALID_HANDLE)
      IndicatorRelease(handleOCC);
  }

bool GetOccValues(double &pcd1, double &pcd2)
  {
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handleOCC, 0, 1, 2, buf) < 2)
      return(false);
   pcd1 = buf[0]; // last closed bar
   pcd2 = buf[1]; // bar before that
   return(true);
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
         double newSL = bid - bufDist;
         // move SL only forward, and only in trailDist increments
         double steps = MathFloor(profit / trailDist);
         newSL = openPrice + steps*trailDist - bufDist;
         if(newSL > curSL + point) // avoid micro-updates
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

   double pcd1, pcd2;
   if(!GetOccValues(pcd1, pcd2))
      return;

   bool buySignal  = (pcd1 < 0.0) && (pcd1 > pcd2);
   bool sellSignal = (pcd1 > 0.0) && (pcd1 < pcd2);

   ENUM_POSITION_TYPE posType;
   bool hasPos = HasOpenPosition(posType);

   if(hasPos)
     {
      //--- reversal exit only used when trailing is disabled
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
