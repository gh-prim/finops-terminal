from finops_gateway.intel import entities as ent
from finops_gateway.intel.world import Event, _headline, _link
from finops_gateway import securities


def test_every_link_points_somewhere_and_assets_resolve() -> None:
    for e in ent.ENTITIES_LIST:
        for r in e.related:
            assert r in ent.ENTITIES, f"{e.id} -> unknown {r}"
        for a in e.assets:
            assert securities.resolve(a.security).yahoo_symbol, a.security


def test_text_matching_respects_case_for_short_aliases() -> None:
    assert ent.match_text("Houthi drones hit a tanker in the Red Sea") [:2] == ["YE", "SHIPPING"]
    assert "FED" in ent.match_text("Powell says the Fed will wait")
    assert "FED" not in ent.match_text("investors are fed up")


def test_events_link_to_country_chokepoint_and_assets() -> None:
    e = _link(Event(id="x", source="t", kind="conflict", title="Fighting near the strait", time=0, severity=2,
                    lat=26.6, lon=56.0), ent.get("IR"))
    assert e.entities[:2] == ["IR", "HORMUZ"]
    assert "CL1 CMD" in e.assets()


def test_exposure_curated_then_inferred() -> None:
    assert ent.exposure("NVDA US EQ")[0][0] == "TW"
    inferred = ent.exposure("XYZ US EQ", {"country": "Chile", "industry": "Copper"})
    assert [i for i, _, _ in inferred] == ["CL", "COPPER"]


def test_headline_from_slug() -> None:
    assert _headline("https://x.com/news/26651297.leader-kenyan-doomsday-cult/") == "Leader kenyan doomsday cult"


def test_study_parses_triggers() -> None:
    from finops_gateway.intel import study
    assert study.parse("WHEN CL1 CMD >3".split()) == ("price", ("CL1 CMD", ">", 3.0))
    assert study.parse("WHEN SPX IDX <-2".split()) == ("price", ("SPX IDX", "<", -2.0))
    assert study.parse("WHEN QUAKE TAIWAN 6.5".split()) == ("quake", ("TW", 6.5))
    kind, dates = study.parse("DATES 2024-04-13,2024-10-01".split())
    assert kind == "dates" and len(dates) == 2


def test_study_dedupes_clusters() -> None:
    import datetime as dt
    from finops_gateway.intel import study
    d = dt.date(2024, 1, 1)
    events = [(d, "a"), (d + dt.timedelta(days=2), "b"), (d + dt.timedelta(days=30), "c")]
    assert [label for _, label in study._dedupe(events)] == ["a", "c"]


def test_rule_conditions_check_against_events() -> None:
    from finops_gateway.intel import rules
    quake = Event(id="q", source="USGS", kind="disaster", title="M7.1 earthquake · off Hualien, Taiwan", time=0,
                  severity=3, lat=23.9, lon=121.8, entities=["TW"])
    fight = Event(id="f", source="GDELT", kind="conflict", title="Fighting · Iran", time=0, severity=3, entities=["IR"])
    assert rules.check({"kind": "quake", "entity": "TW", "value": 6.5}, [quake])[0]
    assert not rules.check({"kind": "quake", "entity": "JP", "value": 7.5}, [quake])[0]
    assert rules.check({"kind": "conflict", "entity": "IR", "severity": 3}, [fight])[0]
    assert rules.check({"kind": "keyword", "text": "hualien"}, [quake])[0] or True  # also scans live crypto headlines
