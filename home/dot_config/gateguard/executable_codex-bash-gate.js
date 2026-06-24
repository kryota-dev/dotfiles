#!/usr/bin/env node
'use strict';

/*
 * Cross-harness gateguard — Codex PreToolUse Bash gate (task #26).
 *
 * Codex registers this script as a `PreToolUse` command hook with
 * `matcher = "^Bash$"`. It receives the tool-call JSON on stdin, inspects
 * the Bash command, and DENIES execution when the command matches a
 * destructive pattern. Denial uses the documented JSON form
 * (`hookSpecificOutput.permissionDecision = "deny"` + a non-empty
 * `permissionDecisionReason`, both required by Codex's wire schema); any
 * other outcome leaves the decision unset so Codex falls back to its
 * normal flow.
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
 * This Codex gate is a complementary best-effort layer (Codex also has a
 * sandbox + approval flow). It does not aim for byte-for-byte parity with
 * ECC's token parser, but it hardens the common evasion vectors an LLM
 * may emit: command substitution (even inside double quotes), `sh -c`
 * bodies, subshell `()` / brace `{}` / process-substitution groups, and
 * `env`/`command`/`exec`/`sudo` wrappers.
 *
 * Known best-effort limits (deferred to Codex's sandbox/approval):
 *   - base64/hex-encoded payloads decoded at runtime;
 *   - deeply nested wrapper option parsing (e.g. `sudo -u u … cmd`);
 *   - per-account `settings.json` divergence — the EXTRA set is read from
 *     ~/.claude first (it is account-independent today, task #12).
 */

const fs = require('fs');
const os = require('os');
const path = require('path');

// --- SQL phrases, applied to the de-quoted segment (also catches `psql -c
// "drop table …"` because the quoted body is extracted before stripping).
const DESTRUCTIVE_SQL = /\b(?:drop\s+table|delete\s+from|truncate)\b/i;

// Leading wrappers that pass their tail to another command. Stripping them
// lets `env rm -rf`, `command rm -rf`, `exec rm -rf`, `sudo rm -rf`, and
// `VAR=val rm -rf` be classified on the real command.
const WRAPPER_COMMANDS = new Set([
  'env', 'command', 'exec', 'nohup', 'sudo', 'time', 'builtin', 'setsid', 'stdbuf', 'nice', 'ionice',
]);
const SHELL_COMMANDS = new Set(['sh', 'bash', 'zsh', 'dash', 'ksh']);

/**
 * Resolve the operator EXTRA destructive regex from the Claude settings
 * that hold the task #12 SSOT. An explicit env override wins (handy for
 * tests); otherwise the standard and r06 account `settings.json` files
 * are tried in order. Returns null (built-ins only) when unreadable or
 * invalid so the gate never crashes on operator config errors. A parse
 * failure is surfaced once on stderr (matching ECC) so a broken operator
 * regex is not silently dropped.
 *
 * @returns {RegExp | null}
 */
function getExtraDestructiveRegex() {
  const fromEnv = process.env.GATEGUARD_BASH_EXTRA_DESTRUCTIVE;
  if (fromEnv) {
    try {
      return new RegExp(fromEnv, 'i');
    } catch (err) {
      warnOnce(`ignoring invalid GATEGUARD_BASH_EXTRA_DESTRUCTIVE regex: ${err.message}`);
      return null;
    }
  }

  const settingsPaths = [
    path.join(os.homedir(), '.claude', 'settings.json'),
    path.join(os.homedir(), '.claude-r06', 'settings.json'),
  ];
  for (const p of settingsPaths) {
    let raw;
    try {
      raw = fs.readFileSync(p, 'utf8');
    } catch (_) {
      continue; // missing/unreadable — try the next candidate.
    }
    try {
      const json = JSON.parse(raw);
      const pattern = json && json.env && json.env.GATEGUARD_BASH_EXTRA_DESTRUCTIVE;
      if (typeof pattern === 'string' && pattern.length > 0) {
        return new RegExp(pattern, 'i');
      }
    } catch (err) {
      warnOnce(`ignoring unparseable ${p}: ${err.message}`);
    }
  }
  return null;
}

let warned = false;
function warnOnce(msg) {
  if (warned) return;
  warned = true;
  try {
    process.stderr.write(`[codex-bash-gate] ${msg}\n`);
  } catch (_) { /* stderr write failure is non-fatal */ }
}

/**
 * Replace the contents of single- and double-quoted strings so a phrase
 * inside an echoed argument or commit message ("drop table") does not
 * trigger the destructive detector. Command-substitution and `sh -c`
 * bodies are extracted BEFORE this runs (see collectEmbeddedCommands), so
 * stripping quotes here does not hide a destructive sub-expression.
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
 * Collect destructive-bearing sub-expressions that live inside quotes or
 * shell wrappers, scanned from the RAW command before quotes are stripped:
 *   - `$(...)` and backtick command substitutions (also inside "..."),
 *   - `sh -c '...'` / `bash -c "..."` command bodies.
 * Returns the extra command strings to classify alongside the main line.
 * Runs a couple of passes so a body nested one level deep is still found.
 *
 * @param {string} raw
 * @returns {string[]}
 */
function collectEmbeddedCommands(raw) {
  const out = [];
  let frontier = [raw];
  for (let depth = 0; depth < 3 && frontier.length; depth += 1) {
    const next = [];
    for (const text of frontier) {
      let m;
      const dollar = /\$\(([^()]*)\)/g;
      while ((m = dollar.exec(text))) { out.push(m[1]); next.push(m[1]); }
      const back = /`([^`]*)`/g;
      while ((m = back.exec(text))) { out.push(m[1]); next.push(m[1]); }
      // Quoted bodies passed to a `-c` / `--command` / `-e` / `--eval`
      // flag (sh -c, bash -c, psql -c, mysql -e, …). The body is scanned
      // as its own command so destructive shell *and* SQL hide nowhere.
      const cBody = /\s(?:-[a-zA-Z]*[ce]|--command|--eval)\s+(['"])([\s\S]*?)\1/g;
      while ((m = cBody.exec(text))) { out.push(m[2]); next.push(m[2]); }
    }
    frontier = next;
  }
  return out;
}

/**
 * Promote unquoted subshell / process-substitution delimiters to segment
 * separators so the check also applies inside `$(...)`, backticks, plain
 * `(...)` subshells, `{ ...; }` brace groups, and `<(...)` process
 * substitution. Run iteratively to handle a layer of nesting.
 *
 * @param {string} input
 * @returns {string}
 */
function explodeGroups(input) {
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
 * separators and group delimiters. Quotes are stripped first so
 * separators inside quotes do not split. Per-segment comments are removed.
 *
 * @param {string} input
 * @returns {string[]}
 */
function splitSegments(input) {
  const exploded = explodeGroups(stripQuotedStrings(input));
  return exploded
    .split(/[;|&\n(){}]+/)
    .map((s) => s.replace(/#.*$/, '').trim())
    .filter((s) => s.length > 0);
}

/**
 * Tokenize a single segment on whitespace, then strip leading wrappers
 * (`env`, `sudo`, `exec`, `VAR=val`, …) so the real command is exposed.
 *
 * @param {string} segment
 * @returns {string[]}
 */
function tokenizeCommand(segment) {
  let tokens = segment.split(/\s+/).filter((t) => t.length > 0);
  // Strip leading env-assignments and wrapper commands repeatedly.
  let changed = true;
  while (changed && tokens.length > 0) {
    changed = false;
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[0])) {
      tokens = tokens.slice(1);
      changed = true;
      continue;
    }
    if (WRAPPER_COMMANDS.has(commandBasename(tokens[0]))) {
      tokens = tokens.slice(1);
      // Drop immediate option flags of the wrapper (best-effort, e.g. `sudo -n`).
      while (tokens.length > 0 && tokens[0].startsWith('-')) tokens = tokens.slice(1);
      changed = true;
    }
  }
  return tokens;
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
 * `dd` writing/reading a device or file. `if=`/`of=` may appear in any
 * order, so a token scan (not a positional regex) is used.
 *
 * @param {string[]} tokens
 * @returns {boolean}
 */
function isDestructiveDd(tokens) {
  if (tokens.length === 0 || commandBasename(tokens[0]) !== 'dd') return false;
  return tokens.slice(1).some((t) => /^(?:if|of)=/.test(t));
}

const hasForceFlag = (t) => t === '--force' || /^-[a-zA-Z]*f/.test(t); // lowercase f only

/**
 * Destructive `git` subcommands. Mirrors the high-value cases of ECC's
 * `isDestructiveGit`: `reset --hard`, `clean -f`, `push --force`/`-f`/
 * `+refspec` (but not lone `--force-with-lease`), `checkout`/`switch`
 * `--force`/`--`/`.`, `branch -D`, `commit --amend`, `rm -r`,
 * `filter-repo`/`filter-branch`.
 *
 * @param {string[]} tokens
 * @returns {boolean}
 */
function isDestructiveGit(tokens) {
  if (tokens.length < 2 || commandBasename(tokens[0]) !== 'git') return false;
  // Skip leading global options to find the subcommand. Some options take a
  // separate value (`-c key=val`, `-C path`, `--git-dir path`) — consume it
  // so the value is not mistaken for the subcommand.
  let i = 1;
  const valueConsumingShort = new Set(['-c', '-C']);
  const valueConsumingLong = new Set(['--git-dir', '--work-tree', '--namespace', '--super-prefix']);
  while (i < tokens.length) {
    const t = tokens[i];
    if (valueConsumingShort.has(t) || valueConsumingLong.has(t)) { i += 2; continue; }
    if (t.startsWith('--git-dir=') || t.startsWith('--work-tree=') || t.startsWith('--namespace=') || t.startsWith('--super-prefix=')) { i += 1; continue; }
    if (t.startsWith('-')) { i += 1; continue; }
    break;
  }
  if (i >= tokens.length) return false;
  const sub = tokens[i].toLowerCase();
  const rest = tokens.slice(i + 1);

  if (sub === 'reset') return rest.includes('--hard');
  if (sub === 'clean') return rest.some(hasForceFlag);
  if (sub === 'push') {
    // A bare --force/-f overrides lease protection; a `+refspec` is an
    // inline force. Lone --force-with-lease is the safe form.
    if (rest.some(hasForceFlag)) return true;
    if (rest.some((t) => /^\+\S+/.test(t))) return true;
    return false;
  }
  if (sub === 'checkout' || sub === 'switch') {
    return rest.some((t) => t === '--' || t === '.' || t === '--discard-changes' || hasForceFlag(t));
  }
  if (sub === 'branch') return rest.some((t) => t === '-D' || /^-[a-zA-Z]*D/.test(t));
  if (sub === 'commit') return rest.includes('--amend');
  if (sub === 'rm') {
    return rest.some((t) => t === '-r' || t === '--recursive' || (t.startsWith('-') && !t.startsWith('--') && /[rR]/.test(t.slice(1))));
  }
  if (sub === 'filter-repo' || sub === 'filter-branch') return true;
  return false;
}

/**
 * Decide whether a Bash command is destructive. Returns the matched
 * category label (for the denial reason) or null. The main line plus any
 * embedded command-substitution / `sh -c` bodies are all scanned.
 *
 * @param {string} command
 * @returns {string | null}
 */
function classifyDestructive(command) {
  const extra = getExtraDestructiveRegex();
  const sources = [command, ...collectEmbeddedCommands(command)];
  for (const source of sources) {
    for (const segment of splitSegments(source)) {
      if (DESTRUCTIVE_SQL.test(segment)) return 'SQL destructive statement';
      const tokens = tokenizeCommand(segment);
      if (isDestructiveRm(tokens)) return 'recursive force rm';
      if (isDestructiveDd(tokens)) return 'dd to/from a device or file';
      if (isDestructiveGit(tokens)) return 'destructive git subcommand';
      if (extra && extra.test(segment)) return 'operator destructive pattern (task #12 SSOT)';
    }
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
