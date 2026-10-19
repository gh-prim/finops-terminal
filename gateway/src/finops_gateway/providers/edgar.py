"""SEC EDGAR: financial statements (XBRL companyfacts) and filings (submissions).

Rules: descriptive User-Agent with contact (config), < 10 requests/second,
cache aggressively. Only SEC filers (mostly US-listed companies) are covered.
"""

from __future__ import annotations

import datetime as dt
import threading
import time
from collections import defaultdict
from typing import Any

from ..cache import ttl_cache
from ..config import settings
from ..documents import choices, column, document, row, series as series_block, table
from .http import get_json

SOURCE = "SEC EDGAR (XBRL company facts)"
_rate_lock = threading.Lock()
_last_request = 0.0


def _get(url: str) -> Any:
    global _last_request
    if not settings.edgar_contact:
        raise LookupError("SEC EDGAR requires a contact email: set EDGAR_CONTACT on the backend "
                          "(or Settings → EDGAR contact in the Mac app).")
    with _rate_lock:  # stay well under SEC's 10 requests/second
        wait = 0.15 - (time.monotonic() - _last_request)
        if wait > 0:
            time.sleep(wait)
        _last_request = time.monotonic()
    return get_json(url, headers={"User-Agent": settings.edgar_user_agent})


@ttl_cache(86400)
def _tickers() -> dict[str, tuple[int, str]]:
    data = _get("https://www.sec.gov/files/company_tickers.json")
    return {v["ticker"].upper(): (int(v["cik_str"]), v["title"]) for v in data.values()}


def cik_for(symbol: str) -> tuple[int, str]:
    key = symbol.upper().replace("-", ".")
    found = _tickers().get(key) or _tickers().get(symbol.upper())
    if not found:
        raise LookupError(f"{symbol} is not an SEC filer, so EDGAR has no fundamentals for it")
    return found


@ttl_cache(86400, maxsize=64)
def _facts(cik: int) -> dict[str, Any]:
    return _get(f"https://data.sec.gov/api/xbrl/companyfacts/CIK{cik:010d}.json")


@ttl_cache(3600, maxsize=64)
def _submissions(cik: int) -> dict[str, Any]:
    return _get(f"https://data.sec.gov/submissions/CIK{cik:010d}.json")


# MARK: Statements

# (label, candidate us-gaap tags in priority order, kind, flow?) — flow items are
# durations (income/cash flow); others are balance-sheet instants.
Line = tuple[str, list[str], str]
STATEMENTS: dict[str, tuple[str, bool, list[Line]]] = {
    "IS": ("Income statement", True, [
        ("Revenue", ["Revenues", "RevenueFromContractWithCustomerExcludingAssessedTax", "SalesRevenueNet",
                     "RevenueFromContractWithCustomerIncludingAssessedTax"], "compact"),
        ("Cost of revenue", ["CostOfRevenue", "CostOfGoodsAndServicesSold", "CostOfGoodsSold"], "compact"),
        ("Gross profit", ["GrossProfit"], "compact"),
        ("R&D", ["ResearchAndDevelopmentExpense"], "compact"),
        ("SG&A", ["SellingGeneralAndAdministrativeExpense"], "compact"),
        ("Operating income", ["OperatingIncomeLoss"], "compact"),
        ("Pre-tax income", ["IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest",
                            "IncomeLossFromContinuingOperationsBeforeIncomeTaxesMinorityInterestAndIncomeLossFromEquityMethodInvestments"],
         "compact"),
        ("Income tax", ["IncomeTaxExpenseBenefit"], "compact"),
        ("Net income", ["NetIncomeLoss", "ProfitLoss"], "compact"),
        ("EPS (basic)", ["EarningsPerShareBasic"], "price"),
        ("EPS (diluted)", ["EarningsPerShareDiluted"], "price"),
        ("Diluted shares", ["WeightedAverageNumberOfDilutedSharesOutstanding"], "compact"),
    ]),
    "BS": ("Balance sheet", False, [
        ("Cash & equivalents", ["CashAndCashEquivalentsAtCarryingValue"], "compact"),
        ("Short-term investments", ["MarketableSecuritiesCurrent", "ShortTermInvestments",
                                    "AvailableForSaleSecuritiesDebtSecuritiesCurrent"], "compact"),
        ("Receivables", ["AccountsReceivableNetCurrent"], "compact"),
        ("Inventory", ["InventoryNet"], "compact"),
        ("Current assets", ["AssetsCurrent"], "compact"),
        ("Total assets", ["Assets"], "compact"),
        ("Payables", ["AccountsPayableCurrent"], "compact"),
        ("Current liabilities", ["LiabilitiesCurrent"], "compact"),
        ("Long-term debt", ["LongTermDebtNoncurrent", "LongTermDebt"], "compact"),
        ("Total liabilities", ["Liabilities"], "compact"),
        ("Shareholders' equity", ["StockholdersEquity",
                                  "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest"], "compact"),
    ]),
    "CF": ("Cash flow", True, [
        ("Operating cash flow", ["NetCashProvidedByUsedInOperatingActivities"], "compact"),
        ("Capital expenditure", ["PaymentsToAcquirePropertyPlantAndEquipment"], "compact"),
        ("Depreciation & amortization", ["DepreciationDepletionAndAmortization", "DepreciationAndAmortization",
                                         "DepreciationAmortizationAndAccretionNet"], "compact"),
        ("Stock-based comp", ["ShareBasedCompensation"], "compact"),
        ("Investing cash flow", ["NetCashProvidedByUsedInInvestingActivities"], "compact"),
        ("Financing cash flow", ["NetCashProvidedByUsedInFinancingActivities"], "compact"),
        ("Buybacks", ["PaymentsForRepurchaseOfCommonStock"], "compact"),
        ("Dividends paid", ["PaymentsOfDividends", "PaymentsOfDividendsCommonStock"], "compact"),
    ]),
}


def _date(s: str) -> dt.date:
    return dt.date.fromisoformat(s)


def _units(fact: dict[str, Any]) -> list[dict[str, Any]]:
    units = fact.get("units", {})
    for unit in ("USD", "USD/shares", "shares"):
        if unit in units:
            return units[unit]
    return next(iter(units.values()), [])


def duration_periods(facts: list[dict[str, Any]]) -> tuple[dict[dt.date, float], dict[dt.date, float]]:
    """Return (annual, quarterly) values keyed by period end.

    10-Qs often report year-to-date figures (6 and 9 months), so quarters are
    derived by differencing consecutive cumulative values that share a start
    date; Q4 comes out as FY minus the 9-month figure.
    """
    latest: dict[tuple[dt.date, dt.date], tuple[str, float]] = {}
    for f in facts:
        if "start" not in f or f.get("val") is None:
            continue
        key = (_date(f["start"]), _date(f["end"]))
        filed = f.get("filed", "")
        if key not in latest or filed > latest[key][0]:
            latest[key] = (filed, float(f["val"]))

    annual: dict[dt.date, float] = {}
    quarterly: dict[dt.date, float] = {}
    by_start: dict[dt.date, list[tuple[dt.date, float]]] = defaultdict(list)
    for (start, end), (_, val) in latest.items():
        days = (end - start).days
        if 350 <= days <= 380:
            annual[end] = val
        if 80 <= days <= 100:
            quarterly[end] = val
        by_start[start].append((end, val))

    for start, items in by_start.items():
        items.sort()
        prev_end, prev_val = start - dt.timedelta(days=1), 0.0
        for end, val in items:
            gap = (end - prev_end).days
            if 80 <= gap <= 100 and end not in quarterly:
                quarterly[end] = val - prev_val
            if 80 <= gap <= 100 or (end - start).days < 100:
                prev_end, prev_val = end, val
    return annual, quarterly


def instant_values(facts: list[dict[str, Any]]) -> dict[dt.date, float]:
    out: dict[dt.date, tuple[str, float]] = {}
    for f in facts:
        if "start" in f or f.get("val") is None:
            continue
        end, filed = _date(f["end"]), f.get("filed", "")
        if end not in out or filed > out[end][0]:
            out[end] = (filed, float(f["val"]))
    return {k: v for k, (_, v) in out.items()}


def _series(gaap: dict[str, Any], tags: list[str], flow: bool, quarterly: bool) -> dict[dt.date, float]:
    """Merge candidate tags: earlier tags win, later tags fill gaps (companies switch tags over time)."""
    merged: dict[dt.date, float] = {}
    for tag in reversed(tags):
        if tag not in gaap:
            continue
        facts = _units(gaap[tag])
        if flow:
            annual, quarters = duration_periods(facts)
            merged.update(quarters if quarterly else annual)
        else:
            merged.update(instant_values(facts))
    return merged


def _period_label(end: dt.date, quarterly: bool) -> str:
    return f"{end:%b %Y}" if quarterly else f"FY {end:%Y}"


@ttl_cache(3600, maxsize=128)
def financials(symbol: str, period: str = "A", statement: str = "IS") -> dict[str, Any]:
    statement = statement if statement in STATEMENTS else "IS"
    quarterly = period == "Q"
    cik, name = cik_for(symbol)
    gaap = _facts(cik).get("facts", {}).get("us-gaap", {})
    if not gaap:
        raise LookupError(f"{name} has no US-GAAP XBRL data (foreign filers use IFRS)")

    title, flow, lines = STATEMENTS[statement]
    series = {label: _series(gaap, tags, flow, quarterly) for label, tags, _ in lines}

    # Period columns: anchor on revenue/net income (flows) or total assets (balance sheet).
    if flow:
        anchor = (series.get("Revenue") or series.get("Net income")
                  or series.get("Operating cash flow") or {})
    else:
        anchor = series.get("Total assets") or {}
        if not quarterly:  # balance sheet at fiscal year ends only
            fy_ends = set(_series(gaap, ["NetIncomeLoss", "ProfitLoss"], True, False))
            anchor = {d: v for d, v in anchor.items() if any(abs((d - e).days) <= 7 for e in fy_ends)}
    ends = sorted(anchor)[-(12 if quarterly else 10):]
    if not ends:
        raise LookupError(f"no {title.lower()} data for {name}")

    def value(label: str, end: dt.date) -> float | None:
        s = series.get(label, {})
        return s.get(end) or next((v for d, v in s.items() if abs((d - end).days) <= 7), None)

    columns = [column("line", "")] + [column(e.isoformat(), _period_label(e, quarterly), "compact") for e in ends]
    rows = []
    for label, _, kind in lines:
        values = [value(label, e) for e in ends]
        if any(v is not None for v in values):
            rows.append({**row([label, *values]), "kind": kind})

    derived: list[tuple[str, list[float | None], str]] = []
    if statement == "IS":
        rev = [value("Revenue", e) for e in ends]
        for label, line in (("Gross margin %", "Gross profit"), ("Operating margin %", "Operating income"),
                            ("Net margin %", "Net income")):
            derived.append((label, [(value(line, e) / r * 100) if r and value(line, e) is not None else None
                                    for e, r in zip(ends, rev)], "percent"))
        lag = 4 if quarterly else 1  # year-over-year
        derived.append(("Revenue growth %", [None] * lag + [(b / a - 1) * 100 if a and b else None
                                                            for a, b in zip(rev, rev[lag:])], "pctchange"))
    if statement == "CF":
        derived.append(("Free cash flow", [
            (value("Operating cash flow", e) - (value("Capital expenditure", e) or 0))
            if value("Operating cash flow", e) is not None else None for e in ends], "compact"))

    for label, values, kind in derived:
        if any(v is not None for v in values):
            rows.append({**row([label, *values]), "kind": kind})  # row-level format override

    # Charts of the main lines and the derived ratios, oldest to newest.
    def epoch(e: dt.date) -> int:
        return int(dt.datetime(e.year, e.month, e.day, tzinfo=dt.timezone.utc).timestamp())

    amounts = [r for r in rows if r.get("kind", "compact") == "compact"][:4]
    ratios = [r for r in rows if r.get("kind") in ("percent", "pctchange")]
    charts = [series_block("lines", "Main lines", [{"label": r["cells"][0], "points": list(zip(map(epoch, ends), r["cells"][1:]))}
                                                   for r in amounts], kind="compact")] if amounts else []
    if ratios:
        charts.append(series_block("ratios", "Margins and growth %", [{"label": r["cells"][0],
                                   "points": list(zip(map(epoch, ends), r["cells"][1:]))} for r in ratios], kind="percent"))

    # Newest period first so the latest numbers are visible without scrolling.
    columns = [columns[0], *reversed(columns[1:])]
    for r in rows:
        r["cells"] = [r["cells"][0], *reversed(r["cells"][1:])]

    period_name = "Quarterly" if quarterly else "Annual"
    return document(f"{title} — {name}", [
        choices("statement", None, [(STATEMENTS[k][0], f"FIN {period} {k}") for k in STATEMENTS], title),
        choices("period", None, [("Annual", f"FIN A {statement}"), ("Quarterly", f"FIN Q {statement}")], period_name),
        table("statement", f"{period_name} · USD", columns, rows),
        *charts,
    ], SOURCE, subtitle=symbol, notes=[
        "Values as reported in 10-K/10-Q XBRL. Quarterly values are derived from year-to-date filings where needed.",
    ])


# MARK: Filings

FORM_GROUPS = {
    "ALL": None,
    "10-K": {"10-K", "10-K/A", "20-F", "40-F"},
    "10-Q": {"10-Q", "10-Q/A"},
    "8-K": {"8-K", "8-K/A", "6-K"},
    "INSIDER": {"3", "4", "5"},
    "PROXY": {"DEF 14A", "DEFA14A"},
}


@ttl_cache(1800, maxsize=128)
def filings(symbol: str, group: str = "ALL") -> dict[str, Any]:
    group = group if group in FORM_GROUPS else "ALL"
    cik, name = cik_for(symbol)
    recent = _submissions(cik)["filings"]["recent"]
    forms = FORM_GROUPS[group]
    rows = []
    for i, form in enumerate(recent["form"]):
        if forms is not None and form not in forms:
            continue
        accession = recent["accessionNumber"][i].replace("-", "")
        doc = recent["primaryDocument"][i]
        url = f"https://www.sec.gov/Archives/edgar/data/{cik}/{accession}/{doc}"
        filed = dt.datetime.fromisoformat(recent["filingDate"][i]).replace(tzinfo=dt.UTC).timestamp()
        rows.append(row([filed, form, recent["primaryDocDescription"][i] or recent.get("items", [""] * (i + 1))[i],
                         recent["reportDate"][i] or None], url=url))
        if len(rows) >= 100:
            break
    return document(f"Filings — {name}", [
        choices("forms", None, [(g.title() if g in ("ALL", "INSIDER", "PROXY") else g, f"FILE {g}")
                                for g in FORM_GROUPS], group.title() if group in ("ALL", "INSIDER", "PROXY") else group),
        table("filings", None, [column("filed", "Filed", "date"), column("form", "Form"),
                                column("desc", "Description"), column("period", "Period")], rows),
    ], "SEC EDGAR submissions", subtitle=symbol, notes=["Click a filing to open it on sec.gov."])
