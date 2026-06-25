#!/usr/bin/env node
'use strict';

// ecc-* CLI reader (Phase 7 PR-C, #4/#5).
//
// Renders ecc-status / ecc-sessions / ecc-work-items from the per-account ECC state.db that
// the governance-capture fork (PR4, hooks-fork/governance-capture.js) writes via node:sqlite.
//
// Why a fork instead of ECC's own CLI: ECC's query layer
// (scripts/lib/state-store/queries.js) loads ./schema, which pulls in `ajv` — absent here
// because the chezmoi external fetches only ECC's hook/lib *source*, not node_modules, and we
// deliberately do not provision sql.js/ajv (the adopted skills need neither). So the SELECTs
// are reimplemented on the built-in node:sqlite, mirroring governance-capture.js's rationale.
//
// Read-only. Account isolation comes from ECC_AGENT_DATA_HOME (exported by the cld / cld-r06
// wrappers): cld reads ~/.claude/ecc/state.db, cld-r06 reads ~/.claude-r06/ecc/state.db.

const fs = require('fs');
const os = require('os');
const path = require('path');

// Mirror governance-capture.js stateDbPath() exactly, so the reader sees what the writer wrote.
function stateDbPath() {
  const base = process.env.ECC_AGENT_DATA_HOME || path.join(os.homedir(), '.claude');
  return path.join(base, 'ecc', 'state.db');
}

function parseArgs(argv) {
  const out = { sub: null, db: null, json: false };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') out.json = true;
    else if (a === '--db') out.db = argv[++i];
    else rest.push(a);
  }
  out.sub = rest[0] || 'status';
  return out;
}

// Returns { db } on success, or { note } for the graceful "nothing to show" cases.
function openDb(dbPath) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = require('node:sqlite'));
  } catch {
    return { note: 'node:sqlite unavailable (needs Node >= 22.5); cannot read state.db.' };
  }
  // readOnly throws if the file is missing, so check first and report gracefully.
  if (!fs.existsSync(dbPath)) {
    return { note: `No state.db at ${dbPath} — this account has not captured any events yet.` };
  }
  try {
    const db = new DatabaseSync(dbPath, { readOnly: true, enableForeignKeyConstraints: false });
    return { db };
  } catch (e) {
    return { note: `Cannot open ${dbPath}: ${e.message}` };
  }
}

function tableExists(db, name) {
  return !!db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(name);
}

function buildStatus(db) {
  const hasGov = tableExists(db, 'governance_events');
  const pending = hasGov
    ? db.prepare('SELECT count(*) c FROM governance_events WHERE resolved_at IS NULL').get().c
    : 0;
  const byType = hasGov
    ? db.prepare(
        "SELECT event_type, count(*) c FROM governance_events WHERE resolved_at IS NULL GROUP BY event_type ORDER BY c DESC"
      ).all()
    : [];
  const recent = hasGov
    ? db.prepare(
        "SELECT event_type, created_at FROM governance_events WHERE resolved_at IS NULL ORDER BY created_at DESC LIMIT 5"
      ).all()
    : [];
  const activeSessions = tableExists(db, 'sessions')
    ? db.prepare("SELECT count(*) c FROM sessions WHERE ended_at IS NULL AND state IN ('active','running','idle')").get().c
    : 0;
  // Mirror ECC's CLOSED_WORK_ITEM_STATUSES (queries.js) exactly so the count matches ECC's
  // own dashboard — resolved/merged are closed there, not open.
  const openWorkItems = tableExists(db, 'work_items')
    ? db.prepare("SELECT count(*) c FROM work_items WHERE status NOT IN ('done','closed','resolved','merged','cancelled')").get().c
    : 0;
  return {
    pendingGovernanceEvents: pending,
    governanceByType: byType,
    recentGovernance: recent,
    activeSessions,
    openWorkItems,
  };
}

function listSessions(db, limit = 20) {
  if (!tableExists(db, 'sessions')) return [];
  return db
    .prepare('SELECT id, harness, state, repo_root, started_at, ended_at FROM sessions ORDER BY started_at DESC LIMIT ?')
    .all(limit);
}

function listWorkItems(db, limit = 50) {
  if (!tableExists(db, 'work_items')) return [];
  return db
    .prepare('SELECT id, source, title, status, priority, url, updated_at FROM work_items ORDER BY updated_at DESC LIMIT ?')
    .all(limit);
}

function renderStatus(s) {
  const lines = [];
  lines.push(`Pending governance events: ${s.pendingGovernanceEvents}`);
  for (const r of s.governanceByType) lines.push(`  ${r.event_type}: ${r.c}`);
  if (s.recentGovernance.length) {
    lines.push('Most recent pending:');
    for (const r of s.recentGovernance) lines.push(`  ${r.created_at}  ${r.event_type}`);
  }
  lines.push(`Active sessions: ${s.activeSessions}`);
  lines.push(`Open work items: ${s.openWorkItems}`);
  return lines.join('\n');
}

function renderSessions(rows) {
  if (!rows.length) return 'No sessions recorded.';
  return rows
    .map((r) => `${r.started_at || '?'}  ${r.state || '?'}  ${r.harness || '?'}  ${r.repo_root || ''}`)
    .join('\n');
}

function renderWorkItems(rows) {
  if (!rows.length) return 'No work items.';
  return rows
    .map((r) => `[${r.status || '?'}] ${r.title || '(untitled)'}  ${r.source || ''}  ${r.url || ''}`)
    .join('\n');
}

const SUBCOMMANDS = new Set(['status', 'sessions', 'work-items', 'work_items']);

function main() {
  const args = parseArgs(process.argv.slice(2));
  // Validate the subcommand BEFORE touching the db, so an unknown subcommand always reports
  // exit 2 — even on a fresh account where openDb() would otherwise short-circuit to a note.
  if (!SUBCOMMANDS.has(args.sub)) {
    process.stderr.write(`Unknown subcommand: ${args.sub} (use status|sessions|work-items)\n`);
    return 2;
  }
  const dbPath = args.db || stateDbPath();

  const opened = openDb(dbPath);
  if (opened.note) {
    // Graceful: no data is a normal state, not an error.
    process.stdout.write((args.json ? JSON.stringify({ note: opened.note }) : opened.note) + '\n');
    return 0;
  }
  const db = opened.db;
  try {
    let payload;
    let text;
    switch (args.sub) {
      case 'status':
        payload = buildStatus(db);
        text = renderStatus(payload);
        break;
      case 'sessions':
        payload = { sessions: listSessions(db) };
        text = renderSessions(payload.sessions);
        break;
      case 'work-items':
      case 'work_items':
        payload = { workItems: listWorkItems(db) };
        text = renderWorkItems(payload.workItems);
        break;
    }
    process.stdout.write((args.json ? JSON.stringify(payload) : text) + '\n');
    return 0;
  } finally {
    db.close();
  }
}

// Set exitCode rather than process.exit() so a large buffered stdout write drains fully
// before the process ends (process.exit() can truncate it).
process.exitCode = main();
