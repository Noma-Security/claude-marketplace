#!/usr/bin/env python3
"""Unit tests for noma_inventory.servers — the MCP config allowlist/normalize."""

import unittest

import _bootstrap  # noqa: F401  (sets sys.path)
from noma_inventory import redaction, servers

R = redaction.REDACTED


class TestCleanServer(unittest.TestCase):
    def test_allowlist_drops_env_headers_meta(self):
        srv = servers.clean_server({
            "type": "stdio", "command": "docker", "args": ["run"],
            "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "github_pat_11AAAAA0secretsecret"},
            "headers": {"Authorization": "Bearer sk-deadbeefdeadbeef"},
            "_meta": {"internal": True},
        })
        self.assertEqual(sorted(srv.keys()), ["args", "command", "type"])

    def test_type_passthrough(self):
        self.assertEqual(servers.clean_server({"type": False})["type"], False)
        self.assertNotIn("type", servers.clean_server({"type": None}))
        self.assertEqual(servers.clean_server({"type": "stdio", "command": "x"})["type"], "stdio")

    def test_url_and_command_fields_sanitized(self):
        srv = servers.clean_server({
            "type": "http",
            "url": "https://admin:letmein99@mcp.example/path",
            "command": "API_TOKEN=cmdsecret77 ./start.sh",
        })
        self.assertEqual(srv["url"], "https://" + R + "@mcp.example/path")
        self.assertEqual(srv["command"], "API_TOKEN=" + R + " ./start.sh")

    def test_args_stringify_non_strings(self):
        srv = servers.clean_server({"type": "stdio", "command": "npx",
                                    "args": ["--token", 12345, "-p", 8080, True]})
        self.assertEqual(srv["args"][1], R)
        self.assertEqual(srv["args"][3], "8080")
        self.assertEqual(srv["args"][4], "true")

    def test_clean_args_unchanged(self):
        srv = servers.clean_server({"type": "stdio", "command": "npx",
                                    "args": ["-y", "@scope/server-name", "--port", "8080",
                                             "https://plain.example/mcp"]})
        self.assertEqual(" ".join(srv["args"]),
                         "-y @scope/server-name --port 8080 https://plain.example/mcp")


class TestNorm(unittest.TestCase):
    def test_variants(self):
        self.assertEqual(servers.norm({"mcpServers": {"a": {"url": "u"}}}), {"a": {"url": "u"}})
        self.assertEqual(servers.norm({"servers": {"b": {"url": "u"}}}), {"b": {"url": "u"}})
        self.assertEqual(servers.norm({"c": {"url": "u"}, "x": {"nope": 1}}), {"c": {"url": "u"}})
        self.assertEqual(servers.norm("nope"), {})
        self.assertEqual(servers.norm({}), {})


class TestWrapAndContent(unittest.TestCase):
    def test_wrap_servers_empty(self):
        self.assertEqual(servers.wrap_servers({}), {})
        self.assertEqual(servers.wrap_servers({"a": {}}), {"mcpServers": {"a": {}}})

    def test_server_content_pipeline(self):
        out = servers.server_content({"servers": {"s": {"type": "http", "url": "https://s.example"}}})
        self.assertEqual(out, {"mcpServers": {"s": {"type": "http", "url": "https://s.example"}}})


class TestManifest(unittest.TestCase):
    def test_keeps_metadata_cleans_inline_servers(self):
        content = servers.manifest_artifact_content({
            "name": "inline", "version": "1.0.0", "author": {"name": "a"},
            "mcpServers": {"srv": {
                "type": "stdio", "command": "npx", "args": ["-y", "s", "--token", "supersecret9"],
                "env": {"API_KEY": "github_pat_11AAAAA0leak"},
                "headers": {"Authorization": "Bearer sk-deadbeef00000000"},
            }},
        })
        self.assertEqual(content["name"], "inline")
        self.assertEqual(content["version"], "1.0.0")
        self.assertEqual(content["author"], {"name": "a"})
        self.assertEqual(sorted(content["mcpServers"]["srv"].keys()), ["args", "command", "type"])
        self.assertEqual(content["mcpServers"]["srv"]["args"][3], R)

    def test_metadata_only_has_no_servers(self):
        content = servers.manifest_artifact_content({"name": "m", "version": "1"})
        self.assertNotIn("mcpServers", content)


class TestWithPluginName(unittest.TestCase):
    def test_tags_non_empty(self):
        self.assertEqual(servers.with_plugin_name({"mcpServers": {"a": {}}}, "Notion")["pluginName"], "Notion")

    def test_empty_untouched(self):
        self.assertEqual(servers.with_plugin_name({}, "Notion"), {})


if __name__ == "__main__":
    unittest.main()
