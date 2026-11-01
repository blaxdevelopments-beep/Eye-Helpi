#  tools/__init__.py
#  The agent's tool registry: every tool Eye~Helpi can call, with its schema.
#  Used by main.py (chat tool-calling loop), the HTTP API and the MCP server.
#

from .device_controls import (
    get_battery, capture_screen, capture_camera_frame, media_to_base64,
    start_recording, stop_recording,
    take_pending_disposals, approve_disposal, reject_disposal,
)
from .productivity_tools import (
    list_reminders, add_reminder, list_calendar_events,
    get_weather, network_diagnostics, file_search,
)
from .watchdog import (
    device_health_check, run_auto_pilot, grant_consent,
    predictive_briefing, record_usage,
)
from .blax_dev import (
    blax_dev_set_key, blax_dev_request, blax_dev_status,
)
from .platform import platform_info

OBJECT_SCHEMA = {"type": "object", "properties": {}, "required": []}

TOOL_REGISTRY = {
    "get_battery": {
        "fn": get_battery,
        "description": "Battery percentage and charging state",
        "parameters": OBJECT_SCHEMA,
    },
    "capture_screen": {
        "fn": capture_screen,
        "description": "One-shot screenshot of the primary monitor, returned as base64 PNG",
        "parameters": OBJECT_SCHEMA,
    },
    "capture_camera_frame": {
        "fn": capture_camera_frame,
        "description": "One-shot frame from the webcam, returned as base64 JPEG",
        "parameters": OBJECT_SCHEMA,
    },
    "media_to_base64": {
        "fn": media_to_base64,
        "description": "Encodes an image or video file as base64 for vision calls",
        "parameters": {
            "type": "object",
            "properties": {"path": {"type": "string", "description": "Absolute path to the media file"}},
            "required": ["path"],
        },
    },
    "start_recording": {
        "fn": start_recording,
        "description": "Starts a background screen recording (60-minute write-over, macOS + ffmpeg)",
        "parameters": OBJECT_SCHEMA,
    },
    "stop_recording": {
        "fn": stop_recording,
        "description": "Stops the running background recording",
        "parameters": OBJECT_SCHEMA,
    },
    "take_pending_disposals": {
        "fn": take_pending_disposals,
        "description": "Lists recordings older than one hour that await the user's approve/reject",
        "parameters": OBJECT_SCHEMA,
    },
    "approve_disposal": {
        "fn": approve_disposal,
        "description": "Deletes the named recordings after user approval",
        "parameters": {
            "type": "object",
            "properties": {"names": {"type": "array", "items": {"type": "string"}}},
            "required": ["names"],
        },
    },
    "reject_disposal": {
        "fn": reject_disposal,
        "description": "Keeps the named recordings, removing them from the pending list",
        "parameters": {
            "type": "object",
            "properties": {"names": {"type": "array", "items": {"type": "string"}}},
            "required": ["names"],
        },
    },
    "list_reminders": {
        "fn": list_reminders,
        "description": "Lists open Reminders on this Mac",
        "parameters": OBJECT_SCHEMA,
    },
    "add_reminder": {
        "fn": add_reminder,
        "description": "Adds a new Reminder on this Mac",
        "parameters": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"],
        },
    },
    "list_calendar_events": {
        "fn": list_calendar_events,
        "description": "Lists today's Calendar events on this Mac",
        "parameters": OBJECT_SCHEMA,
    },
    "get_weather": {
        "fn": get_weather,
        "description": "Current weather for a city (defaults to Alice Springs)",
        "parameters": {
            "type": "object",
            "properties": {"city": {"type": "string"}},
        },
    },
    "network_diagnostics": {
        "fn": network_diagnostics,
        "description": "Pings a host and resolves its DNS (defaults to 1.1.1.1)",
        "parameters": {
            "type": "object",
            "properties": {"host": {"type": "string"}},
        },
    },
    "file_search": {
        "fn": file_search,
        "description": "Searches a folder for files whose names match a pattern",
        "parameters": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string", "description": "Glob pattern, e.g. invoice*.pdf"},
                "folder": {"type": "string", "description": "Folder to search (defaults to ~/Documents)"},
                "max_results": {"type": "integer"},
            },
            "required": ["pattern"],
        },
    },
    "device_health_check": {
        "fn": device_health_check,
        "description": "Device health snapshot: disk, battery, recordings",
        "parameters": OBJECT_SCHEMA,
    },
    "predictive_briefing": {
        "fn": predictive_briefing,
        "description": "What Eye~Helpi expects right now, learned from usage rhythms",
        "parameters": OBJECT_SCHEMA,
    },
    "grant_consent": {
        "fn": grant_consent,
        "description": "One-time permission for an autonomous action type (auto_dispose, protective_stop, auto_start_recording). After this, the agent acts without asking.",
        "parameters": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["auto_dispose", "protective_stop", "auto_start_recording"]},
                "granted": {"type": "boolean"},
            },
            "required": ["action"],
        },
    },
    "run_auto_pilot": {
        "fn": run_auto_pilot,
        "description": "Takes granted preventative actions now (low-battery protection, disk cleanup, rhythmic recording start) without prompting",
        "parameters": OBJECT_SCHEMA,
    },
    "record_usage": {
        "fn": record_usage,
        "description": "Records a usage event so predictions improve",
        "parameters": {
            "type": "object",
            "properties": {"event": {"type": "string"}},
        },
    },
    "blax_dev_status": {
        "fn": blax_dev_status,
        "description": "Checks the Blax Developments API: reachable, key stored, auth ok",
        "parameters": OBJECT_SCHEMA,
    },
    "blax_dev_request": {
        "fn": blax_dev_request,
        "description": "Authenticated request to any BlaxDevelopments.com API endpoint (domain-locked, Bearer key)",
        "parameters": {
            "type": "object",
            "properties": {
                "method": {"type": "string", "enum": ["GET", "POST", "PUT", "PATCH", "DELETE"]},
                "path": {"type": "string", "description": "Endpoint path, e.g. /api/jobs"},
                "payload": {"type": "object", "description": "JSON body for POST/PUT/PATCH"},
            },
        },
    },
    "blax_dev_set_key": {
        "fn": blax_dev_set_key,
        "description": "Stores the BLAXDEV_API_KEY on this Mac (one-time setup)",
        "parameters": {
            "type": "object",
            "properties": {"key": {"type": "string"}},
            "required": ["key"],
        },
    },
    "system_info": {
        "fn": platform_info,
        "description": "This machine's OS, architecture and available helper tools - so Eye~Helpi adapts its advice to the platform it's running on (macOS, Linux or Windows)",
        "parameters": OBJECT_SCHEMA,
    },
}


def tool_schemas_raw():
    """Tool descriptors as plain dicts (schema + description)."""
    return [
        {
            "name": name,
            "description": tool["description"],
            "parameters": tool.get("parameters", OBJECT_SCHEMA),
        }
        for name, tool in TOOL_REGISTRY.items()
    ]


def tool_schemas():
    """Tool descriptors in Ollama /api/chat 'tools' format."""
    return [
        {
            "type": "function",
            "function": {"name": t["name"], "description": t["description"], "parameters": t["parameters"]},
        }
        for t in tool_schemas_raw()
    ]


def run_tool(name, arguments):
    """Executes a registry tool by name, never raising."""
    tool = TOOL_REGISTRY.get(name)
    if tool is None:
        return {"error": f"unknown tool: {name}"}
    try:
        arguments = arguments or {}
        if not isinstance(arguments, dict):
            return {"error": "arguments must be an object"}
        return tool["fn"](**arguments)
    except TypeError as exc:
        return {"error": f"bad arguments for {name}: {exc}"}
    except Exception as exc:
        return {"error": f"{name} failed: {exc}"}