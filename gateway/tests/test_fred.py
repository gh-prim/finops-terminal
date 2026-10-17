import datetime as dt

import pytest

from finops_gateway.providers import fred


@pytest.fixture
def fake_fred(monkeypatch: pytest.MonkeyPatch) -> None:
    today = dt.date.today()

    def obs(days_ago: int, value: str) -> dict:
        return {"date": (today - dt.timedelta(days=days_ago)).isoformat(), "value": value}

    def fake_get(path: str, **params):
        if path == "series":
            return {"seriess": [{"id": params["series_id"], "title": "Test series", "units": "Percent",
                                 "frequency": "Monthly", "last_updated": "2026-10-01", "notes": "n"}]}
        if path == "series/observations":
            rows = [obs(400, "1.0"), obs(366, "1.5"), obs(200, "."), obs(31, "2.0"), obs(1, "2.5")]
            if params.get("sort_order") == "desc":
                rows = rows[::-1]
            return {"observations": rows[: params.get("limit", len(rows))]}
        if path == "releases/dates":
            return {"release_dates": [
                {"release_id": 50, "release_name": "Employment Situation", "date": today.isoformat()},
                {"release_id": 1, "release_name": "Some Obscure Survey", "date": today.isoformat()},
            ]}
        raise AssertionError(path)

    monkeypatch.setattr(fred, "_get", fake_get)
    for fn in (fred.series, fred.curve, fred.dashboard, fred.search):
        fn.cache_clear()


def test_series_skips_missing_values(fake_fred: None) -> None:
    data = fred.series("UNRATE", "MAX")
    assert data["series"]["title"] == "Test series"
    assert [o["v"] for o in data["observations"]] == [1.0, 1.5, 2.0, 2.5]


def test_curve_picks_values_at_offsets(fake_fred: None) -> None:
    curves = {c["label"]: c for c in fred.curve()["curves"]}
    assert curves["Latest"]["points"][0]["yield"] == 2.5
    assert curves["1 month ago"]["points"][0]["yield"] == 2.0
    assert curves["1 year ago"]["points"][0]["yield"] == 1.5
    assert len(curves["Latest"]["points"]) == len(fred.TENORS)


def test_dashboard_rows_link_to_series_and_calendar_filters(fake_fred: None) -> None:
    doc = fred.dashboard()
    first = doc["blocks"][0]["rows"][0]
    assert first["cmd"].startswith("ECON ") and first["cells"][1] == 2.5 and first["cells"][3] == 0.5
    calendar = doc["blocks"][-1]
    assert [r["cells"][1] for r in calendar["rows"]] == ["Employment Situation"]


def test_missing_key_message(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(fred.settings, "fred_api_key", "")
    with pytest.raises(fred.MissingKey, match="Settings"):
        fred._get("series", series_id="X")
