"""The attacker against a stub IdP: `python3 -m pytest attacker/`."""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

import handler

SECRET = "s" * 40


class _Idp(BaseHTTPRequestHandler):
    seen: list[dict] = []

    def do_POST(self):  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        _Idp.seen.append(body)
        outcome = "MFA_REQUIRED" if body["password"] == "right" else "INVALID_CREDENTIALS"
        data = json.dumps({"outcome": outcome}).encode()
        self.send_response(200 if outcome == "MFA_REQUIRED" else 401)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


@pytest.fixture
def idp(monkeypatch):
    server = HTTPServer(("127.0.0.1", 0), _Idp)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    _Idp.seen = []
    monkeypatch.setenv("IDP_URL", f"http://127.0.0.1:{server.server_port}")
    monkeypatch.setenv("ATTACKER_SECRET", SECRET)
    monkeypatch.setattr(handler, "_egress_ip", lambda: "203.0.113.7")
    yield
    server.shutdown()


def _event(body: dict, secret: str = SECRET) -> dict:
    return {"headers": {"X-RokuSec-Attacker-Secret": secret}, "body": json.dumps(body)}


def test_reports_each_attempt(idp) -> None:
    resp = handler.handler(
        _event({"client_id": "rk_x", "email": "m@x", "passwords": ["bad", "right"], "pause_ms": 0})
    )
    assert resp["statusCode"] == 200
    out = json.loads(resp["body"])
    assert [a["outcome"] for a in out["attempts"]] == ["INVALID_CREDENTIALS", "MFA_REQUIRED"]
    assert out["egress_ip"] == "203.0.113.7"
    assert _Idp.seen[0]["client_id"] == "rk_x"
    # No country or ASN: the IdP must see where the request really comes from.
    assert "country" not in _Idp.seen[0] and "asn" not in _Idp.seen[0]


def test_wrong_secret_is_404_and_sends_nothing(idp) -> None:
    resp = handler.handler(_event({"client_id": "rk_x", "email": "m@x", "passwords": ["a"]}, "nope"))
    assert resp["statusCode"] == 404
    assert _Idp.seen == []


def test_attempts_are_capped(idp) -> None:
    resp = handler.handler(
        _event({"client_id": "rk_x", "email": "m@x", "passwords": ["x"] * 50, "pause_ms": 0})
    )
    assert len(json.loads(resp["body"])["attempts"]) == handler.MAX_ATTEMPTS


def test_missing_fields_is_400(idp) -> None:
    assert handler.handler(_event({"email": "m@x"}))["statusCode"] == 400
