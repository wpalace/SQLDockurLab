"""websockify auth plugin for the lab consoles: loopback origin, same port.

websockify loads it with --auth-plugin console_auth.LoopbackOrigin (PYTHONPATH must contain this
directory). It runs inside the runtime image (Python 3.13). A WebSocket upgrade is accepted only
when the page that opens it was served from 127.0.0.1, localhost or ::1 on the exact port of the
request (Origin host and port equal the Host header). The console token is checked separately by
the TokenFile token plugin.
"""

from urllib.parse import urlsplit

from websockify.auth_plugins import AuthenticationError

LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})


def _host_port(url):
    """Return (hostname, port) of a URL; (None, None) when it cannot be parsed."""
    try:
        parts = urlsplit(url)
        return parts.hostname, parts.port
    except ValueError:
        return None, None


class LoopbackOrigin:
    """Accept only same-port loopback origins."""

    def __init__(self, src=None):
        self.source = src

    def authenticate(self, headers, target_host, target_port):
        origin = headers.get("Origin") or ""
        host = headers.get("Host") or ""
        o_host, o_port = _host_port(origin)
        h_host, h_port = _host_port("//" + host)
        scheme = origin.split("://", 1)[0]
        if (
            scheme not in ("http", "https")
            or o_host not in LOOPBACK_HOSTS
            or h_host not in LOOPBACK_HOSTS
            or o_port is None
            or o_port != h_port
        ):
            raise AuthenticationError(
                log_msg="origin not allowed", response_code=403, response_msg="Forbidden"
            )
