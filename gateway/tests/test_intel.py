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
