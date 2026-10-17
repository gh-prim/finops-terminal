"""Typed security form <-> provider symbols.

Users type `<symbol> [<venue>] <class>`, e.g. `AAPL US EQ`, `VOD LN EQ`,
`EURUSD FX`, `SPX IDX`, `CL1 CMD`, `BTC CRYPTO`. Anything without a known
asset-class code is passed through as a raw Yahoo symbol.
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
}


@dataclass(frozen=True)
class Security:
    typed: str
    symbol: str
    asset_class: str | None


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
            symbol = root if "-" in root else f"{root}-USD"
        case _:
            raise ValueError(f"asset class {asset_class} is not supported yet")

    return Security(typed=" ".join(tokens), symbol=symbol, asset_class=asset_class)
