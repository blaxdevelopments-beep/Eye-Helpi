#
#  tools/productivity_tools.py
#  Everyday tool pack for Eye~Helpi: Reminders, Calendar, weather, network
#  diagnostics and file search. Standard library only.
#

import fnmatch
import os
import platform
import socket
import subprocess
import urllib.request
import urllib.parse

_OS = platform.system().lower()


def _unsupported(feature):
    return {
        "error": f"{feature} is not wired up on {platform.system()} yet - "
                 f"Eye~Helpi runs there, but this tool currently only supports macOS "
                 f"for {feature.lower()}."
    }


def _osascript(script):
    proc = subprocess.run(
        ["osascript", "-e", script], capture_output=True, text=True, timeout=20
    )
    if proc.returncode != 0:
        return {"error": (proc.stderr or "osascript failed").strip()}
    return {"result": (proc.stdout or "").strip()}


def list_reminders():
    if _OS != "darwin":
        return _unsupported("Reminders")
    return _osascript(
        'tell application "Reminders" to get name of reminders whose completed is false'
    )


def add_reminder(name):
    if _OS != "darwin":
        return _unsupported("Reminders")
    safe = str(name).replace('"', '\\"')
    return _osascript(
        'tell application "Reminders" to make new reminder with properties {name:"%s"}' % safe
    )


def list_calendar_events():
    if _OS != "darwin":
        return _unsupported("Calendar")
    return _osascript(
        'tell application "Calendar" to get summary of every event of today of every calendar'
    )


def get_weather(city="Alice Springs"):
    try:
        encoded = urllib.parse.quote(str(city))
        with urllib.request.urlopen(
            f"https://wttr.in/{encoded}?format=j1", timeout=10
        ) as resp:
            import json

            data = json.loads(resp.read().decode())
        current = data.get("current_condition", [{}])[0]
        return {
            "city": city,
            "temp_c": current.get("temp_C"),
            "feels_like_c": current.get("FeelsLikeC"),
            "condition": current.get("weatherDesc", [{}])[0].get("value"),
            "humidity": current.get("humidity"),
        }
    except Exception as exc:
        return {"error": f"weather lookup failed: {exc}"}


def network_diagnostics(host="1.1.1.1"):
    host = str(host)
    results = {}
    try:
        results["dns"] = socket.gethostbyname(host)
    except Exception as exc:
        results["dns"] = f"resolution failed: {exc}"
    # Windows uses -n for ping count; macOS/Linux use -c.
    count_flag = "-n" if _OS == "windows" else "-c"
    try:
        proc = subprocess.run(
            ["ping", count_flag, "3", host], capture_output=True, text=True, timeout=15
        )
        tail = [line for line in proc.stdout.splitlines()
                if "avg" in line or "round-trip" in line or "Average" in line or "Minimum" in line]
        results["ping"] = tail[-1] if tail else proc.stdout.strip()[-200:]
    except Exception as exc:
        results["ping"] = str(exc)
    return results


def file_search(pattern, folder="~/Documents", max_results=25):
    folder = os.path.expanduser(str(folder))
    if not os.path.isdir(folder):
        return {"error": f"no such folder: {folder}"}
    matches, scanned = [], 0
    for root, dirs, files in os.walk(folder):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("Library", "node_modules", "$RECYCLE.BIN")]
        for name in files:
            scanned += 1
            if fnmatch.fnmatch(name.lower(), str(pattern).lower()):
                matches.append(os.path.join(root, name))
                if len(matches) >= int(max_results or 25):
                    break
        if len(matches) >= int(max_results or 25):
            break
    return {"pattern": pattern, "scanned": scanned, "matches": matches}