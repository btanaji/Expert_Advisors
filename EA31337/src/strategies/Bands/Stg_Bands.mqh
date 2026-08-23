/**
 * @file
 * Implements Bands strategy based on the Bollinger Bands indicator.
 */

// User input params.
INPUT_GROUP("Bands strategy: strategy params");
INPUT float Bands_LotSize = 0;                // Lot size
INPUT int Bands_SignalOpenMethod = 4;         // Signal open method (-127-127)
INPUT float Bands_SignalOpenLevel = 0.0f;     // Signal open level (-49-49)
INPUT int Bands_SignalOpenFilterMethod = 32;  // Signal open filter method (-49-49)
INPUT int Bands_SignalOpenFilterTime = 3;     // Signal open filter time (-49-49)
INPUT int Bands_SignalOpenBoostMethod = 0;    // Signal open boost method
INPUT int Bands_SignalCloseMethod = 0;        // Signal close method (-127-127)
INPUT int Bands_SignalCloseFilter = 0;        // Signal close filter (-127-127)
INPUT float Bands_SignalCloseLevel = 0.0f;    // Signal close level (-49-49)
INPUT int Bands_PriceStopMethod = 1;          // Price stop method (0-6)
INPUT float Bands_PriceStopLevel = 2;         // Price stop level
INPUT int Bands_TickFilterMethod = 32;        // Tick filter method
INPUT float Bands_MaxSpread = 4.0;            // Max spread to trade (pips)
INPUT short Bands_Shift = 0;                  // Shift (relative to the current bar, 0 - default)
INPUT float Bands_OrderCloseLoss = 80;        // Order close loss
INPUT float Bands_OrderCloseProfit = 80;      // Order close profit
INPUT int Bands_OrderCloseTime = -30;         // Order close time in mins (>0) or bars (<0)
INPUT_GROUP("Bands strategy: Bands indicator params");
INPUT int Bands_Indi_Bands_Period = 24;                                // Period
INPUT float Bands_Indi_Bands_Deviation = 1.0f;                         // Deviation
INPUT int Bands_Indi_Bands_HShift = 0;                                 // Horizontal shift
INPUT ENUM_APPLIED_PRICE Bands_Indi_Bands_Applied_Price = PRICE_OPEN;  // Applied Price
INPUT int Bands_Indi_Bands_Shift = 0;                                  // Shift

// Structs.

// Defines struct with default user strategy values.
struct Stg_Bands_Params_Defaults : StgParams {
  Stg_Bands_Params_Defaults()
      : StgParams(::Bands_SignalOpenMethod, ::Bands_SignalOpenFilterMethod, ::Bands_SignalOpenLevel,
                  ::Bands_SignalOpenBoostMethod, ::Bands_SignalCloseMethod, ::Bands_SignalCloseFilter,
                  ::Bands_SignalCloseLevel, ::Bands_PriceStopMethod, ::Bands_PriceStopLevel, ::Bands_TickFilterMethod,
                  ::Bands_MaxSpread, ::Bands_Shift) {
    Set(STRAT_PARAM_LS, Bands_LotSize);
    Set(STRAT_PARAM_OCL, Bands_OrderCloseLoss);
    Set(STRAT_PARAM_OCP, Bands_OrderCloseProfit);
    Set(STRAT_PARAM_OCT, Bands_OrderCloseTime);
    Set(STRAT_PARAM_SOFT, Bands_SignalOpenFilterTime);
  }
};

#ifdef __config__
// Loads pair specific param values.
#include "config/H1.h"
#include "config/H4.h"
#include "config/H8.h"
#include "config/M1.h"
#include "config/M15.h"
#include "config/M30.h"
#include "config/M5.h"
#endif

class Stg_Bands : public Strategy {
 public:
  Stg_Bands(StgParams &_sparams, TradeParams &_tparams, ChartParams &_cparams, string _name = "")
      : Strategy(_sparams, _tparams, _cparams, _name) {}

  static Stg_Bands *Init(ENUM_TIMEFRAMES _tf = NULL) {
    // Initialize strategy initial values.
    Stg_Bands_Params_Defaults stg_bands_defaults;
    StgParams _stg_params(stg_bands_defaults);
#ifdef __config__
    SetParamsByTf<StgParams>(_stg_params, _tf, stg_bands_m1, stg_bands_m5, stg_bands_m15, stg_bands_m30, stg_bands_h1,
                             stg_bands_h4, stg_bands_h8);
#endif
    // Initialize indicator.
    // Initialize Strategy instance.
    ChartParams _cparams(_tf, _Symbol);
    TradeParams _tparams;
    Strategy *_strat = new Stg_Bands(_stg_params, _tparams, _cparams, "Bands");
    return _strat;
  }

  /**
   * Event on strategy's init.
   */
  void OnInit() {
    IndiBandsParams _indi_params(::Bands_Indi_Bands_Period, ::Bands_Indi_Bands_Deviation, ::Bands_Indi_Bands_HShift,
                                 ::Bands_Indi_Bands_Applied_Price, ::Bands_Indi_Bands_Shift);
    _indi_params.SetTf(Get<ENUM_TIMEFRAMES>(STRAT_PARAM_TF));
    SetIndicator(new Indi_Bands(_indi_params));
  }

  /**
   * Check strategy's opening signal.
   */
  bool SignalOpen(ENUM_ORDER_TYPE _cmd, int _method = 0, float _level = 0.0f, int _shift = 0) {
    Indi_Bands *_indi = GetIndicator();
    Chart *_chart = (Chart *)_indi;
    bool _result = _indi.GetFlag(INDI_ENTRY_FLAG_IS_VALID, 0) && _indi.GetFlag(INDI_ENTRY_FLAG_IS_VALID, 1);
    if (!_result) {
      // Returns false when indicator data is not valid.
      return false;
    }
    double _change_pc = Math::ChangeInPct(_indi[1][(int)BAND_BASE], _indi[0][(int)BAND_BASE], true);
    switch (_cmd) {
      // Buy: price crossed lower line upwards (returned to it from below).
      case ORDER_TYPE_BUY: {
        // Price value was lower than the lower band.
        double lowest_price = fmin3(_chart.GetLow(CURR), _chart.GetLow(PREV), _chart.GetLow(PPREV));
        _result = (lowest_price <
                   fmax3(_indi[CURR][(int)BAND_LOWER], _indi[PREV][(int)BAND_LOWER], _indi[PPREV][(int)BAND_LOWER]));
        _result &= _change_pc > _level;
        if (_result && _method != 0) {
          if (METHOD(_method, 0)) _result &= fmin(Close[PREV], Close[PPREV]) < _indi[CURR][(int)BAND_LOWER];
          if (METHOD(_method, 1)) _result &= (_indi[CURR][(int)BAND_LOWER] > _indi[PPREV][(int)BAND_LOWER]);
          if (METHOD(_method, 2)) _result &= (_indi[CURR][(int)BAND_BASE] > _indi[PPREV][(int)BAND_BASE]);
          if (METHOD(_method, 3)) _result &= (_indi[CURR][(int)BAND_UPPER] > _indi[PPREV][(int)BAND_UPPER]);
          if (METHOD(_method, 4)) _result &= lowest_price < _indi[CURR][(int)BAND_BASE];
          if (METHOD(_method, 5)) _result &= Open[CURR] < _indi[CURR][(int)BAND_BASE];
          if (METHOD(_method, 6)) _result &= fmin(Close[PREV], Close[PPREV]) > _indi[CURR][(int)BAND_BASE];
        }
        break;
      }
      // Sell: price crossed upper line downwards (returned to it from above).
      case ORDER_TYPE_SELL: {
        // Price value was higher than the upper band.
        double highest_price = fmin3(_chart.GetHigh(CURR), _chart.GetHigh(PREV), _chart.GetHigh(PPREV));
        _result = (highest_price >
                   fmin3(_indi[CURR][(int)BAND_UPPER], _indi[PREV][(int)BAND_UPPER], _indi[PPREV][(int)BAND_UPPER]));
        _result &= _change_pc < -_level;
        if (_result && _method != 0) {
          if (METHOD(_method, 0)) _result &= fmin(Close[PREV], Close[PPREV]) > _indi[CURR][(int)BAND_UPPER];
          if (METHOD(_method, 1)) _result &= (_indi[CURR][(int)BAND_LOWER] < _indi[PPREV][(int)BAND_LOWER]);
          if (METHOD(_method, 2)) _result &= (_indi[CURR][(int)BAND_BASE] < _indi[PPREV][(int)BAND_BASE]);
          if (METHOD(_method, 3)) _result &= (_indi[CURR][(int)BAND_UPPER] < _indi[PPREV][(int)BAND_UPPER]);
          if (METHOD(_method, 4)) _result &= highest_price > _indi[CURR][(int)BAND_BASE];
          if (METHOD(_method, 5)) _result &= Open[CURR] > _indi[CURR][(int)BAND_BASE];
          if (METHOD(_method, 6)) _result &= fmin(Close[PREV], Close[PPREV]) < _indi[CURR][(int)BAND_BASE];
        }
        break;
      }
    }
    return _result;
  }
};
