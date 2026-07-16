#!/usr/bin/env python3
"""
License-check client for the Tarang2_dp1 image. Called from entrypoint.sh
before the project folder ($WORK) is populated -- see the "License gate" block
there. Talks to the same license-api that docker-license-test/client/
license_check.py talks to (identical request/response shape).

Usage:
    tarang2p1-license-check.py activate <license_key> <fingerprint>
    tarang2p1-license-check.py validate <license_key> <fingerprint>

Exit code 0 + ok:true on success, non-zero otherwise -- entrypoint.sh only
checks the exit code.
"""

import os
import sys
import json
import urllib.request
import urllib.error

API_BASE_URL = os.environ.get("LICENSE_API_BASE_URL", "")


def call(endpoint: str, license_key: str, fingerprint: str) -> dict:
    url = f"{API_BASE_URL}/{endpoint}"
    payload = json.dumps({"license_key": license_key, "fingerprint": fingerprint}).encode()
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"}, method="POST")

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return {"http_status": resp.status, **json.loads(resp.read())}
    except urllib.error.HTTPError as e:
        return {"http_status": e.code, **json.loads(e.read())}
    except urllib.error.URLError as e:
        return {"http_status": 0, "ok": False, "error": f"unreachable: {e}"}


def main() -> int:
    if len(sys.argv) != 4 or sys.argv[1] not in ("activate", "validate") or not API_BASE_URL:
        print(__doc__)
        return 1

    _, action, license_key, fingerprint = sys.argv
    result = call(action, license_key, fingerprint)
    print(json.dumps(result))

    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
