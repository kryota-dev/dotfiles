#!/usr/bin/env node
'use strict';

/**
 * Governance Event Capture — chezmoi-managed fork of ECC's governance-capture.js.
 *
 * Why this fork exists (task #6 / M3): ECC's scripts/hooks/governance-capture.js
 * detects governance-relevant events (secrets, approval-required commands, sensitive
 * paths, elevated-privilege commands) but only writes them to stderr — its
 * documented state-store persistence is never wired up. This fork reuses ECC's
 * detection logic verbatim (require()d from the pinned external) and ADDS durable
 * persistence to the per-account governance_events table.
 *
 * Why node:sqlite instead of ECC's state-store: ECC's state-store is built on the
 * sql.js npm package and an ajv-validated schema file, none of which the
 * chezmoi-external adoption provisions (no `npm install`, so node_modules and the
 * schemas/ dir are absent). Node's built-in node:sqlite (DatabaseSync) needs no
 * dependencies and writes a standard SQLite3 file that ECC's sql.js readers can
 * still open. The schema is applied by replaying ECC's own migration SQL
 * (require()d from scripts/lib/state-store/migrations.js, which is pure JS with no
 * sql.js/ajv dependency), so the resulting database is schema-compatible with what
 * ECC would have produced — including the schema_migrations bookkeeping — and ECC's
 * later migrations skip cleanly. We replay the MIGRATIONS array ourselves rather
 * than calling ECC's applyMigrations() because the latter uses better-sqlite3's
 * db.transaction(), which node:sqlite's DatabaseSync does not expose; if ECC ever
 * changes its migration-apply semantics, this replay loop must be updated by hand.
 *
 * WAL + busy_timeout match ECC's own connection (state-store/index.js sets WAL) and
 * let concurrent hook processes (parallel tool calls each fire pre+post) serialise
 * writes instead of dropping audit rows on SQLITE_BUSY.
 *
 * Foreign keys are intentionally left disabled on this connection: this hook only
 * appends governance rows, whose session_id may reference a session this hook does
 * not own (it never creates `sessions` rows). FK enforcement would reject those
 * inserts; raw SQLite defaults FK off anyway, so the declared constraint stays
 * inert here and is enforced only when ECC opens the same file with FK on.
 *
 * Account isolation: dbPath derives from ECC_AGENT_DATA_HOME (exported by the
 * cld / cld-r06 aliases), so cld writes ~/.claude/ecc/state.db and cld-r06 writes
 * ~/.claude-r06/ecc/state.db.
 *
 * Fail-open: every failure path (governance capture disabled, missing external
 * runtime, parse error, DB error) degrades to stderr-only emit plus a stdin
 * pass-through. The tool pipeline is never blocked and the process exits 0.
 *
 * Wiring (home/dot_claude/settings.json): invoked directly as `node <this file>`
 * for both pre:governance-capture (PreToolUse) and post:governance-capture
 * (PostToolUse); the phase is derived from the payload's hook_event_name. Enable
 * with ECC_GOVERNANCE_CAPTURE=1.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');

const MAX_STDIN = 1024 * 1024;

function emitGovernanceEvent(event) {
  process.stderr.write(`[governance] ${JSON.stringify(event)}\n`);
}

/**
 * Resolve the ECC plugin root (mirrors plugin-hook-bootstrap.js fallback) so the
 * detection logic and migration SQL can be require()d from the chezmoi-external
 * runtime. Returns null when no runtime is found (fail-open).
 */
function resolvePluginRoot() {
  const probeRel = path.join('scripts', 'lib', 'state-store', 'migrations.js');
  const hasRuntime = candidate => {
    try {
      return Boolean(candidate) && fs.existsSync(path.join(path.resolve(candidate), probeRel));
    } catch {
      return false;
    }
  };

  const envRoot = process.env.CLAUDE_PLUGIN_ROOT;
  if (envRoot && envRoot.trim() && hasRuntime(envRoot.trim())) {
    return path.resolve(envRoot.trim());
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

function stateDbPath() {
  const base = process.env.ECC_AGENT_DATA_HOME || path.join(os.homedir(), '.claude');
  return path.join(base, 'ecc', 'state.db');
}

// Best-effort owner-only (0600) on the audit DB and its WAL sidecars.
function hardenDbPerms(dbPath) {
  for (const suffix of ['', '-wal', '-shm']) {
    try {
      fs.chmodSync(dbPath + suffix, 0o600);
    } catch {
      // Sidecar may not exist / chmod unsupported — best-effort only.
    }
  }
}

/**
 * Persist governance events to the per-account state.db. Best-effort: any failure
 * degrades to stderr-only (the events were already emitted by the caller).
 */
function persistEvents(events, pluginRoot) {
  if (!events.length || !pluginRoot) {
    return;
  }

  let DatabaseSync;
  try {
    ({ DatabaseSync } = require('node:sqlite'));
  } catch {
    // Emit the drop marker so every persistence-failure path is observable,
    // not just DB-open/write errors. (node:sqlite needs Node >= 22.5.)
    process.stderr.write('[governance][persist-failed] node:sqlite unavailable\n');
    return;
  }

  let MIGRATIONS;
  try {
    ({ MIGRATIONS } = require(path.join(pluginRoot, 'scripts', 'lib', 'state-store', 'migrations.js')));
  } catch (err) {
    process.stderr.write(`[governance][persist-failed] migration load failed: ${err.message}\n`);
    return;
  }

  const dbPath = stateDbPath();
  const dbDir = path.dirname(dbPath);
  try {
    // 0700: the audit DB holds sensitive-path / command metadata; keep its
    // directory owner-only. recursive mode only applies to created components.
    fs.mkdirSync(dbDir, { recursive: true, mode: 0o700 });
  } catch {
    // Directory creation failed — the open below will surface the error.
  }
  // Enforce owner-only on the audit dir every run (idempotent), so an existing
  // dir created with a looser umask is also tightened. An audit store has no
  // legitimate reason to be group/world-accessible.
  try {
    fs.chmodSync(dbDir, 0o700);
  } catch {
    // Best-effort hardening only.
  }

  let db;
  try {
    // FK off: see file header — appended rows may reference unmanaged sessions.
    db = new DatabaseSync(dbPath, { enableForeignKeyConstraints: false });
  } catch (err) {
    process.stderr.write(`[governance][persist-failed] open failed: ${err.message}\n`);
    return;
  }

  // Restrict the audit DB to the owner (0600), every run and idempotently. The
  // -wal/-shm sidecars only exist once WAL is active, so they are re-hardened
  // again after the writes below.
  hardenDbPerms(dbPath);

  try {
    // Match ECC's own connection (state-store/index.js uses WAL) and let
    // concurrent hook processes wait on the write lock instead of dropping
    // audit rows on SQLITE_BUSY. busy_timeout stays under the hook's 10s budget.
    try {
      db.exec('PRAGMA journal_mode = WAL');
    } catch {
      // WAL unsupported in this context — fall back to the default journal.
    }
    try {
      db.exec('PRAGMA busy_timeout = 5000');
    } catch {
      // Ignore — a missing busy_timeout only weakens concurrent-write resilience.
    }

    db.exec(
      'CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TEXT NOT NULL)'
    );
    const applied = new Set(db.prepare('SELECT version FROM schema_migrations').all().map(row => row.version));
    // INSERT OR IGNORE: a concurrent fork on a fresh DB may also be recording
    // the same migration version — let the loser skip rather than error.
    const recordMigration = db.prepare('INSERT OR IGNORE INTO schema_migrations (version, name, applied_at) VALUES (?, ?, ?)');

    // BEGIN IMMEDIATE acquires the write lock up front so two concurrent forks
    // serialise the whole migrate+insert unit instead of racing the lock mid-write.
    db.exec('BEGIN IMMEDIATE');
    try {
      for (const migration of Array.isArray(MIGRATIONS) ? MIGRATIONS : []) {
        if (applied.has(migration.version)) continue;
        db.exec(migration.sql);
        recordMigration.run(migration.version, migration.name, new Date().toISOString());
      }
      db.exec('COMMIT');
    } catch (err) {
      try {
        db.exec('ROLLBACK');
      } catch {
        // Ignore rollback failure.
      }
      throw err;
    }

    // DO NOTHING keeps the table append-only: governance events are an audit
    // trail, and ids are unique, so a (near-impossible) id collision must never
    // silently overwrite an existing row.
    const insert = db.prepare(
      'INSERT INTO governance_events (id, session_id, event_type, payload, resolved_at, resolution, created_at) ' +
        'VALUES (@id, @session_id, @event_type, @payload, @resolved_at, @resolution, @created_at) ' +
        'ON CONFLICT(id) DO NOTHING'
    );
    for (const event of events) {
      insert.run({
        '@id': event.id,
        '@session_id': event.sessionId ?? null,
        '@event_type': event.eventType,
        '@payload': JSON.stringify(event.payload ?? {}),
        '@resolved_at': event.resolvedAt ?? null,
        '@resolution': event.resolution ?? null,
        '@created_at': event.createdAt || new Date().toISOString(),
      });
    }

    // Re-harden now that WAL writes have materialised the -wal/-shm sidecars.
    hardenDbPerms(dbPath);
  } catch (err) {
    // Machine-readable marker so external monitoring can detect dropped audit
    // events even though the hook fails open and never blocks the tool.
    process.stderr.write(`[governance][persist-failed] ${err.message}\n`);
  } finally {
    try {
      db.close();
    } catch {
      // Ignore close failure.
    }
  }
}

/**
 * Core hook logic. Detects governance events (via ECC's analyzer), emits each to
 * stderr (preserving ECC behaviour), persists them to state.db, and returns the
 * untouched input for pass-through.
 */
function run(rawInput, options = {}) {
  if (String(process.env.ECC_GOVERNANCE_CAPTURE || '').toLowerCase() !== '1') {
    return rawInput;
  }

  const pluginRoot = resolvePluginRoot();

  let analyze = null;
  let generateEventId = null;
  if (pluginRoot) {
    try {
      const eccModule = require(path.join(pluginRoot, 'scripts', 'hooks', 'governance-capture.js'));
      analyze = eccModule.analyzeForGovernanceEvents;
      generateEventId = eccModule.generateEventId;
    } catch {
      analyze = null;
    }
  }

  let input = null;
  try {
    input = JSON.parse(rawInput);
  } catch {
    input = null;
  }

  // session_id arrives in the stdin payload (a common hook input field); the
  // cld/cld-r06 aliases do NOT export ECC_SESSION_ID, so reading it from the
  // payload is what actually correlates events to a session.
  const sessionId = (input && input.session_id) || process.env.ECC_SESSION_ID || null;

  const eventName = (input && input.hook_event_name) || process.env.CLAUDE_HOOK_EVENT_NAME || '';
  const hookPhase = String(eventName).startsWith('Pre') ? 'pre' : 'post';

  // ECC's analyzer inspects `tool_output` for output-side secrets, but Claude
  // Code delivers tool output under `tool_response` (PostToolUse/PostToolUseFailure).
  // Normalise so the post-side detection actually runs.
  if (input && input.tool_output == null && input.tool_response != null) {
    input.tool_output =
      typeof input.tool_response === 'string' ? input.tool_response : JSON.stringify(input.tool_response);
  }

  // Note: when stdin exceeded MAX_STDIN the payload is truncated, JSON.parse
  // above fails, and only the hook_input_truncated event below is recorded —
  // detection is intentionally skipped rather than run on a corrupt payload.
  const events = [];

  if (options.truncated) {
    events.push({
      id: typeof generateEventId === 'function' ? generateEventId() : `gov-${Date.now()}-truncated`,
      sessionId,
      eventType: 'hook_input_truncated',
      payload: {
        hookPhase,
        sizeLimitBytes: options.maxStdin || MAX_STDIN,
        severity: 'warning',
      },
      resolvedAt: null,
      resolution: null,
    });
  }

  if (typeof analyze === 'function' && input) {
    try {
      events.push(...analyze(input, { sessionId, hookPhase }));
    } catch {
      // Detection failure must never block the tool pipeline.
    }
  }

  for (const event of events) {
    emitGovernanceEvent(event);
  }

  try {
    persistEvents(events, pluginRoot);
  } catch (err) {
    process.stderr.write(`[governance][persist-failed] ${err.message}\n`);
  }

  return rawInput;
}

// Write stdout and exit only once the buffer is fully flushed. A bare
// process.exit() after a write truncates output larger than the OS pipe buffer
// (~64 KB) — fatal for PostToolUse pass-through of large tool_response payloads.
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
  let raw = '';
  let truncated = /^(1|true|yes)$/i.test(String(process.env.ECC_HOOK_INPUT_TRUNCATED || ''));
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => {
    if (raw.length < MAX_STDIN) {
      const remaining = MAX_STDIN - raw.length;
      raw += chunk.substring(0, remaining);
      if (chunk.length > remaining) {
        truncated = true;
      }
    } else {
      truncated = true;
    }
  });
  process.stdin.on('error', () => {
    writeAndExit(raw);
  });
  process.stdin.on('end', () => {
    let output = raw;
    try {
      output = run(raw, {
        truncated,
        maxStdin: Number(process.env.ECC_HOOK_INPUT_MAX_BYTES) || MAX_STDIN,
      });
    } catch {
      output = raw;
    }
    writeAndExit(output);
  });
}

module.exports = {
  resolvePluginRoot,
  stateDbPath,
  persistEvents,
  run,
};
