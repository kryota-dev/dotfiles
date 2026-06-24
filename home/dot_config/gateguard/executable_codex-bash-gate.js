#!/usr/bin/env node
'use strict';

/*
 * Cross-harness gateguard — Codex PreToolUse Bash gate (task #26).
 *
 * Codex registers this script as a `PreToolUse` command hook with
 * `matcher = "^Bash$"`. It receives the tool-call JSON on stdin, inspects
 * the Bash command, and DENIES execution when the command matches a
 * destructive pattern. Denial uses the documented JSON form
 * (`hookSpecificOutput.permissionDecision = "deny"`); any other outcome
 * leaves the decision unset so Codex falls back to its normal flow.
 *
 * SSOT relationship with Claude (task #12):
 *   - Claude's authoritative gate is the ECC `gateguard-fact-force.js`
 *     hook (Theme H), which consumes `GATEGUARD_BASH_EXTRA_DESTRUCTIVE`
 *     from `~/.claude/settings.json`.
 *   - This script re-reads that SAME env value out of `settings.json` at
 *     runtime so the operator-tuned destructive set lives in exactly one
 *     place. The built-in patterns below always apply and degrade
 *     gracefully (fail-open) when settings.json cannot be read, mirroring
 *     ECC's "a hook must never crash tool execution" philosophy.
 *
 * This Codex gate is intentionally a complementary best-effort layer
 * (Codex also has sandbox + approval). It does not aim for byte-for-byte
 * parity with ECC's token parser; it ports the high-value built-ins
 * (rm -rf / destructive git / SQL drop+truncate / dd) and shares the
 * operator EXTRA regex.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');

// --- SQL / dd patterns: stable phrases, applied to the de-quoted line. ---
const DESTRUCTIVE_SQL_DD = /\b(drop\s+table|delete\s+from|truncate|dd\s+if=)\b/i;

/**
 * Resolve the operator EXTRA destructive regex from the Claude settings
 * that hold the task #12 SSOT. An explicit env override wins (handy for
 * tests); otherwise the standard and r06 account `settings.json` files
 * are tried in order. Returns null (built-ins only) when unreadable or
 * invalid so the gate never crashes on operator config errors.
 *
 * @returns {RegExp | null}
 */
function getExtraDestructiveRegex() {
  const fromEnv = process.env.GATEGUARD_BASH_EXTRA_DESTRUCTIVE;
  if (fromEnv) {
    try {
      return new RegExp(fromEnv, 'i');
    } catch (_) {
      return null;
    }
  }

  const settingsPaths = [
    path.join(os.homedir(), '.claude', 'settings.json'),
    path.join(os.homedir(), '.claude-r06', 'settings.json'),
  ];
  for (const p of settingsPaths) {
    try {
      const raw = fs.readFileSync(p, 'utf8');
      const json = JSON.parse(raw);
      const pattern = json && json.env && json.env.GATEGUARD_BASH_EXTRA_DESTRUCTIVE;
      if (typeof pattern === 'string' && pattern.length > 0) {
        return new RegExp(pattern, 'i');
      }
    } catch (_) {
      // Unreadable / malformed / missing — try the next candidate.
    }
  }
  return null;
}

/**
 * Replace the contents of single- and double-quoted strings so a phrase
 * inside an echoed argument or commit message ("drop table") does not
 * trigger the destructive detector.
 *
 * @param {string} input
 * @returns {string}
 */
function stripQuotedStrings(input) {
  return input
    .replace(/'(?:[^'\\]|\\.)*'/g, "''")
    .replace(/"(?:[^"\\]|\\.)*"/g, '""');
}

/**
 * Promote subshell delimiters to top-level separators so the check also
 * applies inside `$(...)` and backtick sub-expressions.
 *
 * @param {string} input
 * @returns {string}
 */
function explodeSubshells(input) {
  let out = input;
  for (let i = 0; i < 4; i += 1) {
    const before = out;
    out = out.replace(/\$\(([^()`]*)\)/g, ';$1;');
    out = out.replace(/`([^`]*)`/g, ';$1;');
    if (out === before) break;
  }
  return out;
}

/**
 * Split a command line into top-level segments at unquoted shell
 * separators. Quotes are stripped first so separators inside quotes do
 * not split. Per-segment comments are removed.
 *
 * @param {string} input
 * @returns {string[]}
 */
function splitSegments(input) {
  const exploded = explodeSubshells(stripQuotedStrings(input));
  return exploded
    .split(/[;|&\n]+/)
    .map((s) => s.replace(/#.*$/, '').trim())
    .filter((s) => s.length > 0);
}

/**
 * Tokenize a single segment on whitespace. Quotes are already stripped.
 *
 * @param {string} segment
 * @returns {string[]}
 */
function tokenize(segment) {
  return segment.split(/\s+/).filter((t) => t.length > 0);
}

/**
 * Strip a leading path so `/bin/rm` matches the `rm` rules.
 *
 * @param {string} token
 * @returns {string}
 */
function commandBasename(token) {
  const slash = token.lastIndexOf('/');
  return slash === -1 ? token : token.slice(slash + 1);
}

/**
 * `rm` invoked with both recursive and force flags (combined or split).
 *
 * @param {string[]} tokens
 * @returns {boolean}
 */
function isDestructiveRm(tokens) {
  if (tokens.length === 0 || commandBasename(tokens[0]) !== 'rm') return false;
  let hasR = false;
  let hasF = false;
  for (const t of tokens.slice(1)) {
    if (t === '--recursive') { hasR = true; continue; }
    if (t === '--force') { hasF = true; continue; }
    if (!t.startsWith('-') || t.startsWith('--')) continue;
    const body = t.slice(1);
    if (/[rR]/.test(body)) hasR = true;
    if (/f/.test(body)) hasF = true;
  }
  return hasR && hasF;
}

/**
 * Destructive `git` subcommands: `reset --hard`, `clean -f...`,
 * `push --force`/`-f` (but not `--force-with-lease`), `branch -D`,
 * `checkout -f` / `switch -f`, `filter-repo` / `filter-branch`.
 *
 * @param {string[]} tokens
 * @returns {boolean}
 */
function isDestructiveGit(tokens) {
  if (tokens.length < 2 || commandBasename(tokens[0]) !== 'git') return false;
  // Skip leading global options to find the subcommand.
  let i = 1;
  const valueConsuming = new Set(['-c', '-C']);
  while (i < tokens.length) {
    const t = tokens[i];
    if (valueConsuming.has(t)) { i += 2; continue; }
    if (t.startsWith('-')) { i += 1; continue; }
    break;
  }
  if (i >= tokens.length) return false;
  const sub = tokens[i].toLowerCase();
  const rest = tokens.slice(i + 1);
  const hasForceFlag = (t) => t === '--force' || /^-[a-zA-Z]*f/.test(t);

  if (sub === 'reset') return rest.includes('--hard');
  if (sub === 'clean') return rest.some(hasForceFlag);
  if (sub === 'push') {
    if (rest.includes('--force-with-lease')) return false;
    return rest.some(hasForceFlag);
  }
  if (sub === 'checkout' || sub === 'switch') return rest.some(hasForceFlag);
  if (sub === 'branch') return rest.some((t) => t === '-D' || /^-[a-zA-Z]*D/.test(t));
  if (sub === 'filter-repo' || sub === 'filter-branch') return true;
  return false;
}

/**
 * Decide whether a Bash command is destructive. Returns the matched
 * category label (for the denial reason) or null.
 *
 * @param {string} command
 * @returns {string | null}
 */
function classifyDestructive(command) {
  const extra = getExtraDestructiveRegex();
  const segments = splitSegments(command);
  for (const segment of segments) {
    if (DESTRUCTIVE_SQL_DD.test(segment)) return 'SQL/dd destructive statement';
    const tokens = tokenize(segment);
    if (isDestructiveRm(tokens)) return 'recursive force rm';
    if (isDestructiveGit(tokens)) return 'destructive git subcommand';
    if (extra && extra.test(segment)) return 'operator destructive pattern (task #12 SSOT)';
  }
  return null;
}

function readStdin() {
  try {
    return fs.readFileSync(0, 'utf8');
  } catch (_) {
    return '';
  }
}

function main() {
  const input = readStdin();
  let payload;
  try {
    payload = JSON.parse(input);
  } catch (_) {
    // No parseable payload — do not interfere with Codex.
    process.exit(0);
  }

  const command =
    payload && payload.tool_input && typeof payload.tool_input.command === 'string'
      ? payload.tool_input.command
      : '';
  if (!command) process.exit(0);

  const category = classifyDestructive(command);
  if (!category) process.exit(0);

  const reason =
    `Destructive command blocked by cross-harness gateguard (${category}). ` +
    'This shares the Claude task #12 destructive set. ' +
    'Re-run with explicit operator approval if this is intended.';

  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: reason,
      },
    })
  );
  process.exit(0);
}

main();
