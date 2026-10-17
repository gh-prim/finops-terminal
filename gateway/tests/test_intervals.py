import pandas as pd

from finops_gateway.providers.yahoo import _four_hour, clamp_range


def test_clamp_range_to_yahoo_limits() -> None:
    assert clamp_range("1Y", "1MIN") == "5D"
    assert clamp_range("1D", "1MIN") == "1D"
    assert clamp_range("6M", "15MIN") == "1M"
    assert clamp_range("5Y", "1H") == "1Y"
    assert clamp_range("MAX", "1DAY") == "MAX"


def test_four_hour_groups_four_bars_per_day() -> None:
    idx = pd.date_range("2026-10-15 09:30", periods=7, freq="h", tz="America/New_York")
    df = pd.DataFrame({"Open": range(7), "High": range(10, 17), "Low": range(-7, 0), "Close": range(1, 8), "Volume": [1] * 7}, index=idx)
    out = _four_hour(df)
    assert len(out) == 2
    first = out.iloc[0]
    assert (first.Open, first.High, first.Low, first.Close, first.Volume) == (0, 13, -7, 4, 4)
    assert out.index[0] == idx[0]
