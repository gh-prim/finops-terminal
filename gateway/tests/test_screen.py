import pytest

from finops_gateway.providers.yahoo_research import parse_filters


def test_parse_filters_normalizes_and_builds_query() -> None:
    query, normalized = parse_filters(["mcap>10b", "PE<20", "SECTOR=TECHNOLOGY"])
    assert normalized == ["MCAP>10B", "PE<20", "SECTOR=TECHNOLOGY"]
    text = str(query)
    assert "10000000000.0" in text and "Technology" in text and "region" in text


@pytest.mark.parametrize("bad", ["FOO>1", "MCAP", "SECTOR=NOPE", "PE<abc"])
def test_parse_filters_rejects(bad: str) -> None:
    with pytest.raises(ValueError):
        parse_filters([bad])
