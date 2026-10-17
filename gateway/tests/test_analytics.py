import math

import numpy as np
import pandas as pd
import pytest

from finops_gateway import analytics as a


def test_beta_and_correlation_of_scaled_series() -> None:
    rng = np.random.default_rng(0)
    market = pd.Series(rng.normal(0, 0.01, 500))
    stock = market * 1.5
    assert a.beta(stock, market) == pytest.approx(1.5)


def test_var_and_drawdown() -> None:
    r = pd.Series([0.01] * 90 + [-0.05] * 10)
    assert a.historical_var(r, 0.95) == pytest.approx(0.05)
    assert a.max_drawdown(pd.Series([0.1, -0.5, 0.2])) == pytest.approx(-0.5)


def test_sharpe_zero_vol_is_none() -> None:
    assert a.sharpe(pd.Series([0.0] * 10)) is None


def test_dcf_matches_closed_form() -> None:
    ev, flows = a.dcf(100, growth=0.0, wacc=0.1, terminal_growth=0.0, years=5)
    assert flows == [100] * 5
    assert ev == pytest.approx(1000)  # perpetuity of 100 at 10%
    with pytest.raises(ValueError):
        a.dcf(100, 0.05, 0.03, 0.04)


def test_headline_sentiment() -> None:
    assert a.headline_sentiment("Apple beats estimates, shares surge") > 0
    assert a.headline_sentiment("Tesla shares plunge after recall") < 0
    assert a.headline_sentiment("Apple announces event") == 0
