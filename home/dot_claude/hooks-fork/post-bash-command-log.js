#!/usr/bin/env node
'use strict';

/**
 * Bash Command Audit Log — chezmoi-managed fork of ECC's post-bash-command-log.js.
 *
 * Why this fork exists (task #11 / M5): ECC's scripts/hooks/post-bash-command-log.js
 * appends each executed Bash command to an audit log, but hardcodes the destination as
 * `os.homedir()/.claude/bash-commands.log`. That ignores ECC_AGENT_DATA_HOME, so the
 * cld and cld-r06 accounts would both write to ~/.claude/bash-commands.log and their
 * command histories would collide. This fork resolves the log directory through ECC's
 * own getClaudeDir() (= resolveAgentDataHome, which honours ECC_AGENT_DATA_HOME), so
 * cld writes ~/.claude/bash-commands.log and cld-r06 writes ~/.claude-r06/bash-commands.log.
 *
 * Reuse over reimplementation: the command sanitiser (secret redaction) and the path
 * resolver are require()d from the pinned external rather than copied, so they stay in
 * sync with upstream. On top of ECC's sanitiser the fork layers extraRedact() (extra
 * secret shapes ECC misses) and writes the log owner-only (0600); the audit-log path
 * is resolved via getClaudeDir() instead of the hardcoded ~/.claude. The plugin-root
 * fallback mirrors the PR4 governance-capture fork (probing for scripts/lib/utils.js,
 * the module that exports getClaudeDir).
 *
 * Scope: audit mode only (#7). ECC's cost mode (#8, cost-tracker.log) is not adopted —
 * cost tracking is handled by the dedicated stop:cost-tracker hook (PR3).
 *
 * Wiring (home/dot_claude/settings.json): the ECC post:bash:dispatcher's internal
 * command-log-audit sub-hook is disabled via
 * ECC_DISABLED_HOOKS=post:bash:command-log-audit and this fork runs instead as a
 * standalone PostToolUse Bash hook (`node <this file> audit`). A standalone node entry
 * is required because run-with-flags.js rejects scripts outside the plugin root
 * (path-traversal guard), so the chezmoi-managed fork cannot route through it —
 * matching the PR4 governance-capture fork.
 *
 * Fail-open: every failure path (missing external runtime, parse error, fs error)
 * degrades to a stdin pass-through with NO log line written. When the external runtime
 * is absent the sanitiser is unavailable, so we deliberately skip logging rather than
 * risk persisting an unredacted command — logging must never block Bash execution and
 * must never leak secrets. The process always exits 0. (Silent fail mirrors ECC's own
 * `catch {}` in the upstream hook.)
 */

const fs = require('fs');
const os = require('os');
const path = require('path');

const MAX_STDIN = 1024 * 1024;
const AUDIT_FILE = 'bash-commands.log';

/**
 * Resolve the ECC plugin root (mirrors plugin-hook-bootstrap.js fallback) so the
 * command sanitiser and getClaudeDir() can be require()d from the chezmoi-external
 * runtime. Returns null when no runtime is found (fail-open). Probes for
 * scripts/lib/utils.js, the module that exports getClaudeDir.
 */
function resolvePluginRoot() {
  const probeRel = path.join('scripts', 'lib', 'utils.js');
  const hasRuntime = candidate => {
    try {
      return Boolean(candidate) && fs.existsSync(path.join(path.resolve(candidate), probeRel));
    } catch {
      return false;
    }
  };

  // plugin-hook-bootstrap.js reads CLAUDE_PLUGIN_ROOT, falling back to ECC_PLUGIN_ROOT;
  // honour both so a host that exports only ECC_PLUGIN_ROOT still resolves.
  for (const name of ['CLAUDE_PLUGIN_ROOT', 'ECC_PLUGIN_ROOT']) {
    const envRoot = process.env[name];
    if (envRoot && envRoot.trim() && hasRuntime(envRoot.trim())) {
      return path.resolve(envRoot.trim());
    }
  }

  const home = os.homedir();
  const candidates = [
    path.join(home, '.agents', 'skills', 'ecc'),
    path.join(home, '.claude', 'plugins', 'ecc'),
    path.join(home, '.claude', 'plugins', 'ecc@ecc'),
    path.join(home, '.claude', 'plugins', 'marketplaces', 'ecc'),
  ];
  for (const candidate of candidates) {
    if (hasRuntime(candidate)) {
      return candidate;
    }
  }

  // Plugin-manager cache: ~/.claude/plugins/cache/ecc/<org>/<version>/
  try {
    const cacheBase = path.join(home, '.claude', 'plugins', 'cache', 'ecc');
    for (const org of fs.readdirSync(cacheBase, { withFileTypes: true })) {
      if (!org.isDirectory()) continue;
      for (const version of fs.readdirSync(path.join(cacheBase, org.name), { withFileTypes: true })) {
        if (!version.isDirectory()) continue;
        const candidate = path.join(cacheBase, org.name, version.name);
        if (hasRuntime(candidate)) {
          return candidate;
        }
      }
    }
  } catch {
    // No cache directory — fall through.
  }

  return null;
}

// Defence-in-depth redaction layered ON TOP of ECC's sanitizeCommand (which is still
// applied first, so upstream improvements keep flowing through). ECC covers
// --token / Authorization / AKIA|ASIA / password / gh*_ tokens but misses several
// secret shapes common in shell commands; redacting them before the line is written
// keeps secrets out of bash-commands.log alongside the 0600 file mode below. \r is
// collapsed too (ECC collapses \n only) so a CRLF command leaves no stray carriage
// return in the log.
function extraRedact(text) {
  return String(text)
    .replace(/\r/g, ' ')
    // Uppercase env-style assignments: AWS_SECRET_ACCESS_KEY=, ANTHROPIC_API_KEY=,
    // NPM_TOKEN=, *_PASSWORD= ... (env-var convention is uppercase, so no /i to avoid
    // over-redacting ordinary words).
    .replace(/\b([A-Z][A-Z0-9_]*(?:SECRET|KEY|TOKEN|PASSWORD|PASSWD)[A-Z0-9_]*)=\S+/g, '$1=<REDACTED>')
    // Credentials embedded in a URL: https://user:pass@host -> https://user:<REDACTED>@host
    .replace(/(https?:\/\/[^/\s:@]+:)[^/\s@]+@/g, '$1<REDACTED>@')
    // OpenAI / Anthropic style keys: sk-..., sk-ant-...
    .replace(/\bsk-[A-Za-z0-9_-]{16,}/g, '<REDACTED>');
}

/**
 * Append a sanitised audit line for the Bash command in `rawInput` to the per-account
 * bash-commands.log. Best-effort: any failure degrades to a silent pass-through.
 *
 * @param {string} rawInput - The PostToolUse Bash event JSON from stdin.
 * @param {object} [options]
 * @param {string} [options.mode] - Only 'audit' logs; any other mode passes through.
 * @returns {string} The original stdin, unchanged (PostToolUse pass-through).
 */
function run(rawInput, options = {}) {
  const mode = options.mode || 'audit';
  if (mode === 'audit') {
    try {
      const pluginRoot = resolvePluginRoot();
      if (pluginRoot) {
        const { sanitizeCommand } = require(path.join(pluginRoot, 'scripts', 'hooks', 'post-bash-command-log'));
        const { getClaudeDir } = require(path.join(pluginRoot, 'scripts', 'lib', 'utils'));
        const input = String(rawInput || '').trim() ? JSON.parse(String(rawInput)) : {};
        const command = (input.tool_input && input.tool_input.command) || '?';
        const line = `[${new Date().toISOString()}] ${extraRedact(sanitizeCommand(command))}`;
        const filePath = path.join(getClaudeDir(), AUDIT_FILE);
        fs.mkdirSync(path.dirname(filePath), { recursive: true });
        // Owner-only: the audit log holds (redacted) command history and must not be
        // world/group readable. `mode` only applies on create, so chmod after append
        // also tightens a pre-existing 0644 file (mirrors governance-capture.js).
        fs.appendFileSync(filePath, `${line}\n`, { encoding: 'utf8', mode: 0o600 });
        try {
          fs.chmodSync(filePath, 0o600);
        } catch {
          // Best-effort — chmod may be unsupported on some filesystems.
        }
      }
      // pluginRoot === null: external runtime absent → skip logging (no sanitiser).
    } catch {
      // Logging must never block the calling tool.
    }
  }

  return typeof rawInput === 'string' ? rawInput : JSON.stringify(rawInput);
}

// process.exit() immediately after stdout.write() truncates output larger than the OS
// pipe buffer (~64 KB) — fatal for PostToolUse pass-through of large payloads. Flush
// via the write callback before exiting (regression guarded in tests/files.bats).
function writeAndExit(output) {
  process.exitCode = 0;
  try {
    process.stdout.write(output, () => process.exit(0));
  } catch {
    process.exit(0);
  }
}

// ── stdin entry point ────────────────────────────────────────────────────────
if (require.main === module) {
  const mode = process.argv[2] || 'audit';
  let raw = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => {
    if (raw.length < MAX_STDIN) {
      const remaining = MAX_STDIN - raw.length;
      raw += chunk.substring(0, remaining);
    }
  });
  process.stdin.on('error', () => {
    writeAndExit(raw);
  });
  process.stdin.on('end', () => {
    let output = raw;
    try {
      output = run(raw, { mode });
    } catch {
      output = raw;
    }
    writeAndExit(output);
  });
}

module.exports = {
  resolvePluginRoot,
  run,
};
