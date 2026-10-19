from finops_gateway.config import settings
from finops_gateway.documents import column, document, row, table
from finops_gateway.intel import news_sentiment


def _doc():
    return document("News", [table("news", None, [column("time", "Time", "datetime"), column("title", "Headline"),
                                                  column("source", "Source")],
                                   [row([1, "Apple beats estimates", "Reuters"], url="u1"),
                                    row([2, "5 stocks to buy", "Fool"], url="u2")])], "src")


def test_annotate_without_key_leaves_document(monkeypatch):
    monkeypatch.setattr(settings, "anthropic_api_key", None)
    doc = _doc()
    assert news_sentiment.annotate(doc, "AAPL") is doc


def test_annotate_adds_claude_columns(monkeypatch):
    monkeypatch.setattr(settings, "anthropic_api_key", "test")
    monkeypatch.setattr(news_sentiment, "score", lambda subject, titles: {
        "items": {"Apple beats estimates": {"score": 0.7, "tone": "bullish", "impact": "high", "why": "earnings beat"}},
        "overall": {"score": 0.3, "summary": "Mostly positive."}})
    out = news_sentiment.annotate(_doc(), "AAPL")
    t = out["blocks"][0]
    assert [c["id"] for c in t["columns"]] == ["time", "sent", "impact", "title", "source"]
    assert t["rows"][0]["cells"][1] == 0.7 and t["rows"][0]["cells"][2] == "high"
    assert t["rows"][1]["cells"][1] is None and t["rows"][0]["url"] == "u1"
    assert out["notes"][0].startswith("Claude's read (+0.30)")


def test_annotate_reports_errors(monkeypatch):
    monkeypatch.setattr(settings, "anthropic_api_key", "test")
    monkeypatch.setattr(news_sentiment, "score", lambda subject, titles: {"error": "rate-limited"})
    out = news_sentiment.annotate(_doc(), "AAPL")
    assert out["blocks"][0]["columns"][1]["id"] == "title" and "rate-limited" in out["notes"]
