"""The scenario map (ADR-0035), end to end, in the order of the live script.

Each test is one row: who triggers it, what Martín sees, what Diego sees. They
share state on purpose, as the demo does (Martín's profile carries from one
scene to the next), so run the file as a whole and in order.
"""

from __future__ import annotations

import json
import os
import time
from datetime import datetime, timedelta, timezone
from urllib.parse import quote

import pytest

from conftest import BANK, KAZE, kubectl, wait_for_failures, wait_for_profiles_to_catch_up

MARTIN = "usr_rb_martin"
# A fresh cloud profile has no history: Martín's first logins are challenged
# by the engine too, until his usual context is familiar (ADR-0041).
WARMUP_MAX_LOGINS = 10


def codes(decision: dict) -> set[str]:
    return {r["code"] for r in decision["reasons"]}


def why(decision: dict) -> str:
    """A decision in one line, for assertion messages."""
    return (f"{decision['action']}/{decision['enforced_action']} {decision['risk_level']} "
            f"{decision['risk_score']:.2f} {sorted(codes(decision))}")


@pytest.fixture(scope="module", autouse=True)
def clean_start(martin, console, presenter):
    """Roku Bank as it starts the demo: passkey always, engine in monitor, and
    Martín's usual context familiar to the engine."""
    wait_for_profiles_to_catch_up()
    presenter.post("/reset", mode="failures")
    console.set_policy(base_policy="ALWAYS_MFA", engine_mode="MONITOR")
    for _ in range(WARMUP_MAX_LOGINS):
        login = martin.login(f"{BANK}/")
        if console.decision(login.event_id)["action"] == "ALLOW":
            break
    else:
        pytest.fail(f"the engine still challenges Martín after {WARMUP_MAX_LOGINS} usual logins")
    yield
    presenter.post("/reset", mode="failures")


def test_monitor_mode_applies_the_base_policy(martin, console):
    """Martín: passkey every time. Diego: MFA applied; what the engine would do."""
    login = martin.login(f"{BANK}/")
    assert login.challenged
    assert login.landed.startswith(BANK) and "Hola" in martin.page.content()

    d = console.decision(login.event_id)
    assert d["engine_mode"] == "MONITOR"
    assert d["enforced_action"] == "REQUIRE_MFA", why(d)
    assert d["action"] == "ALLOW", why(d)  # the engine would have let him in


def test_switch_to_active_lets_a_usual_login_in(martin, console):
    """Diego switches to active. Martín goes straight in."""
    console.set_policy(engine_mode="ACTIVE")
    login = martin.login(f"{BANK}/")
    d = console.decision(login.event_id)
    assert not login.challenged, why(d)
    assert login.landed.startswith(BANK)
    assert (d["engine_mode"], d["action"], d["enforced_action"]) == ("ACTIVE", "ALLOW", "ALLOW")
    assert d["risk_level"] == "LOW"


def test_impossible_travel_is_challenged_and_marked_simulated(martin, console, presenter):
    """Right after a usual login, a login 'from Japan': passkey, marked simulado."""
    login = martin.login(presenter.travel_url())
    assert login.challenged
    assert login.landed.startswith(BANK)

    d = console.decision(login.event_id)
    assert d["simulated"] is True
    assert d["enforced_action"] in ("REQUIRE_MFA", "REAUTHENTICATE"), why(d)
    assert "impossible_travel" in codes(d), why(d)


def _last_decision(console, since: datetime) -> dict:
    """Martín's newest decision after ``since``: the list is the read model,
    which the event-publisher fills a moment after the login (ADR-0044)."""
    deadline = time.monotonic() + 15
    while True:
        items = console.get("/decisions", params={"user_id": MARTIN, "limit": 1}).json()["items"]
        if items and datetime.fromisoformat(items[0]["occurred_at"]) >= since:
            return items[0]
        if time.monotonic() > deadline:
            raise AssertionError(f"no decision for Martín after {since}")
        time.sleep(0.5)


def _now() -> datetime:
    # A little early: the laptop's clock and the cluster's are not the same.
    return datetime.now(timezone.utc) - timedelta(seconds=2)


def test_login_from_tokyo_stops_at_the_passkey(console, presenter):
    """An attacker with Martín's real password, from a hosting network in Japan.

    The score itself must see it, not only the hosting-network rule: that rule
    always fires for this scene, and once hid a model that scored every login
    LOW (finding 2026-10-23).
    """
    since = _now()
    [tokyo] = presenter.post("/attack/tokyo")["regions"]
    [attempt] = tokyo["attempts"]
    assert attempt["outcome"] in ("MFA_REQUIRED", "REAUTH_REQUIRED"), tokyo

    d = _last_decision(console, since)
    assert d["enforced_action"] in ("REQUIRE_MFA", "REAUTHENTICATE"), why(d)
    assert d["login"]["country"] == "JP"
    assert d["risk_level"] in ("HIGH", "CRITICAL"), why(d)


def test_an_abandoned_step_up_teaches_the_profile_nothing(console, presenter):
    """The attacker never passed the passkey, so Japan is still new for Martín
    on the second attempt (ADR-0042)."""
    presenter.post("/attack/tokyo")
    wait_for_profiles_to_catch_up()
    since = _now()
    presenter.post("/attack/tokyo")
    d = _last_decision(console, since)
    assert d["features"]["country_seen_before"] == 0, why(d)
    assert d["features"]["asn_seen_before"] == 0, why(d)
    assert d["risk_level"] in ("HIGH", "CRITICAL"), why(d)


def test_stuffing_burst_makes_the_next_login_reauthenticate(martin, console, presenter):
    """Three wrong passwords from three regions; Martín re-enters credentials."""
    presenter.post("/reset", mode="failures")
    regions = presenter.post("/attack/stuffing", level="burst")["regions"]
    assert sum(len(r["attempts"]) for r in regions) == 3
    assert all(a["outcome"] == "INVALID_CREDENTIALS" for r in regions for a in r["attempts"])
    wait_for_failures(MARTIN, 3)

    login = martin.login(f"{BANK}/")
    d = console.decision(login.event_id)
    assert login.challenged and login.landed.startswith(BANK), why(d)
    assert d["enforced_action"] == "REAUTHENTICATE", why(d)
    assert "failed_login_burst" in codes(d), why(d)


def test_sustained_stuffing_blocks_the_next_login(martin, console, presenter):
    """Twelve wrong passwords: past the lockout band, no challenge is offered."""
    presenter.post("/reset", mode="failures")
    regions = presenter.post("/attack/stuffing", level="lockout")["regions"]
    assert sum(len(r["attempts"]) for r in regions) == 12
    wait_for_failures(MARTIN, 12)

    login = martin.login(f"{BANK}/")
    d = console.decision(login.event_id)
    assert login.panel == "blocked" and not login.challenged, why(d)
    assert d["enforced_action"] == "BLOCK", why(d)
    assert "failed_login_lockout" in codes(d), why(d)

    presenter.post("/reset", mode="failures")


def test_engine_down_falls_back_to_a_passkey_never_a_lockout(martin):
    """Diego scales the PDP to zero. Martín is asked for his passkey and gets in."""
    # Back to the count it had (the HPA's minimum differs per environment): a
    # lower count is raised by the HPA later, in the middle of the load scene.
    replicas = kubectl("-n", "rba", "get", "deploy/decision-service", "-o", "jsonpath={.spec.replicas}")
    kubectl("-n", "rba", "scale", "deploy/decision-service", "--replicas=0")
    try:
        kubectl("-n", "rba", "wait", "--for=delete", "pod",
                "-l", "app.kubernetes.io/name=decision-service", "--timeout=120s")
        login = martin.login(f"{BANK}/")
        assert login.challenged
        assert login.landed.startswith(BANK)
    finally:
        kubectl("-n", "rba", "scale", "deploy/decision-service", f"--replicas={replicas}")
        kubectl("-n", "rba", "rollout", "status", "deploy/decision-service", "--timeout=180s")


def test_kaze_admin_reaches_every_page(lucas):
    login = lucas.login(f"{KAZE}/")
    assert login.landed.startswith(KAZE)
    for path, heading in (("/", "Lucas"), ("/proyectos", "Proyectos"), ("/configuracion", "Configuración")):
        resp = lucas.page.goto(f"{KAZE}{path}")
        assert resp.status == 200, path
        assert heading in lucas.page.locator("h1").inner_text()


def test_kaze_viewer_reads_but_cannot_change(valen):
    login = valen.login(f"{KAZE}/")
    assert login.landed.startswith(KAZE)
    page = valen.page

    assert page.goto(f"{KAZE}/proyectos").status == 200
    assert "Solo lectura" in page.content()
    assert page.locator("form[action='/proyectos']").count() == 0
    # Hiding the form is presentation; the POST is the control.
    refused = page.request.post(f"{KAZE}/proyectos", form={"nombre": "Intruso"})
    assert refused.status == 403

    resp = page.goto(f"{KAZE}/configuracion")
    assert resp.status == 403 and "Sin acceso" in page.content()


def test_tenants_are_isolated(console):
    """Roku Bank's Diego sees nothing of Kaze Labs."""
    emails = {u["email"] for u in console.get("/users").json()}
    assert "martin@correo.example" in emails
    assert not any(e.endswith("@kazelabs.example") for e in emails)

    decisions = console.get("/decisions", params={"limit": 200}).json()["items"]
    assert decisions and all(d["tenant_id"] == "roku-bank" for d in decisions)

    other = console.get("/users", headers={"X-RokuSec-Tenant": "kaze-labs"})
    assert other.status_code in (403, 404)


def pdp_p95_ms(seconds: int) -> float:
    """p95 of /risk/evaluate over the last ``seconds``, from Prometheus."""
    query = (
        "histogram_quantile(0.95, sum by (le) (increase("
        f'http_request_duration_seconds_bucket{{handler="/risk/evaluate"}}[{seconds}s])))'
    )
    out = kubectl(
        "-n", "rba", "exec", "deploy/prometheus", "--",
        "wget", "-qO-", f"http://localhost:9090/api/v1/query?query={quote(query)}",
    )
    [result] = json.loads(out)["data"]["result"]
    return float(result["value"][1]) * 1000


@pytest.mark.skipif(os.environ.get("E2E_LOAD") != "1", reason="slow; set E2E_LOAD=1")
def test_load_scales_the_pdp(presenter):
    """The presenter's load: no errors, and the PDP adds replicas.

    E2E_P95_MS sets the latency bound (RNF-07: 200 ms in the cloud); unset, the
    p95 is reported but not judged, since a laptop cluster says little about it.
    The bound is judged on the PDP's own histogram: the presenter's figure also
    counts its queueing behind 32 workers on a small pod.
    """
    def replicas() -> int:
        return int(kubectl("-n", "rba", "get", "deploy/decision-service", "-o", "jsonpath={.status.replicas}"))

    before = replicas()
    started = time.monotonic()
    assert presenter.post("/load")["started"]
    peak = before
    while True:
        time.sleep(5)
        peak = max(peak, replicas())
        snap = presenter.get("/load")
        if not snap["running"]:
            break
    pdp_p95 = pdp_p95_ms(seconds=int(time.monotonic() - started) + 30)
    print(f"load: {snap['sent']} requests, {snap['errors']} errors, p95 {pdp_p95:.0f} ms at the PDP "
          f"({snap['p95_ms']} ms at the presenter), replicas {before} → {peak}")
    # A request can time out while a new replica starts; a handful is not a failure.
    assert snap["sent"] > 0 and snap["errors"] / snap["sent"] < 0.005
    assert peak > before
    if os.environ.get("E2E_P95_MS"):
        assert pdp_p95 <= int(os.environ["E2E_P95_MS"])
    # Leave the platform as the next scene expects it: profiles current.
    wait_for_profiles_to_catch_up()
