#
#  tools/platform.py
#  Cross-OS detection for Eye~Helpi's agent: which platform we're on and
#  which helper binaries are available, so tools adapt instead of failing.
#

import platform
import shutil
import sys

OS_NAME = platform.system().lower()  # "darwin", "linux", "windows", ...

if OS_NAME == "darwin":
    OS_LABEL = "macOS"
elif OS_NAME == "linux":
    OS_LABEL = "Linux"
elif OS_NAME == "windows":
    OS_LABEL = "Windows"
else:
    OS_LABEL = OS_NAME or "unknown"


def run_binary(name):
    """True when a helper binary is on PATH."""
    return shutil.which(name) is not None


def platform_info():
    """What this machine is, so Eye~Helpi can adapt its answers."""
    helpers = ["ffmpeg", "imagesnap", "gnome-screenshot", "scrot",
               "import", "wmctrl", "xrandr", "pmset", "screencapture",
               "imagesnap", "khal", "powershell"]
    return {
        "os": OS_LABEL,
        "os_internal": OS_NAME,
        "python": sys.version.split()[0],
        "arch": platform.machine(),
        "helpers_available": {name: run_binary(name) for name in helpers if run_binary(name)},
    }


def is_windows():
    return OS_NAME == "windows"


def is_mac():
    return OS_NAME == "darwin"


def is_linux():
    return OS_NAME == "linux"