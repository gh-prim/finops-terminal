import datetime as dt

from finops_gateway.providers.edgar import duration_periods, instant_values


def fact(start: str | None, end: str, val: float, filed: str = "2026-01-01") -> dict:
    f = {"end": end, "val": val, "filed": filed}
    if start:
        f["start"] = start
    return f


def test_quarters_derived_from_year_to_date_figures() -> None:
    # Cash-flow style: 10-Qs report 3, 6 and 9 months; the 10-K reports 12 months.
    facts = [
        fact("2024-10-01", "2024-12-31", 10),
        fact("2024-10-01", "2025-03-31", 25),
        fact("2024-10-01", "2025-06-30", 45),
        fact("2024-10-01", "2025-09-30", 70),
    ]
    annual, quarterly = duration_periods(facts)
    assert annual == {dt.date(2025, 9, 30): 70}
    assert quarterly == {
        dt.date(2024, 12, 31): 10,
        dt.date(2025, 3, 31): 15,
        dt.date(2025, 6, 30): 20,
        dt.date(2025, 9, 30): 25,  # Q4 = FY - 9 months
    }


def test_direct_quarter_wins_and_latest_filing_wins() -> None:
    facts = [
        fact("2025-01-01", "2025-03-31", 99, filed="2025-05-01"),
        fact("2025-01-01", "2025-03-31", 100, filed="2026-05-01"),  # restated
        fact("2025-04-01", "2025-06-30", 120),
    ]
    _, quarterly = duration_periods(facts)
    assert quarterly[dt.date(2025, 3, 31)] == 100
    assert quarterly[dt.date(2025, 6, 30)] == 120


def test_instants_ignore_durations() -> None:
    facts = [fact(None, "2025-09-30", 5), fact("2024-10-01", "2025-09-30", 70)]
    assert instant_values(facts) == {dt.date(2025, 9, 30): 5}
