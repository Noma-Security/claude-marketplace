"""Generic, vendor-agnostic MCP inventory engine (stdlib only).

A plugin supplies a *discoverer* callable ``(home, cwd)`` returning
``(scope, kind, path, content)`` candidates and calls ``engine.run(discoverer)``.
Nothing here knows about a specific vendor or operating system.
"""

from .redaction import REDACTED, sanitize_args, sanitize_str
from .servers import (
    clean_map,
    clean_server,
    is_object,
    manifest_artifact_content,
    norm,
    server_content,
    with_plugin_name,
    wrap_servers,
)
from .engine import (
    build_inventory,
    build_payload,
    file_exists,
    make_artifact,
    read_json,
    read_stdin,
    run,
    write_stdout,
)

__all__ = [
    "REDACTED",
    "sanitize_args",
    "sanitize_str",
    "clean_map",
    "clean_server",
    "is_object",
    "manifest_artifact_content",
    "norm",
    "server_content",
    "with_plugin_name",
    "wrap_servers",
    "build_inventory",
    "build_payload",
    "file_exists",
    "make_artifact",
    "read_json",
    "read_stdin",
    "run",
    "write_stdout",
]
