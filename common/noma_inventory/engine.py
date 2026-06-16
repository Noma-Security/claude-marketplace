"""Generic inventory engine: filesystem/stdio helpers, artifact assembly,
payload construction, and the run() entrypoint.

Vendor-agnostic. A *discoverer* is any callable ``(home, cwd)`` returning a list
of ``(scope, kind, path, content)`` candidates; the engine drops empty content
and emits the rest. Stdlib only.
"""

import json
import os
import sys

from .servers import is_object


# --- filesystem / stdio (every failure degrades to None/"") ------------------


def read_json(path):
    """Parse a JSON file, or None on any read/decode/parse failure."""
    try:
        f = open(path, "rb")
    except Exception:
        return None
    try:
        raw = f.read()
    except Exception:
        return None
    finally:
        f.close()
    try:
        return json.loads(raw.decode("utf-8"))
    except Exception:
        return None


def file_exists(path):
    return os.path.exists(path)


def read_stdin():
    try:
        return sys.stdin.buffer.read().decode("utf-8")
    except Exception:
        return ""


def write_stdout(data):
    try:
        sys.stdout.buffer.write(data.encode("utf-8"))
        sys.stdout.buffer.write(b"\n")
    except Exception:
        sys.stdout.write(data + "\n")


# --- artifact / payload assembly ---------------------------------------------


def make_artifact(scope, kind, path, content):
    return {"scope": scope, "kind": kind, "path": path, "content": content}


def build_inventory(discoverer, home, cwd):
    """Run a discoverer and keep only non-empty artifacts."""
    artifacts = []
    for scope, kind, path, content in discoverer(home, cwd):
        if is_object(content) and len(content) > 0:
            artifacts.append(make_artifact(scope, kind, path, content))
    return artifacts


def build_payload(raw, discoverer, home, cwd_fallback):
    """Pure core (no stdin/stdout/env) so it is directly unit-testable.

    Returns the original event plus mcp_artifacts, or a fallback envelope when
    stdin was not valid JSON.
    """
    event = None
    try:
        parsed = json.loads(raw)
        if is_object(parsed):
            event = parsed
    except Exception:
        event = None

    if event is not None and isinstance(event.get("cwd"), str) and event["cwd"] != "":
        cwd = event["cwd"]
    else:
        cwd = cwd_fallback

    artifacts = build_inventory(discoverer, home, cwd) if discoverer else []

    payload = event if event is not None else {
        "hook_event_name": "UserPromptSubmit", "cwd": cwd
    }
    payload["mcp_artifacts"] = artifacts
    return payload


def run(discoverer, argv=None):
    """Entrypoint: read the event on stdin, emit event + mcp_artifacts on stdout."""
    home = os.environ.get("HOME") or ""
    payload = build_payload(read_stdin(), discoverer, home, os.getcwd())
    write_stdout(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
