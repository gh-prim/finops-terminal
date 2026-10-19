"""The world model: entities (countries, chokepoints, commodities, sectors, central
banks) linked to each other and to the assets they move.

Hand-curated and deliberately small: every link carries the reason it exists, so a
trader can judge it. Companies get their exposures from this seed when listed in
COMPANY_EXPOSURE, else from their headquarters country and sector (Yahoo profile).
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass, field
from functools import cache


@dataclass(frozen=True)
class Asset:
    security: str      # typed terminal form, e.g. "CL1 CMD"
    why: str
    sign: int = 1      # +1 tends to rise when the entity "heats up" (supply shock, conflict), -1 to fall


@dataclass(frozen=True)
class Entity:
    id: str
    kind: str          # country | chokepoint | commodity | sector | centralbank | region
    name: str
    aliases: tuple[str, ...] = ()
    assets: tuple[Asset, ...] = ()
    related: tuple[str, ...] = ()
    lat: float | None = None
    lon: float | None = None
    fips: str | None = None    # GDELT country code (FIPS 10-4)
    iso2: str | None = None
    iso3: str | None = None
    portwatch: str | None = None  # PortWatch chokepoint name


def A(security: str, why: str, sign: int = 1) -> Asset:
    return Asset(security, why, sign)


def country(id: str, name: str, fips: str, iso2: str, iso3: str, lat: float, lon: float, aliases: tuple[str, ...],
            assets: tuple[Asset, ...] = (), related: tuple[str, ...] = ()) -> Entity:
    return Entity(id, "country", name, (name, *aliases), assets, related, lat, lon, fips, iso2, iso3)


ENTITIES_LIST: list[Entity] = [
    # MARK: Countries
    country("US", "United States", "US", "US", "USA", 39.8, -98.6, ("U.S.", "USA", "Washington", "White House", "Congress"),
            (A("SPX IDX", "US equity benchmark"), A("DXY IDX", "dollar index"), A("TLT US EQ", "long Treasuries")),
            ("FED",)),
    country("CN", "China", "CH", "CN", "CHN", 35.9, 104.2, ("Chinese", "Beijing", "Xi Jinping", "PRC"),
            (A("FXI US EQ", "China large caps"), A("000001.SS", "Shanghai Composite"), A("USDCNY FX", "yuan", -1),
             A("HG1 CMD", "copper: China is ~55% of world demand"), A("BABA US EQ", "China tech bellwether"),
             A("MC FP EQ", "LVMH: China luxury demand")),
            ("PBOC", "COPPER", "IRONORE", "TW", "SEMIS")),
    country("TW", "Taiwan", "TW", "TW", "TWN", 23.7, 121.0, ("Taiwanese", "Taipei"),
            (A("TSM US EQ", "TSMC makes ~90% of leading-edge chips"), A("EWT US EQ", "Taiwan equities"),
             A("NVDA US EQ", "NVIDIA GPUs are fabbed by TSMC"), A("AAPL US EQ", "Apple chips are fabbed by TSMC"),
             A("SOXX US EQ", "semiconductor index")),
            ("SEMIS", "TAIWANSTRAIT", "CN")),
    country("RU", "Russia", "RS", "RU", "RUS", 61.5, 105.3, ("Russian", "Moscow", "Kremlin", "Putin"),
            (A("BZ1 CMD", "Russia exports ~7 mb/d of oil and products"), A("TTF1 CMD", "European gas prices"),
             A("ZW1 CMD", "Russia is the top wheat exporter"), A("RHM GY EQ", "Rheinmetall: European rearmament")),
            ("OIL", "GAS", "WHEAT", "UA", "DEFENSE")),
    country("UA", "Ukraine", "UP", "UA", "UKR", 48.4, 31.2, ("Ukrainian", "Kyiv", "Kiev", "Zelensky"),
            (A("ZW1 CMD", "Black Sea wheat exports"), A("ZC1 CMD", "Ukraine is a top-5 corn exporter"),
             A("RHM GY EQ", "European defense spending")),
            ("RU", "WHEAT", "CORN", "DEFENSE")),
    country("IR", "Iran", "IR", "IR", "IRN", 32.4, 53.7, ("Iranian", "Tehran", "IRGC"),
            (A("CL1 CMD", "Iranian supply and Hormuz risk"), A("BZ1 CMD", "Brent risk premium"),
             A("GC1 CMD", "safe-haven demand")),
            ("HORMUZ", "OIL", "IL", "SA")),
    country("IL", "Israel", "IS", "IL", "ISR", 31.0, 34.9, ("Israeli", "Jerusalem", "Tel Aviv", "IDF", "Gaza", "Hamas", "Hezbollah"),
            (A("EIS US EQ", "Israeli equities", -1), A("LMT US EQ", "US defense primes"), A("BZ1 CMD", "regional escalation premium"),
             A("GC1 CMD", "safe-haven demand")),
            ("IR", "DEFENSE", "OIL")),
    country("SA", "Saudi Arabia", "SA", "SA", "SAU", 23.9, 45.1, ("Saudi", "Riyadh", "Aramco", "OPEC"),
            (A("CL1 CMD", "swing producer, OPEC+ policy"), A("BZ1 CMD", "Brent")),
            ("OIL", "HORMUZ", "IR")),
    country("QA", "Qatar", "QA", "QA", "QAT", 25.3, 51.2, ("Qatari", "Doha"),
            (A("TTF1 CMD", "Qatar is a top-3 LNG exporter"), A("NG1 CMD", "global LNG balance")),
            ("GAS", "HORMUZ")),
    country("YE", "Yemen", "YM", "YE", "YEM", 15.6, 48.5, ("Yemeni", "Houthi", "Houthis", "Sanaa"),
            (A("ZIM US EQ", "container rates rise when Red Sea routes close"), A("BZ1 CMD", "tanker diversions")),
            ("BABELMANDEB", "SHIPPING")),
    country("EG", "Egypt", "EG", "EG", "EGY", 26.8, 30.8, ("Egyptian", "Cairo"), (), ("SUEZ",)),
    country("PA", "Panama", "PM", "PA", "PAN", 8.5, -80.8, ("Panamanian",), (), ("PANAMA",)),
    country("TR", "Turkey", "TU", "TR", "TUR", 39.0, 35.2, ("Turkish", "Ankara", "Erdogan", "Türkiye"),
            (A("USDTRY FX", "lira", 1), A("TUR US EQ", "Turkish equities", -1)), ("BOSPORUS",)),
    country("JP", "Japan", "JA", "JP", "JPN", 36.2, 138.3, ("Japanese", "Tokyo"),
            (A("NKY IDX", "Nikkei 225"), A("USDJPY FX", "yen"), A("TM US EQ", "Toyota")), ("BOJ",)),
    country("KR", "South Korea", "KS", "KR", "KOR", 35.9, 127.8, ("Korean", "Seoul"),
            (A("EWY US EQ", "Korean equities (Samsung, SK Hynix)"), A("KS11 IDX", "KOSPI")), ("SEMIS",)),
    country("KP", "North Korea", "KN", "KP", "PRK", 40.3, 127.5, ("North Korean", "Pyongyang", "Kim Jong"),
            (A("EWY US EQ", "Korean risk premium", -1), A("GC1 CMD", "safe haven")), ("KR", "JP")),
    country("IN", "India", "IN", "IN", "IND", 20.6, 79.0, ("Indian", "New Delhi", "Modi"),
            (A("INDA US EQ", "Indian equities"), A("NSEI IDX", "Nifty 50"), A("USDINR FX", "rupee", -1)), ("OIL",)),
    country("DE", "Germany", "GM", "DE", "DEU", 51.2, 10.4, ("German", "Berlin", "Bundestag"),
            (A("DAX IDX", "DAX"), A("EURUSD FX", "euro")), ("ECB", "GAS")),
    country("FR", "France", "FR", "FR", "FRA", 46.2, 2.2, ("French", "Paris", "Elysee", "Macron"),
            (A("CAC IDX", "CAC 40"), A("EURUSD FX", "euro"), A("TTE FP EQ", "TotalEnergies")), ("ECB",)),
    country("GB", "United Kingdom", "UK", "GB", "GBR", 55.4, -3.4, ("British", "UK", "London", "Downing Street"),
            (A("UKX IDX", "FTSE 100"), A("GBPUSD FX", "sterling")), ("BOE",)),
    country("NL", "Netherlands", "NL", "NL", "NLD", 52.1, 5.3, ("Dutch", "Amsterdam", "The Hague"),
            (A("ASML US EQ", "ASML: sole EUV lithography supplier"), A("TTF1 CMD", "Dutch TTF gas hub")), ("SEMIS", "GAS")),
    country("CL", "Chile", "CI", "CL", "CHL", -35.7, -71.5, ("Chilean", "Santiago"),
            (A("HG1 CMD", "Chile mines ~25% of world copper"), A("SCCO US EQ", "Southern Copper"),
             A("SQM US EQ", "lithium")), ("COPPER",)),
    country("PE", "Peru", "PE", "PE", "PER", -9.2, -75.0, ("Peruvian", "Lima"),
            (A("HG1 CMD", "Peru is the #2 copper producer"), A("SCCO US EQ", "Southern Copper")), ("COPPER",)),
    country("BR", "Brazil", "BR", "BR", "BRA", -14.2, -51.9, ("Brazilian", "Brasilia", "Lula"),
            (A("EWZ US EQ", "Brazilian equities"), A("KC1 CMD", "Brazil grows ~35% of coffee"),
             A("ZS1 CMD", "top soybean exporter"), A("VALE US EQ", "Vale: iron ore"), A("USDBRL FX", "real", -1)),
            ("COFFEE", "SOY", "IRONORE")),
    country("AU", "Australia", "AS", "AU", "AUS", -25.3, 133.8, ("Australian", "Canberra"),
            (A("AUDUSD FX", "commodity currency"), A("BHP US EQ", "BHP: iron ore, copper"), A("RIO US EQ", "Rio Tinto")),
            ("IRONORE", "GAS")),
    country("CI", "Ivory Coast", "IV", "CI", "CIV", 7.5, -5.5, ("Ivorian", "Cote d'Ivoire", "Côte d'Ivoire", "Abidjan"),
            (A("CC1 CMD", "Ivory Coast grows ~40% of the world's cocoa"),), ("COCOA",)),
    country("GH", "Ghana", "GH", "GH", "GHA", 7.9, -1.0, ("Ghanaian", "Accra"),
            (A("CC1 CMD", "Ghana is the #2 cocoa grower"),), ("COCOA",)),
    country("VE", "Venezuela", "VE", "VE", "VEN", 6.4, -66.6, ("Venezuelan", "Caracas", "Maduro"),
            (A("CL1 CMD", "heavy crude supply"),), ("OIL",)),
    country("LY", "Libya", "LY", "LY", "LBY", 26.3, 17.2, ("Libyan", "Tripoli", "Benghazi"),
            (A("BZ1 CMD", "Libyan output outages move Brent"),), ("OIL",)),
    country("NG", "Nigeria", "NI", "NG", "NGA", 9.1, 8.7, ("Nigerian", "Abuja", "Lagos"),
            (A("BZ1 CMD", "Nigerian crude"),), ("OIL",)),
    country("NO", "Norway", "NO", "NO", "NOR", 60.5, 8.5, ("Norwegian", "Oslo"),
            (A("TTF1 CMD", "Norway supplies ~30% of EU gas"), A("EQNR US EQ", "Equinor")), ("GAS",)),
    country("MX", "Mexico", "MX", "MX", "MEX", 23.6, -102.6, ("Mexican", "Mexico City"),
            (A("USDMXN FX", "peso", -1), A("EWW US EQ", "Mexican equities")), ("US",)),
    country("CA", "Canada", "CA", "CA", "CAN", 56.1, -106.3, ("Canadian", "Ottawa"),
            (A("USDCAD FX", "loonie"), A("CL1 CMD", "Canada is the top US oil supplier")), ("OIL", "US")),
    country("ZA", "South Africa", "SF", "ZA", "ZAF", -30.6, 22.9, ("South African", "Pretoria", "Johannesburg"),
            (A("EZA US EQ", "South African equities"), A("PL1 CMD", "platinum: ~70% of world supply"),
             A("USDZAR FX", "rand", -1)), ()),
    # MARK: Chokepoints
    Entity("HORMUZ", "chokepoint", "Strait of Hormuz", ("Hormuz", "Strait of Hormuz", "Persian Gulf"),
           (A("CL1 CMD", "~20% of world oil passes Hormuz"), A("BZ1 CMD", "Brent"), A("TTF1 CMD", "Qatari LNG route"),
            A("FRO US EQ", "tanker rates (Frontline)")),
           ("IR", "SA", "QA", "OIL", "GAS"), 26.57, 56.25, portwatch="Strait of Hormuz"),
    Entity("BABELMANDEB", "chokepoint", "Bab el-Mandeb / Red Sea", ("Bab el-Mandeb", "Red Sea", "Gulf of Aden"),
           (A("ZIM US EQ", "container rates"), A("AMKBY US EQ", "Maersk: Red Sea diversions"), A("BZ1 CMD", "tanker diversions")),
           ("YE", "SUEZ", "SHIPPING"), 12.6, 43.3, portwatch="Bab el-Mandeb Strait"),
    Entity("SUEZ", "chokepoint", "Suez Canal", ("Suez", "Suez Canal"),
           (A("ZIM US EQ", "container rates"), A("AMKBY US EQ", "Maersk"), A("BZ1 CMD", "Europe-bound crude")),
           ("EG", "BABELMANDEB", "SHIPPING"), 30.6, 32.35, portwatch="Suez Canal"),
    Entity("PANAMA", "chokepoint", "Panama Canal", ("Panama Canal",),
           (A("ZIM US EQ", "container rates"), A("NG1 CMD", "US LNG to Asia"), A("ZS1 CMD", "US grain to Asia")),
           ("PA", "SHIPPING"), 9.1, -79.7, portwatch="Panama Canal"),
    Entity("MALACCA", "chokepoint", "Strait of Malacca", ("Malacca", "Strait of Malacca", "Singapore Strait"),
           (A("CL1 CMD", "Asia-bound crude"), A("ZIM US EQ", "Asia trade")), ("CN", "SHIPPING"), 2.5, 101.4,
           portwatch="Malacca Strait"),
    Entity("BOSPORUS", "chokepoint", "Bosporus", ("Bosporus", "Bosphorus", "Turkish Straits", "Black Sea"),
           (A("ZW1 CMD", "Black Sea grain"), A("BZ1 CMD", "Russian/Kazakh crude")), ("TR", "RU", "UA", "WHEAT"),
           41.1, 29.05, portwatch="Bosporus Strait"),
    Entity("TAIWANSTRAIT", "chokepoint", "Taiwan Strait", ("Taiwan Strait",),
           (A("TSM US EQ", "TSMC", -1), A("SOXX US EQ", "semiconductors", -1), A("EWT US EQ", "Taiwan", -1)),
           ("TW", "CN", "SEMIS"), 24.5, 119.5, portwatch="Taiwan Strait"),
    Entity("GIBRALTAR", "chokepoint", "Strait of Gibraltar", ("Gibraltar",), (), ("SHIPPING",), 35.95, -5.6,
           portwatch="Gibraltar Strait"),
    Entity("CAPE", "chokepoint", "Cape of Good Hope", ("Cape of Good Hope",), (A("ZIM US EQ", "longer routes lift rates"),),
           ("SHIPPING", "SUEZ"), -34.4, 18.5, portwatch="Cape of Good Hope"),
    # MARK: Commodities & sectors
    Entity("OIL", "commodity", "Crude oil", ("oil", "crude", "OPEC", "barrel", "Brent", "WTI", "refinery", "pipeline"),
           (A("CL1 CMD", "WTI"), A("BZ1 CMD", "Brent"), A("XOM US EQ", "Exxon"), A("CVX US EQ", "Chevron"),
            A("TTE FP EQ", "TotalEnergies"), A("XLE US EQ", "US energy sector"), A("DAL US EQ", "airlines: fuel cost", -1)),
           ("SA", "IR", "RU", "HORMUZ")),
    Entity("GAS", "commodity", "Natural gas / LNG", ("natural gas", "LNG", "gas pipeline", "Nord Stream", "TTF"),
           (A("TTF1 CMD", "European gas (TTF)"), A("NG1 CMD", "US Henry Hub"), A("LNG US EQ", "Cheniere: US LNG exports")),
           ("QA", "RU", "NO", "HORMUZ")),
    Entity("GOLD", "commodity", "Gold", ("gold", "bullion", "safe haven"),
           (A("GC1 CMD", "gold"), A("GDX US EQ", "gold miners")), ()),
    Entity("COPPER", "commodity", "Copper", ("copper",), (A("HG1 CMD", "copper"), A("FCX US EQ", "Freeport"),
           A("SCCO US EQ", "Southern Copper")), ("CL", "PE", "CN")),
    Entity("IRONORE", "commodity", "Iron ore", ("iron ore", "steel"), (A("BHP US EQ", "BHP"), A("RIO US EQ", "Rio Tinto"),
           A("VALE US EQ", "Vale")), ("AU", "BR", "CN")),
    Entity("WHEAT", "commodity", "Wheat", ("wheat", "grain"), (A("ZW1 CMD", "wheat"), A("ADM US EQ", "ADM: grain trading"),
           A("BG US EQ", "Bunge")), ("RU", "UA", "BOSPORUS")),
    Entity("CORN", "commodity", "Corn", ("corn", "maize"), (A("ZC1 CMD", "corn"),), ("UA", "US")),
    Entity("SOY", "commodity", "Soybeans", ("soybean", "soybeans", "soy"), (A("ZS1 CMD", "soybeans"),), ("BR", "US", "CN")),
    Entity("COFFEE", "commodity", "Coffee", ("coffee", "arabica"), (A("KC1 CMD", "arabica"), A("SBUX US EQ", "Starbucks: bean costs", -1)),
           ("BR",)),
    Entity("COCOA", "commodity", "Cocoa", ("cocoa",), (A("CC1 CMD", "cocoa"), A("HSY US EQ", "Hershey: cocoa costs", -1)),
           ("CI", "GH")),
    Entity("SEMIS", "sector", "Semiconductors", ("semiconductor", "semiconductors", "chip", "chips", "chipmaker", "foundry"),
           (A("SOXX US EQ", "semiconductor index"), A("NVDA US EQ", "NVIDIA"), A("TSM US EQ", "TSMC"), A("ASML US EQ", "ASML"),
            A("AMD US EQ", "AMD")), ("TW", "NL", "KR", "CN")),
    Entity("SHIPPING", "sector", "Shipping", ("shipping", "freight", "container ship", "tanker", "vessel"),
           (A("ZIM US EQ", "ZIM"), A("AMKBY US EQ", "Maersk"), A("FRO US EQ", "Frontline tankers")),
           ("SUEZ", "BABELMANDEB", "PANAMA", "HORMUZ", "MALACCA")),
    Entity("DEFENSE", "sector", "Defense", ("defense", "defence", "military", "missile", "drone", "NATO", "arms"),
           (A("LMT US EQ", "Lockheed Martin"), A("RTX US EQ", "RTX"), A("NOC US EQ", "Northrop Grumman"),
            A("RHM GY EQ", "Rheinmetall"), A("ITA US EQ", "US aerospace & defense")), ("UA", "RU", "IL", "TW")),
    Entity("AIRLINES", "sector", "Airlines", ("airline", "airlines", "airspace", "flights"),
           (A("DAL US EQ", "Delta"), A("UAL US EQ", "United"), A("JETS US EQ", "airline ETF")), ("OIL",)),
    # MARK: Central banks
    Entity("FED", "centralbank", "Federal Reserve", ("Federal Reserve", "Fed", "FOMC", "Powell"),
           (A("TLT US EQ", "long Treasuries"), A("DXY IDX", "dollar"), A("SPX IDX", "equities"), A("GC1 CMD", "gold")), ("US",)),
    Entity("ECB", "centralbank", "European Central Bank", ("ECB", "European Central Bank", "Lagarde"),
           (A("EURUSD FX", "euro"), A("SX5E IDX", "Euro Stoxx 50")), ("DE", "FR")),
    Entity("BOJ", "centralbank", "Bank of Japan", ("Bank of Japan", "BoJ", "Ueda"),
           (A("USDJPY FX", "yen", -1), A("NKY IDX", "Nikkei")), ("JP",)),
    Entity("BOE", "centralbank", "Bank of England", ("Bank of England", "BoE"), (A("GBPUSD FX", "sterling"),), ("GB",)),
    Entity("PBOC", "centralbank", "People's Bank of China", ("PBOC", "People's Bank of China"),
           (A("USDCNY FX", "yuan"), A("FXI US EQ", "China equities")), ("CN",)),
]

ENTITIES: dict[str, Entity] = {e.id: e for e in ENTITIES_LIST}
BY_FIPS = {e.fips: e for e in ENTITIES_LIST if e.fips}
BY_ISO2 = {e.iso2: e for e in ENTITIES_LIST if e.iso2}
BY_ISO3 = {e.iso3: e for e in ENTITIES_LIST if e.iso3}

# Explicit exposures for large caps whose risk isn't where their headquarters are.
COMPANY_EXPOSURE: dict[str, list[tuple[str, float, str]]] = {
    "AAPL": [("CN", 0.45, "assembly and ~17% of sales"), ("TW", 0.35, "chips from TSMC"), ("US", 0.2, "headquarters")],
    "NVDA": [("TW", 0.5, "all GPUs fabbed by TSMC"), ("CN", 0.2, "export controls, ~15% of sales"), ("SEMIS", 0.3, "sector")],
    "AMD": [("TW", 0.5, "fabbed by TSMC"), ("SEMIS", 0.5, "sector")],
    "TSM": [("TW", 0.7, "fabs in Taiwan"), ("TAIWANSTRAIT", 0.3, "blockade risk")],
    "ASML": [("NL", 0.4, "headquarters"), ("CN", 0.3, "~25% of sales, export controls"), ("SEMIS", 0.3, "sector")],
    "TSLA": [("CN", 0.4, "Shanghai gigafactory, ~20% of sales"), ("US", 0.6, "headquarters")],
    "BABA": [("CN", 1.0, "operations")],
    "XOM": [("OIL", 0.8, "upstream oil"), ("GAS", 0.2, "LNG")],
    "CVX": [("OIL", 0.8, "upstream oil"), ("GAS", 0.2, "LNG")],
    "TTE": [("OIL", 0.6, "oil"), ("GAS", 0.3, "LNG"), ("FR", 0.1, "headquarters")],
    "MC": [("CN", 0.4, "Asia ~30% of sales"), ("FR", 0.6, "headquarters")],
    "DAL": [("OIL", 0.6, "jet fuel cost"), ("AIRLINES", 0.4, "sector")],
    "UAL": [("OIL", 0.6, "jet fuel cost"), ("AIRLINES", 0.4, "sector")],
    "LMT": [("DEFENSE", 1.0, "sector")],
    "RTX": [("DEFENSE", 1.0, "sector")],
    "FCX": [("COPPER", 0.8, "copper mining"), ("GOLD", 0.2, "gold by-product")],
    "ZIM": [("SHIPPING", 0.6, "container shipping"), ("SUEZ", 0.2, "Asia-Europe route"), ("BABELMANDEB", 0.2, "Red Sea")],
    "MSFT": [("US", 0.8, "headquarters"), ("TW", 0.2, "AI chip supply")],
    "AMZN": [("US", 0.8, "headquarters"), ("CN", 0.2, "sourcing")],
    "GOOGL": [("US", 0.85, "headquarters"), ("TW", 0.15, "TPU supply")],
    "META": [("US", 0.9, "headquarters"), ("TW", 0.1, "AI chip supply")],
}

SECTOR_ENTITY = {"Energy": "OIL", "Basic Materials": "COPPER"}
INDUSTRY_ENTITY = {"Semiconductors": "SEMIS", "Semiconductor Equipment & Materials": "SEMIS", "Airlines": "AIRLINES",
                   "Aerospace & Defense": "DEFENSE", "Marine Shipping": "SHIPPING", "Gold": "GOLD", "Copper": "COPPER",
                   "Oil & Gas Integrated": "OIL", "Oil & Gas E&P": "OIL", "Oil & Gas Refining & Marketing": "OIL"}
COUNTRY_NAME = {e.name: e.id for e in ENTITIES_LIST if e.kind == "country"} | {"Taiwan, Province of China": "TW"}


def get(id: str) -> Entity | None:
    return ENTITIES.get(id.upper())


def find(query: str) -> Entity | None:
    """By id, name or alias (case-insensitive)."""
    q = query.strip().lower()
    if not q:
        return None
    if (e := ENTITIES.get(q.upper())) is not None:
        return e
    for e in ENTITIES_LIST:
        if e.name.lower() == q or any(a.lower() == q for a in e.aliases):
            return e
    return None


@cache
def _patterns() -> list[tuple[re.Pattern[str], str]]:
    out = []
    for e in ENTITIES_LIST:
        words = sorted({e.name, *e.aliases}, key=len, reverse=True)
        # Short all-caps aliases (UK, Fed, LNG) must match case-sensitively to avoid "fed up", "uk" in URLs…
        exact = [w for w in words if len(w) <= 4]
        loose = [w for w in words if len(w) > 4]
        if loose:
            out.append((re.compile(r"\b(" + "|".join(map(re.escape, loose)) + r")\b", re.IGNORECASE), e.id))
        if exact:
            out.append((re.compile(r"\b(" + "|".join(map(re.escape, exact)) + r")\b"), e.id))
    return out


def match_text(text: str) -> list[str]:
    """Entity ids mentioned in free text, in first-seen order."""
    found: list[tuple[int, str]] = []
    for pattern, id in _patterns():
        if (m := pattern.search(text)) and id not in [f[1] for f in found]:
            found.append((m.start(), id))
    return [id for _, id in sorted(found)]


def near(lat: float, lon: float, km: float = 350) -> list[str]:
    """Chokepoints within `km` of a point."""
    out = []
    for e in ENTITIES_LIST:
        if e.kind == "chokepoint" and e.lat is not None and e.lon is not None and _distance(lat, lon, e.lat, e.lon) <= km:
            out.append(e.id)
    return out


def _distance(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 6371 * 2 * math.asin(math.sqrt(a))


def symbol_root(typed: str) -> str:
    return typed.split()[0].upper()


def exposure(typed: str, profile: dict | None = None) -> list[tuple[str, float, str]]:
    """(entity id, weight 0–1, reason) for a security: curated list, else HQ country + sector/industry."""
    root = symbol_root(typed)
    if root in COMPANY_EXPOSURE:
        return COMPANY_EXPOSURE[root]
    # A security that an entity lists as one of its assets (indices, commodities, FX, ETFs).
    listed = [(e.id, 1.0, a.why) for e in ENTITIES_LIST for a in e.assets if a.security == typed.upper()]
    if listed:
        total = len(listed)
        return [(id, 1 / total, why) for id, _, why in listed]
    out: list[tuple[str, float, str]] = []
    if profile:
        if (cid := COUNTRY_NAME.get(profile.get("country") or "")):
            out.append((cid, 0.6, "headquarters"))
        if (ind := INDUSTRY_ENTITY.get(profile.get("industry") or "")) or (ind := SECTOR_ENTITY.get(profile.get("sector") or "")):
            out.append((ind, 0.4, profile.get("industry") or profile.get("sector") or "sector"))
    if not out and typed.upper().endswith(" CRYPTO"):
        out.append(("US", 0.3, "US regulation and dollar liquidity"))
        out.append(("FED", 0.7, "liquidity and rates"))
    total = sum(w for _, w, _ in out) or 1
    return [(id, w / total, why) for id, w, why in out]


def watch_set(exposure_ids: set[str]) -> set[str]:
    """Entities whose events matter for these exposures: a commodity, sector or chokepoint brings
    its producers and routes along; the home market (US) is left out, its news is everywhere."""
    out = set(exposure_ids)
    for id in exposure_ids:
        if (e := get(id)) is not None and e.kind in ("commodity", "sector", "chokepoint"):
            out.update(e.related)
    return out - {"US"}
