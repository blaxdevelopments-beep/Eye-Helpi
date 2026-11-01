#  tools/blax_dev.py
#  Blax Developments API client for Eye~Helpi.
#
#  Talks to BlaxDevelopments.com on behalf of the agent, authenticated with
#  the creator's BLAXDEV_API_KEY. The key is read from (in order):
#    1. the BLAXDEV_API_KEY environment variable
#    2. ~/.eyehelpi/blaxdev.key  (set once via blax_dev_set_key, permissions 0600)
#
#  Security properties:
#    - requests are locked to *.blaxdevelopments.com — the agent can never be
#      talked into sending the key to a third-party host
#    - HTTPS only, 20-second timeouts, bounded response sizes
#    - the key never appears in error messages
#

import json
import os
import urllib.error
import urllib.parse
import urllib.request

from .watchdog import STATE_DIR

KEY_FILE = os.path.join(STATE_DIR, "blaxdev.key")
DEFAULT_BASE_URL = "https://blaxdevelopments.com"
ALLOWED_SUFFIX = ".blaxdevelopments.com"
ALLOWED_HOST = "blaxdevelopments.com"
TIMEOUT_SECONDS = 20
MAX_RESPONSE_BYTES = 512 * 1024


def _base_url():
    return os.environ.get("BLAXDEV_API_BASE_URL", DEFAULT_BASE_URL).rstrip("/")


def _key():
    key = os.environ.get("BLAXDEV_API_KEY", "").strip()
    if key:
        return key
    try:
        with open(KEY_FILE) as handle:
            stored = handle.read().strip()
            return stored or None
    except FileNotFoundError:
        return None


def blax_dev_set_key(key):
    """Stores the BLAXDEV_API_KEY on this Mac (one-time setup)."""
    key = str(key).strip()
    if not key:
        return {"error": "empty key - nothing stored"}
    os.makedirs(STATE_DIR, exist_ok=True)
    path = KEY_FILE
    with open(path, "w") as handle:
        handle.write(key)
    os.chmod(path, 0o600)
    return {"stored": True, "note": "key saved to this Mac with owner-only permissions"}


def _check_host(url):
    host = urllib.parse.urlsplit(url).hostname or ""
    if host != ALLOWED_HOST and not host.endswith(ALLOWED_SUFFIX):
        return False
    return True


def blax_dev_request(method="GET", path="/", payload=None):
    """Generic authenticated request to any endpoint on BlaxDevelopments.com.
    The agent can call whatever the real API exposes once it goes live."""
    base = _base_url()
    path = str(path or "/")
    if "://" in path or path.startswith("//"):
        return {"error": "path must be a path like /api/jobs — not a full URL (the agent may only talk to BlaxDevelopments.com)"}
    if not path.startswith("/"):
        path = "/" + path
    url = base + path

    # Domain lock FIRST: the key must never leave the Blax Developments
    # perimeter, no matter what the model asks for.
    if not _check_host(url):
        return {"error": f"refused: {url} is outside *.blaxdevelopments.com"}

    method = str(method or "GET").upper()
    if method not in ("GET", "POST", "PUT", "PATCH", "DELETE"):
        return {"error": f"unsupported method: {method}"}

    key = _key()
    if not key:
        return {
            "error": "no BLAXDEV_API_KEY on this Mac yet",
            "fix": "ask the user to run: python main.py setkey <key>  (or set the BLAXDEV_API_KEY env var)",
        }

    data = None
    headers = {
        "Authorization": f"Bearer {key}",
        "Accept": "application/json",
        "User-Agent": "EyeHelpi-Agent/1.0",
    }
    if payload is not None and method != "GET":
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"

    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            body = response.read(MAX_RESPONSE_BYTES).decode(errors="replace")
        try:
            return {"status": response.status, "body": json.loads(body)}
        except Exception:
            return {"status": response.status, "body": body[:2000]}
    except urllib.error.HTTPError as exc:
        detail = exc.read(MAX_RESPONSE_BYTES).decode(errors="replace")
        return {"status": exc.code, "error": "API returned an error", "detail": detail[:2000]}
    except Exception as exc:
        return {"error": f"request failed: {exc}"}


def blax_dev_status():
    """Connectivity + auth check against the Blax Developments API."""
    outcome = blax_dev_request("GET", "/api/status")
    key_present = _key() is not None
    return {
        "base_url": _base_url(),
        "key_present": key_present,
        "api_reachable": "status" in outcome,
        "outcome": outcome,