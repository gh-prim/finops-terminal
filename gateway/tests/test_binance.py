import pytest

from finops_gateway.providers import binance
from finops_gateway.providers.binance_stream import apply_trade
from finops_gateway.securities import resolve


def ticker(symbol: str, last: float, open_: float, qvol: float) -> dict:
    return {"symbol": symbol, "lastPrice": str(last), "openPrice": str(open_), "highPrice": str(last * 1.01),
            "lowPrice": str(open_ * 0.99), "volume": "10", "quoteVolume": str(qvol),
            "priceChangePercent": str((last / open_ - 1) * 100), "weightedAvgPrice": str(last),
            "closeTime": 1_700_000_000_000, "count": 5}


@pytest.fixture
def tickers(monkeypatch: pytest.MonkeyPatch) -> None:
    data = [ticker("BTCUSDT", 110.0, 100.0, 9e9), ticker("ETHUSDT", 95.0, 100.0, 5e9),
            ticker("USDCUSDT", 1.0, 1.0, 8e9), ticker("BTCUPUSDT", 2.0, 1.0, 1e6), ticker("BTCEUR", 95.0, 90.0, 1e8),
            ticker("EURUSDT", 1.1, 1.1, 1e8)]
    monkeypatch.setattr(binance, "_tickers", lambda: data)


def test_quote_uses_24h_open_as_previous_close() -> None:
    q = binance.quote_from_ticker(ticker("BTCUSDT", 110.0, 100.0, 1.0))
    assert q["previousClose"] == 100.0
    assert q["changePct"] == pytest.approx(10.0)
    assert q["currency"] == "USDT" and q["exchange"] == "Binance"


def test_trade_moves_last_and_range() -> None:
    q = binance.quote_from_ticker(ticker("BTCUSDT", 110.0, 100.0, 1.0))
    moved = apply_trade(q, {"p": "120", "T": 1_700_000_001_000})
    assert moved["last"] == 120.0 and moved["dayHigh"] == 120.0
    assert moved["changePct"] == pytest.approx(20.0)
    assert moved["asOf"] == 1_700_000_001.0


def test_market_skips_stablecoins_and_leveraged_tokens(tickers: None) -> None:
    doc = binance.market("USDT")
    pairs = next(b for b in doc["blocks"] if b.get("id") == "pairs")
    assert [r["cells"][0] for r in pairs["rows"]] == ["BTC", "ETH"]
    assert pairs["rows"][0]["cmd"] == "BTC CRYPTO"
    assert doc["refresh"] == 10


def test_lookup_returns_terminal_forms(tickers: None) -> None:
    hits = binance.lookup("btc")
    assert [h["symbol"] for h in hits[:2]] == ["BTC CRYPTO", "BTC EUR CRYPTO"]
    assert resolve(hits[1]["symbol"]).symbol == "BTCEUR"


def test_yahoo_fallback_symbol() -> None:
    assert resolve("BTC CRYPTO").yahoo_symbol == "BTC-USD"
    assert resolve("ETH EUR CRYPTO").yahoo_symbol == "ETH-EUR"
    assert resolve("BTC CRYPTO").provider == "binance"
