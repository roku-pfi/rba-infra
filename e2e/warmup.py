"""Build a usual login history for demo personas, through the real login.

    scripts/warm-up.sh martin            10 logins as Martín (k3d)
    scripts/warm-up.sh martin diego -n 15
    TARGET=aws scripts/warm-up.sh martin

Each login goes through the hosted login exactly as a person's would: password,
the tenant's passkey step on a virtual authenticator, the engine's decision
(recorded, visible to Diego), and the profile learning it once the step-up is
passed (ADR-0042). Nothing is written to a profile directly. The history is that
of this machine (its IP, Chromium on this OS), which is the context the
presenter's own browser has.

The virtual passkey is kept in rba-infra/.session/ (gitignored) per environment,
so a persona enrolls once; `aws-down` saves the server's side of it as well.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

from conftest import BANK, IDP, KAZE, Persona

PERSONAS = {
    "martin": ("martin@correo.example", "roku-bank", lambda: f"{BANK}/"),
    "diego": ("diego@rokubank.example", "roku-bank", lambda: f"{IDP}/console/login"),
    "juan": ("juan@rokusec.example", "rokusec", lambda: f"{IDP}/console/login"),
    "lucas": ("lucas@kazelabs.example", "kaze-labs", lambda: f"{KAZE}/"),
    "valen": ("valen@kazelabs.example", "kaze-labs", lambda: f"{KAZE}/"),
}
SESSION = Path(__file__).resolve().parents[1] / ".session"


def _store(who: str) -> Path:
    host = IDP.split("://", 1)[1].split("/", 1)[0].replace(":", "_")
    return SESSION / f"warmup-{host}-{who}.json"


def warm_up(browser, who: str, logins: int) -> None:
    email, tenant, start = PERSONAS[who]
    context = browser.new_context(locale="es-AR")
    page = context.new_page()
    cdp = context.new_cdp_session(page)
    cdp.send("WebAuthn.enable")
    authenticator = cdp.send("WebAuthn.addVirtualAuthenticator", {"options": {
        "protocol": "ctap2", "transport": "internal", "hasResidentKey": True,
        "hasUserVerification": True, "isUserVerified": True,
        "automaticPresenceSimulation": True,
    }})["authenticatorId"]
    persona = Persona(email, tenant, page)

    store = _store(who)
    saved = json.loads(store.read_text()) if store.exists() else None
    if saved:
        cdp.send("WebAuthn.addCredential", {"authenticatorId": authenticator, "credential": saved})
    try:
        first = persona.login(start())
        # Stopped on a panel (no passkey on the server, denied): not in yet.
        enroll = first.panel is not None
    except AssertionError:
        # A passkey was asked for and this authenticator has none the server knows.
        enroll = True
    if enroll:
        print(f"  {who}: enrolling a passkey (activation code via kubectl)")
        persona.enroll()
        first = persona.login(start())
        if first.panel is not None:
            raise SystemExit(f"{who}: still not in after enrolling ({first.panel})")
    print(f"  {who}: login 1/{logins}{' (passkey)' if first.challenged else ''}")
    for i in range(2, logins + 1):
        result = persona.login(start())
        print(f"  {who}: login {i}/{logins}{' (passkey)' if result.challenged else ''}")
    # Keep the passkey (and the counter the server last saw) for the next run.
    creds = cdp.send("WebAuthn.getCredentials", {"authenticatorId": authenticator})["credentials"]
    if creds:
        SESSION.mkdir(exist_ok=True)
        store.write_text(json.dumps(creds[-1]))
        os.chmod(store, 0o600)
    context.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("who", nargs="+", choices=sorted(PERSONAS))
    parser.add_argument("-n", "--logins", type=int, default=10)
    args = parser.parse_args()
    print(f"warm-up against {IDP}")
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=os.environ.get("E2E_HEADED") != "1")
        for who in args.who:
            warm_up(browser, who, args.logins)
        browser.close()
    print("done; the last decisions may take a few seconds to reach the profile")
    return 0


if __name__ == "__main__":
    sys.exit(main())
