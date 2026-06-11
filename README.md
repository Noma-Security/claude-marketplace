# Noma Security - Claude Code Hooks Plugin

**Runtime Protection for Claude Code Agents**

Noma Security provides active runtime protection for Claude Code by sitting between your AI agents and their intended actions. This plugin enables you to evaluate, allow, or block high-risk activities in real-time.

For more details, visit [noma.security](https://noma.security).

## What We Protect

With Claude Code Hooks enabled, Noma acts as a security gatekeeper for the following high-risk agent actions:

- **Shell execution**: Prevent unauthorized terminal commands or malicious script injections
- **MCP tool execution**: Governs Model Context Protocol interactions and unauthorized tool use
- **MCP server inventory** (macOS): On every prompt, sends the MCP server configuration files as separate per-scope artifacts (local, project, user, plugin, managed) plus the enable/disable lists; the merged per-session inventory is reconstructed by Noma server-side, and mid-session changes (plugin installs, `/reload-plugins`, `claude mcp add`) are picked up by the next prompt. Only server identity fields (`type`, `url`, `command`, `args`) are sent per server, with secret-looking values masked — `env`, `headers`, and all other fields never leave your machine. Built on `osascript`, which ships with every macOS — no extra dependencies; on Linux this feature is currently skipped (all other protections are unaffected)
- **File reads**: Protects sensitive local data (e.g., `.env` files, SSH keys) from being indexed or sent to the LLM
- **User prompt submission**: Scans and filters sensitive data, PCI, PII, PHI before it leaves your local environment

## Prerequisites

- **Claude Code v2.0.12+**: Ensure you are running a supported version of the CLI
- **Noma API Key**: Request an API Key for this plugin from your Noma Technical Account manager (Note: This is not an API Key that you create within the Noma Console)
- **Supported OS**: macOS, Linux, or Windows
  - **macOS / Linux**: requires `bash` and `curl` (both preinstalled on macOS; available by default on most Linux distributions). The MCP server inventory uses the built-in `osascript` (present on every macOS); on Linux only that feature is skipped
  - **Windows**: requires Windows PowerShell 5.1 or later (preinstalled on Windows 10 / 11)

## Installation

### Step 1: Add the Noma Marketplace

Add the Noma marketplace to your Claude Code instance:

```bash
claude plugin marketplace add https://github.com/Noma-Security/claude-marketplace
```

### Step 2: Install the Guardrails Plugin for Your OS

The Noma marketplace ships **two plugins** — choose the one matching your operating system. **Do not install both** on the same machine; they would double-fire every hook event and produce duplicate inferences in the Noma Console.

| Plugin | OS | Runtime | Hook Scripts |
|---|---|---|---|
| `guardrails` | macOS, Linux | bash + curl | `hook-curl.sh`, `hook-mcp-inventory.sh` (+ `mcp-inventory.js` via macOS's built-in `osascript`) |
| `guardrails-windows` | Windows | PowerShell 5.1+ | `hook-curl.ps1` |

#### macOS / Linux

```bash
claude plugin install guardrails@noma-marketplace
```

#### Windows

```bash
claude plugin install guardrails-windows@noma-marketplace
```

Both plugins implement the same protection model and connect to the same Noma API endpoints — only the runtime and credential-storage mechanism differ.

## Configuration

To connect Claude Code to your Noma instance, you need to configure the `NOMA_API_KEY`.

### Option A: Managed Settings (Recommended for Teams)

If your organization manages Claude Code usage via a centralized `settings.json`, your administrator can push these configurations directly:

1. Navigate to your organization's Claude management console
2. In the Managed settings section, update the `settings.json` to include the Noma environment variables

### Option B: Local Environment

For individual setups, instead of exporting variables in your shell profile, Claude Code reads configurations from a local JSON file. This mirrors the structure used in the Managed Settings method.

To configure your local environment, add your Noma credentials to the following path: ~/.claude/settings.json
Example settings.json structure:

```json
{
  "NOMA_API_KEY": "your-secret-api-key"
}
```

### Option C: Operating System Credential Store (Most Secure Local)

If `NOMA_API_KEY` is not set via env var or `settings.json`, the hook scripts will look it up from your operating system's built-in credential store. The key is encrypted at rest by the OS and bound to your user account.

#### macOS — Keychain

Store the key once:

```bash
security add-generic-password -s "noma-guardrails" -a "$USER" -w "your-secret-api-key"
```

The `guardrails` plugin retrieves it via `security find-generic-password` at hook fire time.

#### Linux — libsecret / GNOME Keyring

Requires `secret-tool` (package `libsecret-tools` on Debian/Ubuntu, `libsecret` on Fedora):

```bash
secret-tool store --label="Noma Guardrails" service noma-guardrails username "$USER"
# secret-tool will prompt for the API key
```

The `guardrails` plugin retrieves it via `secret-tool lookup` at hook fire time.

#### Windows — Credential Manager

Store the key via `cmdkey` (run from PowerShell so `$env:USERNAME` expands to your Windows login):

```powershell
cmdkey /generic:noma-guardrails /user:$env:USERNAME /pass:your-secret-api-key
```

Or via the GUI (Control Panel → User Accounts → Credential Manager → Windows Credentials → Add a generic credential):

- **Internet or network address**: `noma-guardrails`
- **User name**: your Windows username (the script doesn't filter by this field — only the password is read — but using your real login keeps the entry recognizable in the Credential Manager UI)
- **Password**: your Noma API key

The `guardrails-windows` plugin retrieves it via the Windows `CredRead` API at hook fire time, looking up only by the target name `noma-guardrails`. The credential is DPAPI-encrypted by Windows and only accessible to the same user account on the same machine.

## Activation

### Initialize and Approve Hooks

Once the plugin and settings are in place, authorize the managed settings within Claude Code:

1. **Launch Claude Code**: Start a new session
2. **Approve Managed Settings**: You'll see a prompt regarding "Managed settings require approval." This is a security feature to ensure you trust the configured API endpoints
3. **Select 1.** Yes, I trust these settings to proceed

If you installed the plugin during an active session, refresh the state:

```bash
/reload-plugins
```

## Verification

To confirm that Noma is actively protecting your session:

1. **Test an action**: Ask Claude Code to perform a sensitive task, such as "Read the contents of my ~/.ssh/config file"
2. **Check Noma Console**: Navigate to Runtime Protection → Inferences in the Noma Console
3. Filter by `Application ID -> Claude-Code` to see real-time allow/block events

Look for Debug mode indicators and status bar labels to confirm protection is active.

## Troubleshooting

### Hooks are not firing

- **Check Plugin Status**: Run `claude plugin list` to ensure `guardrails@noma-marketplace` (macOS / Linux) or `guardrails-windows@noma-marketplace` (Windows) is listed and active
- **Restart or Reload**: Always run `/reload-plugins` after making changes to your plugin configuration. Restart Claude after every environment variable change
- **Wrong plugin for OS**: If you installed `guardrails` on Windows or `guardrails-windows` on macOS / Linux, the hook script will fail to launch (missing `bash` or `powershell.exe` respectively). Uninstall the wrong plugin and install the one matching your OS
- **Note**: Changes in the team panel may take a few minutes to be applied

### PowerShell execution policy errors (Windows only)

If you see errors like `File ...hook-curl.ps1 cannot be loaded because running scripts is disabled on this system`:

- Confirm the plugin is `guardrails-windows`, not `guardrails`
- The hook config invokes PowerShell with `-ExecutionPolicy Bypass`, which should override any system policy for the hook process only. If the error persists, your organization may enforce execution policy via Group Policy (`MachinePolicy` scope), which `-ExecutionPolicy Bypass` cannot override. Contact your IT administrator to allow `guardrails-windows` hook scripts, or set `NOMA_API_KEY` via env var / `settings.json` and verify the script is reachable

### NOMA_API_KEY not found

The hook scripts look up the key in this order — first match wins:

1. Environment variable `NOMA_API_KEY`
2. `~/.claude/settings.json` (`NOMA_API_KEY` field)
3. OS credential store:
   - macOS: Keychain entry with service `noma-guardrails`
   - Linux: libsecret entry with service `noma-guardrails`
   - Windows: Credential Manager target `noma-guardrails`

If none are configured, hooks will exit with `NOMA_API_KEY not found...`. Use one of the methods in the [Configuration](#configuration) section above.

### Managed settings are not appearing

- **Verify JSON Schema**: Ensure your `settings.json` follows the correct Claude Code schema. Invalid syntax will cause the CLI to ignore managed settings
- **Auth Check**: Ensure you are logged into the correct Claude organization using `claude auth status`

### No inferences in Noma

- **API Key Validation**: Check the Claude Code debug logs (found at the path shown during startup) for any `401 Unauthorized` or `403 Forbidden` errors related to Noma

## Beta Status

> **Note**: Claude Code Hooks is currently in **Beta** status. Beta status means Noma is actively researching, iterating, and developing this feature. Based on feedback, market innovation, and technical and commercial viability, Noma may decide to suspend further work on this feature. To gain early access to a beta feature initiative, contact your Noma Technical Account Manager.

## Development

The bash hook scripts are covered by a [bats-core](https://github.com/bats-core/bats-core) test suite that runs hermetically against a sandbox `HOME` (no network, no access to your real Claude Code config):

```bash
brew install bats-core jq   # jq is used by test assertions only, never by the hooks
bats tests/
```

CI (GitHub Actions) runs the suite on Ubuntu and macOS — the macOS job uses the stock `/bin/bash` 3.2 that real plugin users run — plus `shellcheck` on all scripts.

## Support

For support and access to beta features, contact your Noma Technical Account Manager.

## About Noma Security

Noma Security handles security for AI, providing comprehensive protection for AI-powered development tools and workflows.
