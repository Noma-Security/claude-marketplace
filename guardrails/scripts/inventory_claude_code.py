#!/usr/bin/env python3
"""Claude Code MCP discovery for the guardrails plugin.

The Claude Code + macOS/Linux specifics live here; the generic engine
(redaction, allowlist, artifact schema, I/O) lives in the vendored
noma_inventory package. Invoked by hook-mcp-inventory.sh:

    python3 -B inventory_claude_code.py   # reads the hook event JSON on stdin

Stdlib only, no f-strings/annotations — runs on any python3.
"""

import os
import sys

try:
    from noma_inventory import engine, servers
except ImportError:
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "common"))
    from noma_inventory import engine, servers


# Managed (enterprise-deployed) config, ordered by precedence: macOS first, then
# Linux — the first that exists wins. Module-level so tests can repoint it.
MANAGED_MCP_PATHS = [
    "/Library/Application Support/ClaudeCode/managed-mcp.json",
    "/etc/claude-code/managed-mcp.json",
]

# Enterprise managed-settings.json, same OS precedence as MANAGED_MCP_PATHS. Only
# its mcpServers block is taken (the file otherwise holds policy/env). Repointable
# for tests.
MANAGED_SETTINGS_PATHS = [
    "/Library/Application Support/ClaudeCode/managed-settings.json",
    "/etc/claude-code/managed-settings.json",
]


def plugin_name_from(install_path):
    """Plugin manifest "name" (.claude-plugin/plugin.json, then plugin.json).

    It can differ from the cache-dir name and the server key, and the backend
    needs it to parse mcp__plugin_<name>_* tool calls; "" when absent.
    """
    manifest = engine.read_json(install_path + "/.claude-plugin/plugin.json")
    if manifest is None:
        manifest = engine.read_json(install_path + "/plugin.json")
    if servers.is_object(manifest) and isinstance(manifest.get("name"), str):
        return manifest["name"]
    return ""


def _discover_plugins(home, cwd):
    """One set of artifacts per installed plugin active for this cwd."""
    out = []
    registry = engine.read_json(home + "/.claude/plugins/installed_plugins.json")
    if not (servers.is_object(registry) and servers.is_object(registry.get("plugins"))):
        return out
    plugins = registry["plugins"]
    for plugin_key in plugins:
        installs = plugins[plugin_key]
        if not isinstance(installs, list):
            continue
        for install in installs:
            if not servers.is_object(install):
                continue
            if install.get("scope") == "local" and install.get("projectPath") != cwd:
                continue
            install_path = install.get("installPath")
            if not isinstance(install_path, str) or install_path == "":
                continue

            plugin_name = plugin_name_from(install_path)

            # Full manifest: metadata + inline mcpServers (cleaned). Manifest
            # mcpServers are additive to .mcp.json, so both are emitted.
            manifest_path = None
            if engine.file_exists(install_path + "/.claude-plugin/plugin.json"):
                manifest_path = install_path + "/.claude-plugin/plugin.json"
            elif engine.file_exists(install_path + "/plugin.json"):
                manifest_path = install_path + "/plugin.json"
            if manifest_path:
                out.append((
                    "plugin", "claude_plugin_json", manifest_path,
                    servers.manifest_artifact_content(engine.read_json(manifest_path)),
                ))

            # Dedicated server file; tagged with the plugin name.
            mcp_file = install_path + "/.mcp.json"
            if engine.file_exists(mcp_file):
                out.append((
                    "plugin", "claude_mcp_json", mcp_file,
                    servers.with_plugin_name(
                        servers.server_content(engine.read_json(mcp_file)), plugin_name),
                ))
    return out


def discover_claude_code(home, cwd):
    """Return (scope, kind, path, content) MCP candidates for Claude Code."""
    candidates = []

    claude_json_path = home + "/.claude.json"
    claude_json = engine.read_json(claude_json_path)
    if servers.is_object(claude_json):
        # User scope: explicit keys only — the top level holds unrelated and
        # sensitive state, so the bare-map heuristic must not run here.
        candidates.append((
            "user", "claude_json", claude_json_path,
            servers.wrap_servers(servers.clean_map(
                servers.explicit_servers(claude_json))),
        ))

        # Local scope: this project's entry — only its server map; the entry
        # also holds prompts and metrics that must never be sent.
        projects = claude_json.get("projects")
        if not servers.is_object(projects):
            projects = {}
        entry = projects.get(cwd)
        if not servers.is_object(entry):
            entry = {}
        local_servers = entry.get("mcpServers")
        if not servers.is_object(local_servers):
            local_servers = {}
        candidates.append((
            "local", "claude_json", claude_json_path,
            servers.wrap_servers(servers.clean_map(local_servers)),
        ))

    # User scope: ~/.claude/mcp.json; project scope: <cwd>/.mcp.json
    user_mcp = home + "/.claude/mcp.json"
    candidates.append((
        "user", "claude_mcp_json", user_mcp,
        servers.server_content(engine.read_json(user_mcp)),
    ))
    project_mcp = cwd + "/.mcp.json"
    candidates.append((
        "project", "claude_mcp_json", project_mcp,
        servers.server_content(engine.read_json(project_mcp)),
    ))

    candidates.extend(_discover_plugins(home, cwd))

    # Managed scope (enterprise-deployed); first existing path wins.
    for p in MANAGED_MCP_PATHS:
        if engine.file_exists(p):
            candidates.append((
                "managed", "claude_managed_mcp_json", p,
                servers.server_content(engine.read_json(p)),
            ))
            break

    # Settings files. These hold unrelated/secret state (env, tokens), so take
    # the explicit mcpServers/servers key only — never the bare-map heuristic. No
    # servers => empty content => engine drops the artifact (the common case:
    # these files usually carry only policy/env, so this is a no-op).
    #
    # Server-managed "remote" settings (~/.claude/remote-settings.json) are the
    # highest-precedence tier; enterprise "managed" settings sit one below.
    remote_settings = home + "/.claude/remote-settings.json"
    candidates.append((
        "remote", "claude_settings_json", remote_settings,
        servers.wrap_servers(servers.clean_map(
            servers.explicit_servers(engine.read_json(remote_settings)))),
    ))
    for p in MANAGED_SETTINGS_PATHS:
        if engine.file_exists(p):
            candidates.append((
                "managed", "claude_settings_json", p,
                servers.wrap_servers(servers.clean_map(
                    servers.explicit_servers(engine.read_json(p)))),
            ))
            break

    return candidates


if __name__ == "__main__":
    try:
        engine.run(discover_claude_code)
    except Exception:
        # Total degradation: emit nothing and fail so the shell hook forwards
        # the original event unchanged (no mcp_artifacts) — the same basic
        # behavior as a machine with no usable python3.
        sys.exit(1)
