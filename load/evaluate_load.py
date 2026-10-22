#!/usr/bin/env python3
"""Concurrent POST /risk/evaluate so the PDP HPA can see CPU.

Stdlib only — runs in a Job from python:3.12-slim. Each request uses a fresh
event_id so the PDP actually scores (idempotent replay would be free).
"""

from __future__ import annotations

import json
import os
import random
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from datetime import datetime, timezone

TARGET = os.environ.get("PDP_URL", "http://decision-service:8000").rstrip("/")
DURATION = float(os.environ.get("DURATION_SECONDS", "180"))
WORKERS = int(os.environ.get("WORKERS", "24"))
APP_ID = os.environ.get("APPLICATION_ID", "roku-bank-web")
# ADR-0033: every evaluation names its tenant; the PDP 404s an unknown one.
TENANT_ID = os.environ.get("TENANT_ID", "roku-bank")

USERS = [f"load-user-{i}" for i in range(80)]
IPS = [f"203.0.113.{i}" for i in range(1, 80)]
COUNTRIES = ["AR", "NO", "US", "DE", "BR", "GB"]
DEVICES = ["mobile", "desktop"]
OSES = ["Android", "iOS", "Windows", "macOS"]
BROWSERS = ["Chrome", "Firefox", "Safari"]


def _one() -> int:
    body = {
        "event_id": str(uuid.uuid4()),
        "tenant_id": TENANT_ID,
        "application_id": APP_ID,
        "user_id": random.choice(USERS),
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ip_address": random.choice(IPS),
        "asn": "13335",
        "country": random.choice(COUNTRIES),
        "device_type": random.choice(DEVICES),
        "os": random.choice(OSES),
        "browser": random.choice(BROWSERS),
        "login_successful": True,
    }
    req = urllib.request.Request(
        f"{TARGET}/risk/evaluate",
        data=json.dumps(body).encode(),
        headers={"content-type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return int(resp.status)
    except urllib.error.HTTPError as exc:
        return int(exc.code)
    except Exception:
        return 0


def main() -> None:
    deadline = time.time() + DURATION
    ok = err = 0
    t0 = time.time()
    last_report = t0
    inflight: set = set()
    print(
        f"load start target={TARGET} workers={WORKERS} duration_s={DURATION:.0f}",
        flush=True,
    )
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        while time.time() < deadline or inflight:
            while time.time() < deadline and len(inflight) < WORKERS:
                inflight.add(pool.submit(_one))
            if not inflight:
                break
            done, pending = wait(inflight, timeout=1.0, return_when=FIRST_COMPLETED)
            inflight = set(pending)
            for fut in done:
                code = fut.result()
                if 200 <= code < 300:
                    ok += 1
                else:
                    err += 1
            now = time.time()
            if now - last_report >= 10:
                elapsed = now - t0
                print(
                    f"progress ok={ok} err={err} elapsed_s={elapsed:.0f} "
                    f"rps={ok / elapsed:.1f}",
                    flush=True,
                )
                last_report = now
    elapsed = time.time() - t0
    print(
        f"load done ok={ok} err={err} elapsed_s={elapsed:.1f} rps={ok / max(elapsed, 1e-6):.1f}",
        flush=True,
    )


if __name__ == "__main__":
    main()
