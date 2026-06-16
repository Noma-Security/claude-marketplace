#!/usr/bin/env python3
"""Unit tests for noma_inventory.redaction — the secret-masking patterns."""

import unittest

import _bootstrap  # noqa: F401  (sets sys.path)
from noma_inventory import redaction

R = redaction.REDACTED
ss = redaction.sanitize_str
sa = redaction.sanitize_args


class TestSanitizeStr(unittest.TestCase):
    def test_github_gitlab_token_family(self):
        for tok in ("github_pat_11AAAAA0secret", "ghp_abcdefgh12345678901234",
                    "gho_abcdefgh12345678901234", "ghu_abcdefgh12345678901234",
                    "ghs_abcdefgh12345678901234", "ghr_abcdefgh12345678901234",
                    "glpat-abcdefgh123456"):
            self.assertEqual(ss(tok), R, tok)

    def test_sk_keys_length_and_boundary(self):
        self.assertEqual(ss("sk-abcdefgh"), R)
        self.assertEqual(ss("sk-proj-longersecretvalue"), R)
        self.assertEqual(ss("sk-dev"), "sk-dev")
        self.assertEqual(ss("task-12345678"), "task-12345678")

    def test_slack_known_prefixes_only(self):
        self.assertEqual(ss("xoxb-1234-5678-abcdef"), R)
        self.assertEqual(ss("xoxp-1111-2222-cccc"), R)
        self.assertEqual(ss("xoxz-not-a-real-prefix"), "xoxz-not-a-real-prefix")

    def test_aws_exact_shape(self):
        self.assertEqual(ss("AKIAIOSFODNN7EXAMPLE"), R)
        self.assertEqual(ss("AKIA123"), "AKIA123")
        self.assertEqual(ss("akiaiosfodnn7example"), "akiaiosfodnn7example")

    def test_jwt_but_not_short(self):
        self.assertEqual(ss("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig-part"), R)
        self.assertEqual(ss("eyJa.b.c"), "eyJa.b.c")

    def test_bearer_normalized(self):
        self.assertEqual(ss("Bearer abc123token"), "Bearer " + R)
        self.assertEqual(ss("bearer lowertoken123"), "Bearer " + R)
        self.assertEqual(ss("BEARER YELLING99"), "Bearer " + R)
        self.assertEqual(ss("Bearer"), "Bearer")

    def test_key_value_secret_keys(self):
        self.assertEqual(ss("MY_API_TOKEN=abc123"), "MY_API_TOKEN=" + R)
        self.assertEqual(ss("password=hunter2"), "password=" + R)
        self.assertEqual(ss("db-credential-prod=s3cret"), "db-credential-prod=" + R)
        self.assertEqual(ss("GITHUB_AUTH=xyz"), "GITHUB_AUTH=" + R)

    def test_key_value_non_secret_keys_kept(self):
        self.assertEqual(ss("NODE_ENV=production"), "NODE_ENV=production")
        self.assertEqual(ss("WORKERS=4"), "WORKERS=4")

    def test_url_userinfo(self):
        self.assertEqual(ss("https://admin:letmein99@mcp.example/path"),
                         "https://" + R + "@mcp.example/path")
        self.assertEqual(ss("postgres://svc:dbpass42@db.internal:5432/app"),
                         "postgres://" + R + "@db.internal:5432/app")

    def test_ssh_remote_kept(self):
        self.assertEqual(ss("git@github.com:org/repo.git"), "git@github.com:org/repo.git")

    def test_secret_query_param(self):
        out = ss("https://x.example/mcp?api_key=abc123&page=2")
        self.assertTrue(out.startswith("https://x.example/mcp?api_key=" + R), out)
        self.assertNotIn("abc123", out)

    def test_multiple_secrets_one_string(self):
        self.assertEqual(
            ss("run with Bearer tok111 and ghp_tok2222222222222222 and PASSWORD=tok333"),
            "run with Bearer " + R + " and " + R + " and PASSWORD=" + R)

    def test_clean_strings_unchanged(self):
        self.assertEqual(ss("https://plain.example/mcp"), "https://plain.example/mcp")
        self.assertEqual(ss("@scope/server-name"), "@scope/server-name")


class TestSanitizeArgs(unittest.TestCase):
    def test_bare_token_args(self):
        self.assertEqual(sa(["ghp_abcdefgh12345678901234", "glpat-abcdefgh123456"]), [R, R])

    def test_secret_flag_spellings(self):
        out = sa(["--token", "v1", "--api-key", "v2", "--apikey", "v3", "--access-key", "v4",
                  "--auth", "v5", "--pat", "v6", "--client-secret", "v7", "-password", "v8"])
        for i in (1, 3, 5, 7, 9, 11, 13, 15):
            self.assertEqual(out[i], R)
        self.assertNotIn("v1", out)
        self.assertNotIn("v8", out)

    def test_non_secret_flags_kept(self):
        out = sa(["--port", "8080", "-o", "out.json", "--verbose", "true"])
        self.assertEqual([out[1], out[3], out[5]], ["8080", "out.json", "true"])

    def test_inline_flag_value(self):
        self.assertEqual(sa(["--api-key=inline-secret-1", "--token=inline-secret-2"]),
                         ["--api-key=" + R, "--token=" + R])

    def test_over_redact_keyword_flag(self):
        self.assertEqual(sa(["--author", "Jane Doe"]), ["--author", R])

    def test_non_string_masked_after_flag_else_untouched(self):
        # sanitize_args masks the value after a secret flag; stringifying other
        # non-strings is clean_server's job, so they pass through here unchanged.
        out = sa(["--token", 12345, "-p", 8080, True])
        self.assertEqual(out[1], R)
        self.assertEqual(out[3], 8080)
        self.assertEqual(out[4], True)


if __name__ == "__main__":
    unittest.main()
