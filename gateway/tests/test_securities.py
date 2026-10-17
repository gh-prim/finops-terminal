import pytest

from finops_gateway.securities import resolve


@pytest.mark.parametrize(
    ("typed", "symbol"),
    [
        ("AAPL US EQ", "AAPL"),
        ("aapl eq", "AAPL"),
        ("VOD LN EQ", "VOD.L"),
        ("BRK/B US EQ", "BRK-B"),
        ("EURUSD FX", "EURUSD=X"),
        ("SPX IDX", "^GSPC"),
        ("FOO IDX", "^FOO"),
        ("CL1 CMD", "CL=F"),
        ("BTC CRYPTO", "BTC-USD"),
        ("MSFT", "MSFT"),
        ("^GSPC", "^GSPC"),
    ],
)
def test_resolve(typed: str, symbol: str) -> None:
    assert resolve(typed).symbol == symbol


@pytest.mark.parametrize("typed", ["", "AAPL XX EQ", "A B C EQ", "US10Y GOV"])
def test_resolve_rejects(typed: str) -> None:
    with pytest.raises(ValueError):
        resolve(typed)
