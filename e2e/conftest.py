"""End-to-end harness for the scenario map (ADR-0035) on a running cluster.

Real browsers (Playwright Chromium) through the real hosted login, with Chrome's
virtual authenticator standing in for a fingerprint reader. Passkeys are
enrolled the way a person would: an activation code (issued with kubectl, as
an operator would) entered at /activate. What Diego would see is read from the
console's own API with his session.

Configuration (environment, defaults = k3d):

    E2E_IDP_URL          http://localhost:8080
    E2E_BANK_URL         http://demo.localhost:8080
    E2E_KAZE_URL         http://kaze.localhost:8080
    E2E_KUBE_CONTEXT     k3d-rba
    E2E_PASSWORD_SUFFIX  demo           (cloud: tofu output seed_password_suffix)
    E2E_PRESENTER_SECRET                (cloud: tofu output presenter_secret)
    E2E_HEADED           1 to watch
"""

from __future__ import annotations

import os
import re
import subprocess
import time
from dataclasses import dataclass, field
from urllib.parse import urlsplit

import httpx
import pytest
from playwright.sync_api import Browser, Page, sync_playwright

IDP = os.environ.get("E2E_IDP_URL", "http://localhost:8080").rstrip("/")
BANK = os.environ.get("E2E_BANK_URL", "http://demo.localhost:8080").rstrip("/")
KAZE = os.environ.get("E2E_KAZE_URL", "http://kaze.localhost:8080").rstrip("/")
KUBE_CONTEXT = os.environ.get("E2E_KUBE_CONTEXT", "k3d-rba")
SUFFIX = os.environ.get("E2E_PASSWORD_SUFFIX", "demo")
PRESENTER_SECRET = os.environ.get("E2E_PRESENTER_SECRET", "")

SESSION_KEY = "rba.idp.session"  # rba_idp/web/static/login.js
TENANT_HEADER = "X-RokuSec-Tenant"
POLICY_CACHE_SECONDS = 5  # rba_decision_service.config.policy_cache_seconds
# Panels of the hosted login that end a step (login.js `panels`).
END_PANELS = ("challenge", "blocked", "denied", "nofactor", "unavailable", "offer", "session")


def kubectl(*args: str, timeout: int = 180) -> str:
    out = subprocess.run(
        ["kubectl", "--context", KUBE_CONTEXT, *args],
        capture_output=True, text=True, timeout=timeout,
    )
    if out.returncode != 0:
        raise RuntimeError(f"kubectl {' '.join(args)}: {out.stderr.strip()}")
    return out.stdout


def activation_code(email: str, tenant: str) -> str:
    out = kubectl(
        "-n", "rba", "exec", "deploy/idp", "-c", "idp", "--",
        "python", "-m", "rba_idp.activation", email, "--tenant", tenant,
    )
    return out.split()[0]


_READ_FAILURES = (
    "import json, os, redis, sys; "
    "r = redis.Redis.from_url(os.environ['REDIS_URL'], decode_responses=True); "
    "raw = r.get('rba:profile:' + sys.argv[1]); "
    "print(len(json.loads(raw).get('failed_login_ts', [])) if raw else 0)"
)


def failed_logins(user_id: str) -> int:
    """Failures in the user's window, read where the PDP reads them (the
    profile store), from inside the profile-service pod: works on k3d and EKS."""
    out = kubectl("-n", "rba", "exec", "deploy/profile-service", "-c", "profile-service", "--",
                  "python", "-c", _READ_FAILURES, user_id)
    return int(out.strip())


def wait_for_failures(user_id: str, at_least: int, timeout: float = 120) -> int:
    """Failures travel journal → queue → profile-service; under a backlog (after
    the load scene) that takes a while. Wait for them instead of guessing."""
    deadline = time.monotonic() + timeout
    while (n := failed_logins(user_id)) < at_least:
        if time.monotonic() > deadline:
            raise AssertionError(f"{user_id}: {n} failures in the window, expected {at_least}")
        time.sleep(1)
    return n


# Relayed entries are deleted from the stream, so its length is the backlog.
_JOURNAL_BACKLOG = (
    "import os, redis; "
    "print(redis.Redis.from_url(os.environ['REDIS_URL']).xlen('rba:events'))"
)


def wait_for_profiles_to_catch_up(timeout: float = 600) -> None:
    """Every decision event relayed (journal → event-publisher) and consumed
    (queue → profile-service). Until then the PDP scores against a stale
    profile; after the load scene the journal is where the backlog builds."""
    deadline = time.monotonic() + timeout
    while True:
        journal = int(kubectl("-n", "rba", "exec", "deploy/event-publisher", "--",
                              "python", "-c", _JOURNAL_BACKLOG).strip())
        out = kubectl("-n", "rba", "exec", "deploy/rabbitmq", "--",
                      "rabbitmqctl", "-q", "list_queues", "name", "messages", timeout=120)
        queued = sum(int(n) for name, n in (l.split() for l in out.splitlines() if l.strip())
                     if name.startswith("rba.profile."))
        if journal == 0 and queued == 0:
            return
        if time.monotonic() > deadline:
            raise AssertionError(f"profiles behind: {journal} unrelayed, {queued} queued")
        time.sleep(3)


def _host(url: str) -> str:
    return urlsplit(url).netloc


@dataclass
class Login:
    """What happened to one login, as the person saw it."""

    outcome: str | None          # the IdP's answer to the password (LoginOutcome)
    challenged: bool             # a passkey was asked for
    panel: str | None            # the login panel it ended on, if it stayed there
    landed: str                  # final URL
    event_id: str | None = None  # decision id, when the login was scored


@dataclass
class Persona:
    email: str
    tenant: str
    page: Page
    password: str = field(init=False)

    def __post_init__(self) -> None:
        self.password = f"{self.email.split('@', 1)[0]}-{SUFFIX}"

    # ------------------------------------------------------------ passkey

    def enroll(self) -> None:
        """Activation code → /activate → passkey on this persona's authenticator."""
        code = activation_code(self.email, self.tenant)
        p = self.page
        p.goto(f"{IDP}/activate")
        p.fill("#code", code)
        p.fill("#password", self.password)
        p.click("#activate-submit")
        p.wait_for_selector("#panel-create:not([hidden])", timeout=10_000)
        p.click("#create-submit")
        p.wait_for_selector("#panel-done:not([hidden])", timeout=10_000)

    # ------------------------------------------------------------ login

    def login(self, start_url: str, *, complete_challenge: bool = True) -> Login:
        """Open an app (or a login URL) and sign in, the way a person would."""
        p = self.page
        answer = self._submit(start_url, self.password)
        outcome, event_id = answer.get("outcome"), answer.get("event_id")
        panel = self._settle()
        challenged = panel == "challenge"
        if challenged and complete_challenge:
            p.wait_for_function("!document.getElementById('mfa-submit').disabled", timeout=10_000)
            p.click("#mfa-submit")
            # The panel stays up while the ceremony runs; it ends by leaving
            # the IdP or by an error under the button.
            p.wait_for_function(
                "() => document.getElementById('panel-challenge')?.hidden !== false"
                " || (document.getElementById('mfa-error')?.textContent || '').trim()",
                timeout=20_000,
            )
            error = p.locator("#mfa-error").all_inner_texts() if p.locator("#mfa-error").count() else []
            panel = self._settle()
            if panel == "challenge":
                raise AssertionError(f"passkey step failed: {error}")
        return Login(outcome, challenged, panel, p.url, event_id)

    def wrong_password(self, start_url: str) -> str | None:
        """One attempt with a wrong password; the IdP's answer (INVALID_CREDENTIALS)."""
        answer = self._submit(start_url, f"{self.password}-typo")
        self.page.wait_for_selector("#login-error:not([hidden])", timeout=10_000)
        return answer.get("outcome")

    def _submit(self, start_url: str, password: str) -> dict:
        """Fill the hosted login and send it; the IdP's JSON answer."""
        p = self.page
        self.forget_sessions()
        p.goto(start_url)
        p.wait_for_selector("#form-login", state="visible", timeout=15_000)
        p.fill("#email", self.email)
        p.fill("#password", password)
        # Read the answer on its way to the page: on ALLOW the page navigates at
        # once, and a remote host loses that race for the browser's own copy.
        answer: dict = {}

        def grab(route) -> None:
            if route.request.method != "POST":
                route.continue_()
                return
            resp = route.fetch()
            answer.update(_json(resp))
            route.fulfill(response=resp)

        p.route(LOGIN_POST, grab)
        try:
            with p.expect_response(lambda r: r.request.method == "POST" and LOGIN_POST.match(r.url)):
                p.click("#login-submit")
        finally:
            p.unroute(LOGIN_POST, grab)
        return answer

    def _settle(self) -> str | None:
        """Wait until the login leaves the IdP, or stops on a panel."""
        p = self.page
        idp = _host(IDP)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if _host(p.url) != idp or p.url.startswith(f"{IDP}/admin"):
                p.wait_for_load_state()
                return None
            for name in END_PANELS:
                if p.locator(f"#panel-{name}:not([hidden])").count():
                    if name == "offer":
                        p.click("#offer-skip")
                        break
                    return name
            p.wait_for_timeout(200)
        raise AssertionError(f"login did not settle; at {p.url}")

    def forget_sessions(self) -> None:
        """A fresh visit: no app cookies, no IdP session in this tab."""
        self.page.context.clear_cookies()
        if _host(self.page.url) == _host(IDP):
            self.page.evaluate(f"sessionStorage.removeItem('{SESSION_KEY}')")

    def idp_token(self) -> str:
        return self.page.evaluate(f"sessionStorage.getItem('{SESSION_KEY}')")


LOGIN_POST = re.compile(r"[^?]*login(\?.*)?$")


def _json(response) -> dict:
    try:
        return response.json()
    except Exception:  # noqa: BLE001 - an empty or HTML body is just "no outcome"
        return {}


class Console:
    """The console's API, as an operator (what Diego's screens show)."""

    def __init__(self, token: str, tenant: str) -> None:
        self._http = httpx.Client(
            base_url=IDP,
            headers={"Authorization": f"Bearer {token}", TENANT_HEADER: tenant},
            timeout=10,
        )

    def get(self, path: str, **kw) -> httpx.Response:
        return self._http.get(f"/admin/api{path}", **kw)

    def put(self, path: str, **kw) -> httpx.Response:
        return self._http.put(f"/admin/api{path}", **kw)

    def decision(self, event_id: str, wait: float = 15) -> dict:
        """The recorded decision. The record is written asynchronously, so wait for it."""
        deadline = time.monotonic() + wait
        while True:
            resp = self.get(f"/decisions/{event_id}")
            if resp.status_code == 200:
                return resp.json()
            if time.monotonic() > deadline:
                raise AssertionError(f"decision {event_id} never recorded ({resp.status_code})")
            time.sleep(0.5)

    def policy(self) -> dict:
        resp = self.get("/policy")
        resp.raise_for_status()
        return resp.json()

    def set_policy(self, **changes) -> dict:
        """Save a policy change and wait until every PDP replica uses it: each
        caches the tenant's policy for POLICY_CACHE_SECONDS (decision-service
        config). The IdP drops its own copy on save."""
        resp = self.put("/policy", json={**self.policy(), **changes})
        assert resp.status_code == 200, resp.text
        time.sleep(POLICY_CACHE_SECONDS + 1)
        return resp.json()


class Presenter:
    """The presenter panel's actions (D-1)."""

    def __init__(self) -> None:
        self._http = httpx.Client(base_url=BANK, timeout=180)
        if PRESENTER_SECRET:
            self._http.post("/presenter/login", data={"secret": PRESENTER_SECRET})

    def post(self, path: str, **params) -> dict:
        resp = self._http.post(f"/presenter{path}", params=params)
        assert resp.status_code == 200, f"{path}: {resp.status_code} {resp.text[:200]}"
        return resp.json()

    def get(self, path: str) -> dict:
        resp = self._http.get(f"/presenter{path}")
        assert resp.status_code == 200, f"{path}: {resp.status_code}"
        return resp.json()

    def travel_url(self) -> str:
        resp = self._http.get("/presenter/travel", follow_redirects=False)
        assert resp.status_code == 302, resp.text
        return resp.headers["location"]


# ---------------------------------------------------------------- fixtures


@pytest.fixture(scope="session")
def browser() -> Browser:
    with sync_playwright() as pw:
        b = pw.chromium.launch(headless=os.environ.get("E2E_HEADED") != "1")
        yield b
        b.close()


def _persona(browser: Browser, email: str, tenant: str) -> Persona:
    context = browser.new_context(locale="es-AR")
    page = context.new_page()
    cdp = context.new_cdp_session(page)
    cdp.send("WebAuthn.enable")
    cdp.send("WebAuthn.addVirtualAuthenticator", {"options": {
        "protocol": "ctap2", "transport": "internal", "hasResidentKey": True,
        "hasUserVerification": True, "isUserVerified": True,
        "automaticPresenceSimulation": True,
    }})
    persona = Persona(email, tenant, page)
    persona.enroll()
    return persona


@pytest.fixture(scope="session")
def martin(browser) -> Persona:
    return _persona(browser, "martin@correo.example", "roku-bank")


@pytest.fixture(scope="session")
def diego(browser) -> Persona:
    return _persona(browser, "diego@rokubank.example", "roku-bank")


@pytest.fixture(scope="session")
def lucas(browser) -> Persona:
    return _persona(browser, "lucas@kazelabs.example", "kaze-labs")


@pytest.fixture(scope="session")
def valen(browser) -> Persona:
    return _persona(browser, "valen@kazelabs.example", "kaze-labs")


@pytest.fixture(scope="session")
def console(diego) -> Console:
    """Diego signed in to the console; his tenant's policy is restored afterwards."""
    result = diego.login(f"{IDP}/console/login")
    assert diego.page.url.startswith(f"{IDP}/admin"), result
    c = Console(diego.idp_token(), "roku-bank")
    original = c.policy()
    yield c
    c.put("/policy", json=original)


@pytest.fixture(scope="session")
def presenter() -> Presenter:
    return Presenter()
