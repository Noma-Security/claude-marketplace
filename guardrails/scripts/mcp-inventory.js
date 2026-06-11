// MCP inventory builder for hook-mcp-inventory.sh, written in JXA
// (osascript -l JavaScript) — present on every macOS, so the inventory needs
// no extra dependencies (jq is deliberately not used).
//
// Contract: reads the hook event JSON on stdin, prints the event plus
// mcp_artifacts on stdout. The bats suite in tests/ pins the behavior,
// including the redaction patterns.
//
// Security notes: all parsing is JSON.parse (never eval); per-server output is
// allowlisted to type/url/command/args; env, headers and anything else never
// leave the machine; secret-looking values are masked best-effort.

ObjC.import("Foundation");

var REDACTED = "***REDACTED***";

// --- sanitizers --------------------------------------------------------------

function sanitizeStr(s) {
  return s
    .replace(/([A-Za-z0-9_-]*(?:token|secret|password|passwd|api[_-]?key|apikey|access[_-]?key|credential|auth)[A-Za-z0-9_-]*)=([^ \t]+)/gi, "$1=" + REDACTED)
    .replace(/bearer[ \t]+[^ \t"]+/gi, "Bearer " + REDACTED)
    .replace(/\b(?:github_pat_|ghp_|gho_|ghu_|ghs_|ghr_|glpat-)[A-Za-z0-9_-]+/g, REDACTED)
    .replace(/\bsk-[A-Za-z0-9_-]{8,}/g, REDACTED)
    .replace(/\bxox[baprs]-[A-Za-z0-9-]+/g, REDACTED)
    .replace(/\bAKIA[0-9A-Z]{16}\b/g, REDACTED)
    .replace(/\beyJ[A-Za-z0-9_-]{14,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, REDACTED)
    .replace(/([A-Za-z][A-Za-z0-9+.-]*:\/\/)[^/@ \t]+:[^/@ \t]+@/g, "$1" + REDACTED + "@");
}

var SECRET_FLAG = /^--?[A-Za-z0-9-]*(?:token|secret|password|passwd|api-?key|apikey|access-?key|credential|auth|pat)[A-Za-z0-9-]*$/i;

function sanitizeArgs(args) {
  var out = [];
  for (var i = 0; i < args.length; i++) {
    var prev = i > 0 ? args[i - 1] : null;
    if (typeof prev === "string" && SECRET_FLAG.test(prev)) {
      out.push(REDACTED);
    } else if (typeof args[i] === "string") {
      out.push(sanitizeStr(args[i]));
    } else {
      out.push(args[i]);
    }
  }
  return out;
}

// --- shape helpers -------------------------------------------------------------

function isObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

// Normalize a config file to {name: config}: mcpServers / servers wrapper, or
// a bare map of server-looking objects (never used for ~/.claude.json)
function norm(doc) {
  if (!isObject(doc)) return {};
  if (isObject(doc.mcpServers)) return doc.mcpServers;
  if (isObject(doc.servers)) return doc.servers;
  var bare = {};
  for (var name in doc) {
    var v = doc[name];
    if (isObject(v) && ("command" in v || "url" in v || "type" in v)) bare[name] = v;
  }
  return bare;
}

// Per-server allowlist: type/url/command/args only, strings sanitized so the
// identifier ai-dr derives from them is clean by construction
function cleanServer(cfg) {
  if (!isObject(cfg)) return {};
  var out = {};
  if (cfg.type !== null && cfg.type !== undefined) out.type = cfg.type;
  if (typeof cfg.url === "string") out.url = sanitizeStr(cfg.url);
  if (typeof cfg.command === "string") out.command = sanitizeStr(cfg.command);
  if (Array.isArray(cfg.args)) {
    out.args = sanitizeArgs(cfg.args).map(function (v) {
      // matches jq tostring: 8080 -> "8080", true -> "true"
      return typeof v === "string" ? v : JSON.stringify(v);
    });
  }
  return out;
}

function cleanMap(servers) {
  if (!isObject(servers)) return {};
  var out = {};
  for (var name in servers) out[name] = cleanServer(servers[name]);
  return out;
}

function wrapServers(m) {
  return Object.keys(m).length > 0 ? { mcpServers: m } : {};
}

function serverContent(doc) {
  return wrapServers(cleanMap(norm(doc)));
}

function manifestContent(doc) {
  var servers = isObject(doc) && isObject(doc.mcpServers) ? doc.mcpServers : {};
  return wrapServers(cleanMap(servers));
}

function listsContent(doc) {
  if (!isObject(doc)) return {};
  var out = {};
  ["enabledMcpjsonServers", "disabledMcpjsonServers"].forEach(function (key) {
    if (Array.isArray(doc[key]) && doc[key].length > 0) out[key] = doc[key];
  });
  return out;
}

// --- filesystem (every failure degrades to null/{}) ---------------------------

function readJSON(path) {
  var s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (s.isNil()) return null;
  try {
    return JSON.parse(s.js);
  } catch (e) {
    return null;
  }
}

function fileExists(path) {
  return $.NSFileManager.defaultManager.fileExistsAtPath(path);
}

function getEnv(name) {
  var v = $.NSProcessInfo.processInfo.environment.objectForKey(name);
  return v.isNil() ? null : ObjC.unwrap(v);
}

function readStdin() {
  var data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
  var s = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
  return s.isNil() ? "" : s.js;
}

// --- main ----------------------------------------------------------------------

function run() {
  var event = null;
  try {
    var parsed = JSON.parse(readStdin());
    if (isObject(parsed)) event = parsed;
  } catch (e) {
    event = null;
  }

  var home = getEnv("HOME") || "";
  var cwd = event && typeof event.cwd === "string" && event.cwd !== ""
    ? event.cwd
    : ObjC.unwrap($.NSFileManager.defaultManager.currentDirectoryPath);

  var artifacts = [];
  function addArtifact(scope, kind, path, content) {
    if (isObject(content) && Object.keys(content).length > 0) {
      artifacts.push({ scope: scope, kind: kind, path: path, content: content });
    }
  }

  var claudeJsonPath = home + "/.claude.json";
  var claudeJson = readJSON(claudeJsonPath);

  // User scope in ~/.claude.json: explicit keys only — the file top level is
  // full of unrelated (and sensitive) state, so the bare-map heuristic must
  // not run here
  if (isObject(claudeJson)) {
    var userServers = isObject(claudeJson.mcpServers) ? claudeJson.mcpServers
      : isObject(claudeJson.servers) ? claudeJson.servers : {};
    addArtifact("user", "claude_json", claudeJsonPath, wrapServers(cleanMap(userServers)));

    // Local scope: this project entry in ~/.claude.json — only its MCP keys;
    // the entry also holds prompts and metrics that must never be sent
    var projects = isObject(claudeJson.projects) ? claudeJson.projects : {};
    var entry = isObject(projects[cwd]) ? projects[cwd] : {};
    var localServers = isObject(entry.mcpServers) ? entry.mcpServers : {};
    var localContent = wrapServers(cleanMap(localServers));
    var entryLists = listsContent(entry);
    for (var key in entryLists) localContent[key] = entryLists[key];
    addArtifact("local", "claude_json", claudeJsonPath, localContent);
  }

  // User scope: ~/.claude/mcp.json; project scope: <cwd>/.mcp.json
  addArtifact("user", "claude_mcp_json", home + "/.claude/mcp.json", serverContent(readJSON(home + "/.claude/mcp.json")));
  addArtifact("project", "claude_mcp_json", cwd + "/.mcp.json", serverContent(readJSON(cwd + "/.mcp.json")));

  // Plugin scope: one artifact per installed plugin active for this cwd
  var registry = readJSON(home + "/.claude/plugins/installed_plugins.json");
  if (isObject(registry) && isObject(registry.plugins)) {
    for (var pluginKey in registry.plugins) {
      var installs = registry.plugins[pluginKey];
      if (!Array.isArray(installs)) continue;
      installs.forEach(function (install) {
        if (!isObject(install)) return;
        if (install.scope === "local" && install.projectPath !== cwd) return;
        var installPath = install.installPath;
        if (typeof installPath !== "string" || installPath === "") return;
        var mcpFile = installPath + "/.mcp.json";
        var manifest = installPath + "/.claude-plugin/plugin.json";
        var legacyManifest = installPath + "/plugin.json";
        if (fileExists(mcpFile)) {
          addArtifact("plugin", "claude_mcp_json", mcpFile, serverContent(readJSON(mcpFile)));
        } else if (fileExists(manifest)) {
          addArtifact("plugin", "claude_mcp_json", manifest, manifestContent(readJSON(manifest)));
        } else if (fileExists(legacyManifest)) {
          addArtifact("plugin", "claude_mcp_json", legacyManifest, manifestContent(readJSON(legacyManifest)));
        }
      });
    }
  }

  // Managed scope (enterprise-deployed)
  var managedPaths = [
    "/Library/Application Support/ClaudeCode/managed-mcp.json",
    "/etc/claude-code/managed-mcp.json"
  ];
  for (var i = 0; i < managedPaths.length; i++) {
    if (fileExists(managedPaths[i])) {
      addArtifact("managed", "claude_managed_mcp_json", managedPaths[i], serverContent(readJSON(managedPaths[i])));
      break;
    }
  }

  // Enable/disable lists from settings files
  addArtifact("user", "claude_settings_json", home + "/.claude/settings.json", listsContent(readJSON(home + "/.claude/settings.json")));
  addArtifact("project", "claude_settings_json", cwd + "/.claude/settings.json", listsContent(readJSON(cwd + "/.claude/settings.json")));
  addArtifact("local", "claude_settings_json", cwd + "/.claude/settings.local.json", listsContent(readJSON(cwd + "/.claude/settings.local.json")));

  // Same payload shape as before: full event + mcp_artifacts, or the fallback
  // envelope when stdin was not valid JSON
  var payload = event || { hook_event_name: "UserPromptSubmit", cwd: cwd };
  payload.mcp_artifacts = artifacts;

  return JSON.stringify(payload);
}
