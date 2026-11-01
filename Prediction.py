#
#  tools/watchdog.py
#  Predictive watchdog + one-time-consent autopilot for Eye~Helpi.
#
#  Watches device health and takes preventative action WITHOUT prompting —
#  but only for action types the user granted ONCE in chat (stored in
#  ~/.eyehelpi/consent.json), and only when the action clearly benefits the
#  user or the device (protective, reversible, low-risk).
#

import json
import os
import shutil
import time
from collections import Counter

from .device_controls import (
    STATE_DIR, RECORDING_DIR, RECORDING_PID_FILE,
    get_battery, start_recording, stop_recording,
    take_pending_disposals, approve_disposal,
)

CONSENT_FILE = os.path.join(STATE_DIR, "consent.json")
USAGE_FILE = os.path.join(STATE_DIR, "usage.json")

VALID_CONSENTS = {
    "auto_dispose": "Clean up approved-category recordings when disk runs low",
    "protective_stop": "Stop recordings automatically when the battery is nearly flat",
    "auto_start_recording": "Start the usual recording automatically at your preferred hour",
}


def _load_json(path, default):
    try:
        with open(path) as handle:
            return json.load(handle)
    except Exception:
        return default


def _save_json(path, data):
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(path, "w") as handle:
        json.dump(data, handle, indent=2)


def consent_granted(action):
    return bool(_load_json(CONSENT_FILE, {}).get(action))


def grant_consent(action, granted=True):
    if action not in VALID_CONSENTS:
        return {
            "error": f"unknown consent type: {action}",
            "available": sorted(VALID_CONSENTS),
        }
    consents = _load_json(CONSENT_FILE, {})
    consents[action] = bool(granted)
    _save_json(CONSENT_FILE, consents)
    return {
        "action": action,
        "granted": bool(granted),
        "meaning": VALID_CONSENTS[action],
        "note": "one-time permission stored — no further prompts for this action.",
    }


def record_usage(event="chat"):
    usage = _load_json(USAGE_FILE, [])
    usage.append({"hour": time.localtime().tm_hour, "event": str(event)})
    if len(usage) > 500:
        usage = usage[-500:]
    _save_json(USAGE_FILE, usage)
    return {"recorded": True, "total": len(usage)}


def preferred_hour():
    usage = _load_json(USAGE_FILE, [])
    hours = [entry.get("hour") for entry in usage if entry.get("hour") is not None]
    if len(hours) < 5:
        return None
    return Counter(hours).most_common(1)[0][0]


def device_health_check():
    disk = shutil.disk_usage(os.path.expanduser("~"))
    total = disk.total or 1
    recordings = []
    if os.path.isdir(RECORDING_DIR):
        recordings = os.listdir(RECORDING_DIR)
    return {
        "disk_free_percent": round(100 * disk.free / total, 1),
        "battery": get_battery(),
        "recordings": len(recordings),
        "recording_active": os.path.exists(RECORDING_PID_FILE),
    }


def predictive_briefing():
    """What Eye~Helpi expects right now, based on learned rhythms."""
    hour = time.localtime().tm_hour
    preferred = preferred_hour()
    briefing = []
    if preferred is not None:
        if hour == preferred:
            briefing.append("This is your usual Eye~Helpi hour — everything is staged and ready.")
        else:
            briefing.append(
                f"You usually check in around {preferred}:00 — next window in {(preferred - hour) % 24}h."
            )
    health = device_health_check()
    if health["recordings"]:
        briefing.append(f"{health['recordings']} recording(s) on disk — disposal review available.")
    return {"briefing": briefing, "health": health}


def run_auto_pilot():
    """Predictive preventative actions without prompting. Each action type
    must have been granted once (see VALID_CONSENTS)."""
    actions = []
    health = device_health_check()

    # Protective: nearly flat battery while recording -> stop to protect the device.
    battery_percent = health["battery"].get("percent")
    if (
        battery_percent is not None
        and battery_percent <= 20
        and not health["battery"].get("charging")
        and health["recording_active"]
    ):
        if consent_granted("protective_stop"):
            outcome = stop_recording()
            actions.append({
                "action": "protective_stop",
                "detail": outcome,
                "why": f"battery at {battery_percent}% — protecting the device.",
            })
        else:
            actions.append({
                "action": "needs_consent",
                "type": "protective_stop",
                "why": f"battery at {battery_percent}% with a recording running.",
            })

    # Preventative: disk nearly full -> clean recordings the user pre-approved.
    if health["disk_free_percent"] < 10:
        if consent_granted("auto_dispose"):
            pending = take_pending_disposals()
            names = [c["name"] for c in pending.get("candidates", [])]
            if names:
                approve_disposal(names)
                actions.append({
                    "action": "auto_dispose",
                    "detail": names,
                    "why": f"only {health['disk_free_percent']}% disk free.",
                })
        else:
            actions.append({
                "action": "needs_consent",
                "type": "auto_dispose",
                "why": f"only {health['disk_free_percent']}% disk free — grant once and I'll manage it.",
            })

    # Predictive: at the user's usual hour, stage the usual recording automatically.
    if consent_granted("auto_start_recording") and not health["recording_active"]:
        preferred = preferred_hour()
        if preferred is not None and time.localtime().tm_hour == preferred:
            outcome = start_recording()
            if outcome.get("started"):
                actions.append({
                    "action": "auto_start_recording",
                    "detail": outcome,
                    "why": f"your usual {preferred}:00 session — started it for you.",
                })

    return {
        "actions": actions,
        "health": health,
        "consents": _load_json(CONSENT_FILE, {}),
    }