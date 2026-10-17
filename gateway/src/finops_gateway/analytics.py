"""Pure quantitative helpers (no I/O) shared by the analytics services."""

from __future__ import annotations

import math

import numpy as np
import pandas as pd

TRADING_DAYS = 252


def returns(prices: pd.DataFrame | pd.Series) -> pd.DataFrame | pd.Series:
    return prices.pct_change().dropna(how="all")


def annualized_return(r: pd.Series) -> float:
    growth = float((1 + r).prod())
    return growth ** (TRADING_DAYS / max(len(r), 1)) - 1


def volatility(r: pd.Series) -> float:
    return float(r.std() * math.sqrt(TRADING_DAYS))


def sharpe(r: pd.Series, risk_free: float = 0.0) -> float | None:
    vol = volatility(r)
    return None if vol == 0 else (annualized_return(r) - risk_free) / vol


def beta(r: pd.Series, market: pd.Series) -> float | None:
    joined = pd.concat([r, market], axis=1, join="inner").dropna()
    if len(joined) < 20:
        return None
    var = joined.iloc[:, 1].var()
    return None if var == 0 else float(joined.cov().iloc[0, 1] / var)


def historical_var(r: pd.Series, level: float = 0.95) -> float:
    """One-day historical Value-at-Risk as a positive loss fraction."""
    return float(-np.percentile(r.dropna(), (1 - level) * 100))


def max_drawdown(r: pd.Series) -> float:
    wealth = (1 + r).cumprod()
    return float((wealth / wealth.cummax() - 1).min())


def dcf(fcf: float, growth: float, wacc: float, terminal_growth: float, years: int = 5) -> tuple[float, list[float]]:
    """Enterprise value from a base free cash flow growing at `growth` for `years`, then Gordon growth."""
    if wacc <= terminal_growth:
        raise ValueError("WACC must exceed terminal growth")
    flows = [fcf * (1 + growth) ** t for t in range(1, years + 1)]
    pv = sum(f / (1 + wacc) ** t for t, f in enumerate(flows, start=1))
    terminal = flows[-1] * (1 + terminal_growth) / (wacc - terminal_growth)
    return pv + terminal / (1 + wacc) ** years, flows


# A compact finance-oriented sentiment lexicon (Loughran–McDonald style), applied to headlines.
POSITIVE = set("""beat beats surge surges soar soars jump jumps rally rallies gain gains record upgrade upgraded
outperform strong stronger growth grows profit profitable boost boosts rise rises raised raises bullish buy
breakthrough win wins expands expansion exceeds tops optimistic rebound recovers recovery higher positive""".split())
NEGATIVE = set("""miss misses plunge plunges slump slumps fall falls drop drops decline declines loss losses
downgrade downgraded underperform weak weaker cut cuts lawsuit probe investigation recall bearish sell warning
warns layoffs fraud default crash crashes lower negative risk risks concern concerns slowdown tumble tumbles""".split())


def headline_sentiment(text: str) -> float:
    words = [w.strip(".,:;!?'\"()").lower() for w in text.split()]
    pos = sum(w in POSITIVE for w in words)
    neg = sum(w in NEGATIVE for w in words)
    return 0.0 if pos == neg == 0 else (pos - neg) / (pos + neg)
