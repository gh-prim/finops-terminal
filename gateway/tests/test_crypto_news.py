from finops_gateway.providers import crypto_news

RSS = b"""<?xml version="1.0"?><rss><channel>
<item><title>Bitcoin tops $80K &amp; climbs</title><link>https://example.com/a</link>
<pubDate>Sun, 18 Oct 2026 10:00:00 +0000</pubDate><description><![CDATA[<p>BTC rallied.</p>]]></description>
<category>Markets</category></item>
<item><title>Optimism op-ed on L2s</title><link>https://example.com/b</link>
<pubDate>Sun, 18 Oct 2026 09:00:00 +0000</pubDate><description>an op-ed</description></item>
<item><title></title></item>
</channel></rss>"""


def test_parse_strips_markup_and_reads_dates() -> None:
    items = crypto_news.parse("Test", RSS)
    assert [i["title"] for i in items] == ["Bitcoin tops $80K & climbs", "Optimism op-ed on L2s"]
    assert items[0]["summary"] == "BTC rallied." and items[0]["tags"] == ["Markets"]
    assert items[0]["time"] == 1792317600.0


def test_mentions_matches_ticker_words_and_names() -> None:
    btc, op = crypto_news.parse("Test", RSS)
    assert crypto_news.mentions(btc, "BTC")
    assert not crypto_news.mentions(btc, "ETH")
    assert crypto_news.mentions(op, "OP")          # by name ("Optimism"), not by "op-ed"
    assert not crypto_news.mentions(btc, "OP")
