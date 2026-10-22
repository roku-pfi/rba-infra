#!/usr/bin/env bash
# Reset the k3d demo profile to the pristine home seed.
# Retries because a freshly-seeded blob can still be overwritten by an
# in-flight decision event that has not yet been consumed.
set -uo pipefail
K=(kubectl --context k3d-rba -n rba)
for i in $(seq 6); do
  "${K[@]}" exec deploy/redis -- redis-cli DEL rba:profile:usr_rb_martin >/dev/null
  "${K[@]}" rollout restart deploy/profile-service >/dev/null 2>&1
  "${K[@]}" rollout status deploy/profile-service --timeout=120s >/dev/null 2>&1
  until [ "$("${K[@]}" exec deploy/redis -- redis-cli EXISTS rba:profile:usr_rb_martin 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done
  sleep 4
  sig=$("${K[@]}" exec deploy/redis -- redis-cli GET rba:profile:usr_rb_martin | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["login_count"],len(d.get("failed_login_ts",[])),",".join(sorted(d.get("seen_ips",[]))))' 2>/dev/null)
  if [ "$sig" = "98 0 203.0.113.10" ]; then echo "pristine seed: $sig"; exit 0; fi
  echo "  retry $i (saw: $sig)"
done
echo "WARN: could not reach pristine seed"; exit 1
