import pytest

from finops_gateway.providers import article


@pytest.mark.parametrize("url", ["file:///etc/passwd", "ftp://example.com/x", "http://127.0.0.1:8765/health",
                                 "http://localhost/", "http://192.168.1.1/", "http://[::1]/", "http://169.254.169.254/"])
def test_rejects_non_public_targets(url: str) -> None:
    with pytest.raises((ValueError, LookupError)):
        article.check_public(url)


def test_redirect_to_private_host_is_blocked() -> None:
    handler = article._PublicRedirects()
    with pytest.raises(ValueError):
        handler.redirect_request(None, None, 302, "Found", {}, "http://10.0.0.5/admin")
