"""Typed security form <-> provider symbols.

Users type `<symbol> [<venue>] <class>`, e.g. `AAPL US EQ`, `VOD LN EQ`,
`EURUSD FX`, `SPX IDX`, `CL1 CMD`, `BTC CRYPTO`, `ETH EUR CRYPTO`. Anything
without a known asset-class code is passed through as a raw Yahoo symbol.
Crypto resolves to a Binance spot pair (quote currency USDT unless given).
"""

from __future__ import annotations

from dataclasses import dataclass

ASSET_CLASSES = {"EQ", "ETF", "GOV", "CORP", "FX", "CMD", "IDX", "CRYPTO", "FUT", "OPT", "ECO"}

# Venue code -> Yahoo suffix.
VENUE_SUFFIX = {
    "US": "",
    "LN": ".L",
    "FP": ".PA",
    "GY": ".DE",
    "NA": ".AS",
    "IM": ".MI",
    "SM": ".MC",
    "SW": ".SW",
    "JP": ".T",
    "HK": ".HK",
    "CN": ".TO",
    "AU": ".AX",
}

INDEX_ALIASES = {
    "SPX": "^GSPC",
    "NDX": "^NDX",
    "CCMP": "^IXIC",
    "INDU": "^DJI",
    "RTY": "^RUT",
    "VIX": "^VIX",
    "UKX": "^FTSE",
    "CAC": "^FCHI",
    "DAX": "^GDAXI",
    "SX5E": "^STOXX50E",
    "NKY": "^N225",
    "HSI": "^HSI",
    "DXY": "DX-Y.NYB",
}


# Binance quote assets, longest first so "BTCFDUSD" isn't read as "BTCF" + "DUSD".
CRYPTO_QUOTES = ("FDUSD", "USDT", "USDC", "EUR", "TRY", "BRL", "JPY", "BTC", "ETH", "BNB")


@dataclass(frozen=True)
class Security:
    typed: str
    symbol: str
    asset_class: str | None

    @property
    def provider(self) -> str:
        return "binance" if self.asset_class == "CRYPTO" else "yahoo"

    @property
    def yahoo_symbol(self) -> str:
        """Closest Yahoo symbol, for Yahoo-only screens (news, profile)."""
        if self.asset_class != "CRYPTO":
            return self.symbol
        base, quote = split_pair(self.symbol)
        return f"{base}-{'USD' if quote.startswith('USD') or quote == 'FDUSD' else quote}"


def crypto_pair(root: str, quote: str | None = None) -> str:
    """BTC -> BTCUSDT, BTC-EUR / BTC/EUR / (BTC, EUR) -> BTCEUR; full pairs pass through."""
    for sep in ("-", "/"):
        if sep in root:
            root, quote = root.split(sep, 1)
    if quote is None:
        if any(root.endswith(q) and len(root) >= len(q) + 3 for q in CRYPTO_QUOTES):
            return root
        quote = "USDT"
    return root + ("USDT" if quote == "USD" else quote)


def split_pair(pair: str) -> tuple[str, str]:
    for q in CRYPTO_QUOTES:
        if pair.endswith(q) and len(pair) > len(q):
            return pair[: -len(q)], q
    return pair, ""


def resolve(typed: str) -> Security:
    tokens = typed.upper().split()
    if not tokens:
        raise ValueError("empty security")

    asset_class = tokens[-1] if len(tokens) > 1 and tokens[-1] in ASSET_CLASSES else None
    if asset_class is None:
        return Security(typed=typed.upper(), symbol=tokens[0], asset_class=None)

    body = tokens[:-1]
    if len(body) > 2:
        raise ValueError(f"cannot parse security: {typed!r}")
    root = body[0]
    venue = body[1] if len(body) == 2 else None

    match asset_class:
        case "EQ" | "ETF":
            if venue is not None and venue not in VENUE_SUFFIX:
                raise ValueError(f"unknown venue {venue!r}")
            symbol = root.replace("/", "-") + VENUE_SUFFIX.get(venue or "US", "")
        case "FX":
            symbol = f"{root}=X"
        case "IDX":
            symbol = INDEX_ALIASES.get(root, root if root.startswith("^") else f"^{root}")
        case "CMD" | "FUT":
            symbol = f"{root.rstrip('0123456789') or root}=F"
        case "CRYPTO":
            symbol = crypto_pair(root, venue)
        case _:
            raise ValueError(f"asset class {asset_class} is not supported yet")

    return Security(typed=" ".join(tokens), symbol=symbol, asset_class=asset_class)
