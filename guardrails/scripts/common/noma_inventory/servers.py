"""MCP server-config normalization and allowlisting.

Vendor-agnostic: works on any tool's mcpServers/servers map. Output is
allowlisted to type/url/command/args with secret-looking values masked, so the
identifier a backend derives from them is clean by construction. env, headers
and everything else never leave the machine.
"""

import json

from .redaction import sanitize_args, sanitize_str


def is_object(v):
    """True for a JSON object (dict); JSON arrays are list, null is None."""
    return isinstance(v, dict)


def norm(doc):
    """Normalize a config file to {name: config}.

    Accepts an mcpServers / servers wrapper, or a bare map of server-looking
    objects. Never use this for ~/.claude.json, whose top level holds unrelated
    and sensitive state.
    """
    if not is_object(doc):
        return {}
    if is_object(doc.get("mcpServers")):
        return doc["mcpServers"]
    if is_object(doc.get("servers")):
        return doc["servers"]
    bare = {}
    for name in doc:
        v = doc[name]
        if is_object(v) and ("command" in v or "url" in v or "type" in v):
            bare[name] = v
    return bare


def clean_server(cfg):
    """Per-server allowlist: type/url/command/args only, strings sanitized."""
    if not is_object(cfg):
        return {}
    out = {}
    if cfg.get("type") is not None:
        out["type"] = cfg["type"]
    if isinstance(cfg.get("url"), str):
        out["url"] = sanitize_str(cfg["url"])
    if isinstance(cfg.get("command"), str):
        out["command"] = sanitize_str(cfg["command"])
    if isinstance(cfg.get("args"), list):
        cleaned = sanitize_args(cfg["args"])
        # matches jq/JSON.stringify tostring: 8080 -> "8080", true -> "true"
        out["args"] = [
            v if isinstance(v, str) else json.dumps(v, separators=(",", ":"))
            for v in cleaned
        ]
    return out


def clean_map(servers):
    """Allowlist every server in a {name: config} map."""
    if not is_object(servers):
        return {}
    out = {}
    for name in servers:
        out[name] = clean_server(servers[name])
    return out


def wrap_servers(m):
    """Wrap a cleaned server map as {mcpServers: m}; {} when empty."""
    return {"mcpServers": m} if len(m) > 0 else {}


def server_content(doc):
    """Full pipeline for a server config file: normalize -> clean -> wrap."""
    return wrap_servers(clean_map(norm(doc)))


def manifest_artifact_content(doc):
    """Manifest verbatim, with only its inline mcpServers allowlisted+sanitized.

    Metadata (name/version/author/...) is benign and sent as-is.
    """
    if not is_object(doc):
        return {}
    out = {}
    for key in doc:
        if key == "mcpServers":
            continue
        out[key] = doc[key]
    if is_object(doc.get("mcpServers")):
        servers = clean_map(doc["mcpServers"])
        if len(servers) > 0:
            out["mcpServers"] = servers
    return out


def with_plugin_name(content, name):
    """Tag non-empty content with a plugin name; empty content is untouched."""
    if name and is_object(content) and len(content) > 0:
        content["pluginName"] = name
    return content
