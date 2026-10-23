"""Merge a fresh passkey export into the saved one (aws-down).

Union by credential id, higher counter wins, so a session where nobody enrolled
never wipes the passkeys saved by earlier ones.

    python3 scripts/merge-passkeys.py <saved.json> <new.json>
"""

import json
import sys
from pathlib import Path

saved_path, new_path = Path(sys.argv[1]), Path(sys.argv[2])
saved = json.loads(saved_path.read_text()) if saved_path.exists() else []
merged = {p["credential_id"]: p for p in saved}
for p in json.loads(new_path.read_text() or "[]"):
    old = merged.get(p["credential_id"])
    if old is None or int(p["sign_count"]) >= int(old["sign_count"]):
        merged[p["credential_id"]] = p
saved_path.write_text(json.dumps(list(merged.values())))
print(f"  {len(merged)} passkeys saved in {saved_path}")
