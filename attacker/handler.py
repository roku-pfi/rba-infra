"""Attacker Lambda (I-6, ADR-0035): run the IdP login from another region.

One copy per region (Tokyo, Frankfurt, São Paulo). Its egress address is a real
AWS address there, so the IdP geolocates a real foreign country and a hosting
ASN. Nothing is simulated: it is the same `POST /login` a browser sends.

Invoked through its function URL by the presenter panel (D-1):

    POST <function url>
    X-RokuSec-Attacker-Secret: <ATTACKER_SECRET>
    {"client_id": "rk_…", "email": "martin@correo.example",
     "passwords": ["…", "…"], "pause_ms": 300}

and answers with what the IdP said to each attempt. It cannot complete a
passkey, so a challenge is where the attack ends.

Stdlib only, so the package is this one file.
"""

from __future__ import annotations

import base64
import hmac
import json
import os
import time
import urllib.error
import urllib.request

MAX_ATTEMPTS = 20
TIMEOUT_SECONDS = 8
# What a stuffing kit claims to be: the most common desktop browser, as real
# kits do and as Wiefling et al.'s VPN attacker does (ADR-0043). The IdP
# records it like any browser's.
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/129.0 Safari/537.36"
)


def _response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }


def _authorized(event: dict, secret: str) -> bool:
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    given = headers.get("x-rokusec-attacker-secret", "")
    return bool(secret) and hmac.compare_digest(given, secret)


def _body(event: dict) -> dict:
    raw = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode()
    return json.loads(raw)


def _egress_ip() -> str | None:
    try:
        with urllib.request.urlopen("https://checkip.amazonaws.com", timeout=3) as resp:
            return resp.read().decode().strip()
    except (urllib.error.URLError, TimeoutError):
        return None


def attempt(idp_url: str, *, client_id: str, email: str, password: str) -> dict:
    """One login. The IdP takes the address from the connection, not from here."""
    payload = {
        "email": email,
        "password": password,
        "client_id": client_id,
        # Required by the contract, replaced by the IdP in the cloud (ADR-0032).
        "ip_address": "0.0.0.0",
        "device_type": "desktop",
        "os": "Windows",
        "browser": "Chrome",
        "user_agent": USER_AGENT,
    }
    req = urllib.request.Request(
        f"{idp_url.rstrip('/')}/login",
        data=json.dumps(payload).encode(),
        headers={"content-type": "application/json", "user-agent": USER_AGENT},
        method="POST",
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
            status, data = resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        try:
            status, data = exc.code, json.loads(exc.read() or b"{}")
        except ValueError:
            status, data = exc.code, {}
    except (urllib.error.URLError, TimeoutError) as exc:
        return {"status": None, "outcome": "UNREACHABLE", "detail": str(exc)}
    return {
        "status": status,
        "outcome": data.get("outcome", f"HTTP_{status}"),
        "ms": round((time.monotonic() - started) * 1000),
    }


def handler(event: dict, _context=None) -> dict:
    if not _authorized(event, os.environ.get("ATTACKER_SECRET", "")):
        return _response(404, {"detail": "not found"})
    try:
        body = _body(event)
        client_id = str(body["client_id"])
        email = str(body["email"])
        passwords = [str(p) for p in body["passwords"]][:MAX_ATTEMPTS]
        pause = max(0, min(int(body.get("pause_ms", 300)), 5000)) / 1000
    except (ValueError, KeyError, TypeError):
        return _response(400, {"detail": "client_id, email and passwords are required"})

    idp_url = os.environ["IDP_URL"]
    results = []
    for i, password in enumerate(passwords):
        if i:
            time.sleep(pause)
        results.append(attempt(idp_url, client_id=client_id, email=email, password=password))
    return _response(
        200,
        {
            "region": os.environ.get("AWS_REGION", "local"),
            "egress_ip": _egress_ip(),
            "attempts": results,
        },
    )
