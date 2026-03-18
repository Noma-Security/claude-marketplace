# Noma Security - Claude Code Hooks Plugin

**Runtime Protection for Claude Code Agents**

Noma Security provides active runtime protection for Claude Code by sitting between your AI agents and their intended actions. This plugin enables you to evaluate, allow, or block high-risk activities in real-time.

For more details, visit [noma.security](https://noma.security).

## What We Protect

With Claude Code Hooks enabled, Noma acts as a security gatekeeper for the following high-risk agent actions:

- **Shell execution**: Prevent unauthorized terminal commands or malicious script injections
- **MCP tool execution**: Governs Model Context Protocol interactions and unauthorized tool use
- **File reads**: Protects sensitive local data (e.g., `.env` files, SSH keys) from being indexed or sent to the LLM
- **User prompt submission**: Scans and filters sensitive data, PCI, PII, PHI before it leaves your local environment

## Prerequisites

- **Claude Code v2.0.12+**: Ensure you are running a supported version of the CLI
- **Noma API Key**: Request an API Key for this plugin from your Noma Technical Account manager (Note: This is not an API Key that you create within the Noma Console)

## Installation

### Step 1: Add the Noma Marketplace

Add the Noma marketplace to your Claude Code instance:

```bash
claude plugin marketplace add https://github.com/Noma-Security/claude-marketplace
```

### Step 2: Install the Guardrails Plugin

Install the specific Noma guardrails hook:

```bash
claude plugin install guardrails@noma-marketplace
```

## Configuration

To connect Claude Code to your Noma instance, you need to configure the `NOMA_API_KEY`.

### Option A: Managed Settings (Recommended for Teams)

If your organization manages Claude Code usage via a centralized `settings.json`, your administrator can push these configurations directly:

1. Navigate to your organization's Claude management console
2. In the Managed settings section, update the `settings.json` to include the Noma environment variables

### Option B: Local Environment

Alternatively, export these variables in your shell profile (`.zshrc` or `.bashrc`):

```bash
export NOMA_API_KEY="your-secret-api-key"
```

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

- **Check Plugin Status**: Run `claude plugin list` to ensure `guardrails@noma-marketplace` is listed and active
- **Restart or Reload**: Always run `/reload-plugins` after making changes to your plugin configuration. Restart Claude after every environment variable change
- **Note**: Changes in the team panel may take a few minutes to be applied

### Managed settings are not appearing

- **Verify JSON Schema**: Ensure your `settings.json` follows the correct Claude Code schema. Invalid syntax will cause the CLI to ignore managed settings
- **Auth Check**: Ensure you are logged into the correct Claude organization using `claude auth status`

### No inferences in Noma

- **API Key Validation**: Check the Claude Code debug logs (found at the path shown during startup) for any `401 Unauthorized` or `403 Forbidden` errors related to Noma

## Beta Status

> **Note**: Claude Code Hooks is currently in **Beta** status. Beta status means Noma is actively researching, iterating, and developing this feature. Based on feedback, market innovation, and technical and commercial viability, Noma may decide to suspend further work on this feature. To gain early access to a beta feature initiative, contact your Noma Technical Account Manager.

## Support

For support and access to beta features, contact your Noma Technical Account Manager.

## About Noma Security

Noma Security handles security for AI, providing comprehensive protection for AI-powered development tools and workflows.
