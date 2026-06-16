#!/usr/bin/env python3
"""Unit tests for the plugin-local Claude Code discoverer over a fixture HOME."""

import json
import os
import tempfile
import unittest

import _bootstrap  # noqa: F401  (sets sys.path)
from noma_inventory import engine
import inventory_claude_code as cc


def write_file(path, content):
    parent = os.path.dirname(path)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    with open(path, "w") as f:
        f.write(content)


def add_plugin(home, name, relpath, content, scope="user", project_path=None):
    install_dir = os.path.join(home, ".claude", "plugins", "cache", "test-marketplace", name, "1.0.0")
    write_file(os.path.join(install_dir, relpath), content)
    registry_path = os.path.join(home, ".claude", "plugins", "installed_plugins.json")
    registry = {"plugins": {}}
    if os.path.isfile(registry_path):
        with open(registry_path) as f:
            registry = json.load(f)
    entry = {"installPath": install_dir, "scope": scope}
    if project_path is not None:
        entry["projectPath"] = project_path
    registry["plugins"][name + "@test-marketplace"] = [entry]
    write_file(registry_path, json.dumps(registry))


def artifact(payload, scope, kind):
    for a in payload["mcp_artifacts"]:
        if a["scope"] == scope and a["kind"] == kind:
            return a
    return None


def count(payload, scope=None, kind=None):
    n = 0
    for a in payload["mcp_artifacts"]:
        if (scope is None or a["scope"] == scope) and (kind is None or a["kind"] == kind):
            n += 1
    return n


class TestDiscoverClaudeCode(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.home = os.path.join(self.tmp, "home")
        self.proj = os.path.join(self.tmp, "proj")
        os.makedirs(self.home)
        os.makedirs(self.proj)

    def run_inv(self):
        raw = json.dumps({"hook_event_name": "UserPromptSubmit", "prompt": "hi",
                          "cwd": self.proj, "session_id": "s"})
        return engine.build_payload(raw, cc.discover_claude_code, self.home, self.proj)

    def test_user_scope_mcpservers(self):
        write_file(os.path.join(self.home, ".claude.json"),
                   '{"mcpServers":{"alpha":{"type":"http","url":"https://alpha.example"}},"numStartups":42}')
        p = self.run_inv()
        a = artifact(p, "user", "claude_json")
        self.assertEqual(a["content"]["mcpServers"]["alpha"]["url"], "https://alpha.example")
        self.assertEqual(a["path"], os.path.join(self.home, ".claude.json"))

    def test_user_scope_servers_variant(self):
        write_file(os.path.join(self.home, ".claude.json"),
                   '{"servers":{"beta":{"type":"http","url":"https://beta.example"}}}')
        p = self.run_inv()
        self.assertEqual(artifact(p, "user", "claude_json")["content"]["mcpServers"]["beta"]["url"],
                         "https://beta.example")

    def test_no_bare_map_for_claude_json(self):
        write_file(os.path.join(self.home, ".claude.json"),
                   '{"cachedDynamicConfigs":{"type":"remote","url":"https://internal.example"}}')
        p = self.run_inv()
        self.assertEqual(count(p, "user", "claude_json"), 0)
        self.assertNotIn("internal.example", json.dumps(p))

    def test_local_scope_only_servers(self):
        write_file(os.path.join(self.home, ".claude.json"), json.dumps({"projects": {self.proj: {
            "mcpServers": {"gh": {"type": "stdio", "command": "docker", "args": ["run", "-i"]}},
            "enabledMcpjsonServers": ["gh"],
            "lastSessionFirstPrompt": "SUPER PRIVATE PROMPT",
            "allowedTools": ["Bash(rm:*)"],
        }}}))
        p = self.run_inv()
        local = artifact(p, "local", "claude_json")
        self.assertEqual(local["content"]["mcpServers"]["gh"]["command"], "docker")
        self.assertEqual(list(local["content"].keys()), ["mcpServers"])
        blob = json.dumps(p)
        for leak in ("SUPER PRIVATE PROMPT", "allowedTools", "enabledMcpjsonServers"):
            self.assertNotIn(leak, blob)

    def test_user_and_project_mcp_json(self):
        write_file(os.path.join(self.home, ".claude", "mcp.json"),
                   '{"servers":{"logger":{"type":"http","url":"https://logger.example"}}}')
        write_file(os.path.join(self.proj, ".mcp.json"),
                   '{"mcpServers":{"proj":{"type":"stdio","command":"npx","args":["-y","proj-server"]}}}')
        p = self.run_inv()
        self.assertEqual(artifact(p, "user", "claude_mcp_json")["content"]["mcpServers"]["logger"]["url"],
                         "https://logger.example")
        self.assertEqual(artifact(p, "project", "claude_mcp_json")["content"]["mcpServers"]["proj"]["command"],
                         "npx")

    def test_plugin_wrapped_and_bare(self):
        add_plugin(self.home, "wrapped", ".mcp.json",
                   '{"mcpServers":{"w":{"type":"http","url":"https://w.example"}}}')
        add_plugin(self.home, "bare", ".mcp.json", '{"b":{"type":"http","url":"https://b.example"}}')
        p = self.run_inv()
        self.assertEqual(count(p, "plugin", "claude_mcp_json"), 2)
        keys = []
        for a in p["mcp_artifacts"]:
            if a["scope"] == "plugin":
                keys.extend(a["content"]["mcpServers"].keys())
        self.assertEqual(sorted(keys), ["b", "w"])

    def test_plugin_manifest_and_mcp_json_with_name(self):
        add_plugin(self.home, "notion", ".mcp.json",
                   '{"mcpServers":{"notion":{"type":"http","url":"https://mcp.notion.com/mcp"}}}')
        add_plugin(self.home, "notion", ".claude-plugin/plugin.json", '{"name":"Notion","version":"0.1.0"}')
        p = self.run_inv()
        self.assertEqual(count(p, "plugin", "claude_plugin_json"), 1)
        self.assertEqual(count(p, "plugin", "claude_mcp_json"), 1)
        self.assertEqual(artifact(p, "plugin", "claude_plugin_json")["content"]["name"], "Notion")
        mcp = artifact(p, "plugin", "claude_mcp_json")
        self.assertEqual(mcp["content"]["mcpServers"]["notion"]["url"], "https://mcp.notion.com/mcp")
        self.assertEqual(mcp["content"]["pluginName"], "Notion")

    def test_plugin_inline_manifest_servers_cleaned(self):
        add_plugin(self.home, "inline", ".claude-plugin/plugin.json", json.dumps({
            "name": "inline", "version": "1.0.0",
            "mcpServers": {"srv": {
                "type": "stdio", "command": "npx", "args": ["-y", "s", "--token", "supersecret9"],
                "env": {"API_KEY": "github_pat_11AAAAA0leak"},
                "headers": {"Authorization": "Bearer sk-deadbeef00000000"},
            }},
        }))
        p = self.run_inv()
        man = artifact(p, "plugin", "claude_plugin_json")["content"]
        self.assertEqual(sorted(man["mcpServers"]["srv"].keys()), ["args", "command", "type"])
        self.assertEqual(man["mcpServers"]["srv"]["args"][3], "***REDACTED***")
        blob = json.dumps(p)
        for leak in ('"env"', '"headers"', "supersecret9", "github_pat_"):
            self.assertNotIn(leak, blob)

    def test_local_plugin_excluded_for_other_project(self):
        add_plugin(self.home, "other", ".mcp.json",
                   '{"mcpServers":{"other":{"type":"http","url":"https://other.example"}}}',
                   scope="local", project_path="/somewhere/else")
        add_plugin(self.home, "mine", ".mcp.json",
                   '{"mcpServers":{"mine":{"type":"http","url":"https://mine.example"}}}',
                   scope="local", project_path=self.proj)
        p = self.run_inv()
        self.assertEqual(count(p, "plugin", "claude_mcp_json"), 1)
        self.assertNotIn("other.example", json.dumps(p))

    def test_managed_scope(self):
        managed = os.path.join(self.tmp, "managed-mcp.json")
        write_file(managed, '{"mcpServers":{"corp":{"type":"http","url":"https://mcp.corp.example"}}}')
        saved = cc.MANAGED_MCP_PATHS
        cc.MANAGED_MCP_PATHS = [managed]
        self.addCleanup(lambda: setattr(cc, "MANAGED_MCP_PATHS", saved))
        p = self.run_inv()
        self.assertEqual(artifact(p, "managed", "claude_managed_mcp_json")["content"]["mcpServers"]["corp"]["url"],
                         "https://mcp.corp.example")

    def test_settings_files_never_read(self):
        write_file(os.path.join(self.home, ".claude", "settings.json"),
                   '{"disabledMcpjsonServers":["dropped"],"env":{"FOO":"bar"}}')
        p = self.run_inv()
        self.assertEqual(count(p, kind="claude_settings_json"), 0)
        self.assertNotIn("disabledMcpjsonServers", json.dumps(p))

    def test_empty_home(self):
        p = self.run_inv()
        self.assertEqual(p["mcp_artifacts"], [])
        self.assertEqual(p["prompt"], "hi")


if __name__ == "__main__":
    unittest.main()
