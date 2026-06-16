#!/usr/bin/env python3
"""Unit tests for noma_inventory.engine — orchestration, payload, fs helpers."""

import json
import os
import tempfile
import unittest

import _bootstrap  # noqa: F401  (sets sys.path)
from noma_inventory import engine


def fake_discoverer(home, cwd):
    # Two candidates: one non-empty, one empty (must be dropped).
    return [
        ("user", "k1", "/p1", {"mcpServers": {"a": {"type": "http"}}}),
        ("user", "k2", "/p2", {}),
    ]


class TestBuildInventory(unittest.TestCase):
    def test_skips_empty_content(self):
        arts = engine.build_inventory(fake_discoverer, "/home", "/cwd")
        self.assertEqual(len(arts), 1)
        self.assertEqual(arts[0], {"scope": "user", "kind": "k1", "path": "/p1",
                                   "content": {"mcpServers": {"a": {"type": "http"}}}})

    def test_discoverer_receives_cwd(self):
        seen = {}

        def disc(home, cwd):
            seen["home"], seen["cwd"] = home, cwd
            return []

        engine.build_inventory(disc, "/H", "/C")
        self.assertEqual(seen, {"home": "/H", "cwd": "/C"})


class TestBuildPayload(unittest.TestCase):
    def test_event_preserved_and_artifacts_appended(self):
        raw = json.dumps({"hook_event_name": "UserPromptSubmit", "prompt": "hi", "cwd": "/x"})
        p = engine.build_payload(raw, fake_discoverer, "/home", "/fallback")
        self.assertEqual(p["prompt"], "hi")
        self.assertEqual(len(p["mcp_artifacts"]), 1)

    def test_malformed_stdin_fallback_envelope(self):
        p = engine.build_payload("not json {", lambda h, c: [], "/home", "/tmp")
        self.assertEqual(p["hook_event_name"], "UserPromptSubmit")
        self.assertEqual(p["cwd"], "/tmp")
        self.assertEqual(p["mcp_artifacts"], [])

    def test_event_cwd_overrides_fallback(self):
        raw = json.dumps({"hook_event_name": "UserPromptSubmit", "cwd": "/from/event"})
        captured = {}

        def disc(home, cwd):
            captured["cwd"] = cwd
            return []

        p = engine.build_payload(raw, disc, "/home", "/fallback")
        self.assertEqual(p["cwd"], "/from/event")
        self.assertEqual(captured["cwd"], "/from/event")

    def test_blank_cwd_uses_fallback(self):
        raw = json.dumps({"hook_event_name": "UserPromptSubmit", "cwd": ""})
        captured = {}

        def disc(home, cwd):
            captured["cwd"] = cwd
            return []

        engine.build_payload(raw, disc, "/home", "/fallback")
        self.assertEqual(captured["cwd"], "/fallback")


class TestFsHelpers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_read_json_valid_invalid_missing(self):
        good = os.path.join(self.tmp, "good.json")
        bad = os.path.join(self.tmp, "bad.json")
        with open(good, "w") as f:
            f.write('{"a": 1}')
        with open(bad, "w") as f:
            f.write("{not json")
        self.assertEqual(engine.read_json(good), {"a": 1})
        self.assertIsNone(engine.read_json(bad))
        self.assertIsNone(engine.read_json(os.path.join(self.tmp, "missing.json")))

    def test_file_exists(self):
        self.assertTrue(engine.file_exists(self.tmp))
        self.assertFalse(engine.file_exists(os.path.join(self.tmp, "nope")))

    def test_make_artifact(self):
        self.assertEqual(engine.make_artifact("s", "k", "/p", {"x": 1}),
                         {"scope": "s", "kind": "k", "path": "/p", "content": {"x": 1}})


if __name__ == "__main__":
    unittest.main()
