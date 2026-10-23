# End-to-end tests: the scenario map

Every row of the scenario map ([ADR-0035](../../docs/decisions/0035-demo-around-personas-and-tenants.md))
as a test, in the order of the live script, against a running cluster. Real
Chromium through the real hosted login; Chrome's virtual authenticator holds the
passkeys, enrolled with activation codes the way an operator would hand them out.
What Diego would see is read from the console's API with his own session.

```bash
make e2e                       # k3d, ~1 min
E2E_LOAD=1 make e2e            # plus the load scene, ~2.5 min
E2E_HEADED=1 make e2e          # watch the browsers
```

| Test | Scene |
|---|---|
| `test_monitor_mode_applies_the_base_policy` | Monitor: passkey every time; engine would allow |
| `test_switch_to_active_lets_a_usual_login_in` | Diego switches to active; Martín goes straight in |
| `test_impossible_travel_is_challenged_and_marked_simulated` | Signed ticket from Japan: passkey, `simulated` |
| `test_login_from_tokyo_stops_at_the_passkey` | Attacker with the real password, hosting network in JP |
| `test_stuffing_burst_makes_the_next_login_reauthenticate` | 3 failures from 3 regions → REAUTHENTICATE |
| `test_sustained_stuffing_blocks_the_next_login` | 12 failures → BLOCK, no challenge |
| `test_engine_down_falls_back_to_a_passkey_never_a_lockout` | PDP scaled to 0 → passkey, still gets in |
| `test_kaze_admin_reaches_every_page` | Lucas (admin): Inicio, Proyectos, Configuración |
| `test_kaze_viewer_reads_but_cannot_change` | Valen (viewer): read-only, POST 403, settings 403 |
| `test_tenants_are_isolated` | Diego sees no Kaze Labs user or decision |
| `test_load_scales_the_pdp` (`E2E_LOAD=1`) | Errors under 0.5 %; PDP replicas grow; `E2E_P95_MS` bounds p95 |

The tests share state on purpose, as the demo does, so run the file whole. They
leave Roku Bank's policy as they found it and Martín's failure window empty.

## Against AWS

After `make aws-up` (kubectl already points at EKS):

```bash
cd rba-infra
E2E_IDP_URL=https://d1fg623tjiucw7.cloudfront.net \
E2E_BANK_URL=https://d3m6kfm1gma0g6.cloudfront.net \
E2E_KAZE_URL=https://d14wc5kuicqxf6.cloudfront.net \
E2E_KUBE_CONTEXT=$(kubectl config current-context) \
E2E_PASSWORD_SUFFIX=$(tofu -chdir=tofu/runtime output -raw seed_password_suffix) \
E2E_PRESENTER_SECRET=$(tofu -chdir=tofu/runtime output -raw presenter_secret) \
E2E_LOAD=1 E2E_P95_MS=200 make e2e
```

In the cloud Martín starts with no history; the suite first logs him in
ordinarily until the engine would let him in (at most 10 times), as the run
sheet does.

## Waits, and why

- After a policy change the suite waits 6 s: each PDP replica caches the policy
  for 5 s.
- Before the first scene and after the load, it waits until the decision journal
  (Valkey stream) and the profile queue are empty, so Martín is scored against a current profile.
- After a stuffing attack it waits until the failures are in Martín's profile
  (read from inside the profile-service pod) instead of sleeping a fixed time.

## Warm-up: a usual history without logging in by hand

```bash
make warm-up                          # Martín, 10 logins, k3d
make warm-up WHO="martin diego" N=15
make warm-up WHO=martin TARGET=aws    # after make aws-up
```

`e2e/warmup.py` logs personas in through the real hosted login with this
machine's IP and browser: real decisions (Diego sees them), learned through the
normal step-up confirmation (ADR-0042). Each persona's virtual passkey is kept
in `.session/` (gitignored) per environment, so it enrolls once.

## Passkeys across a cloud teardown

The passkeys on people's devices are bound to the IdP's CloudFront host, which
the permanent stack keeps. `make aws-down` saves the server's copy of every
enrolled passkey (`.session/passkeys.json`: credential ids, user ids, public
keys, counters) and `make aws-up` restores it after seeding the users, so phones
and laptops enrolled once keep working (`python -m rba_idp.passkeys`).
