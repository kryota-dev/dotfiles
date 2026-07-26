#!/usr/bin/env node
'use strict';

/**
 * Prompt Conform Suggest — UserPromptSubmit hook (task #367).
 *
 * Why this exists: `$prompt-conform` optimizes an arbitrary prompt, but nothing
 * offers it automatically. UserPromptSubmit hooks cannot implement an interactive
 * gate themselves — they can only inject `additionalContext` or hard-block the
 * prompt — so this hook mirrors `model-fitness-check`'s design: detect an
 * optimization-worthy prompt, inject a suggestion into context, and let Claude
 * decide whether to offer `$prompt-conform` (e.g. via AskUserQuestion). Firing on
 * every prompt was rejected as noisy, hence the two-stage heuristic below.
 *
 * Detection is intentionally conservative (length AND shape/keyword, not OR):
 * a bare length threshold would also catch long non-task pastes (logs, diffs
 * quoted for reference), and a bare keyword match would fire on short one-liners
 * that don't benefit from optimization. Both signals are required.
 *
 * Tunable via env (mirrors the GATEGUARD_BASH_EXTRA_DESTRUCTIVE pattern in
 * home/dot_config/gateguard/executable_codex-bash-gate.js): an invalid override
 * falls back to the built-in default rather than crashing the hook.
 *
 *   PROMPT_CONFORM_SUGGEST_MIN_LENGTH  — integer, default 200
 *   PROMPT_CONFORM_SUGGEST_TASK_REGEX  — RegExp source, default: imperative task verbs (JP/EN)
 *   PROMPT_CONFORM_SUGGEST_KEYWORD_REGEX — RegExp source, default: skill/prompt-authoring terms
 *
 * Unlike home/dot_claude/hooks-fork/governance-capture.js this hook has no
 * persistence layer and does not require() the ECC external runtime — it is a
 * standalone, stateless script (prompt text is never written to disk or a DB).
 *
 * Fail-open: every failure path (malformed stdin JSON, invalid env regex,
 * unexpected exception) degrades to emitting nothing on stdout and exiting 0,
 * so a bug here can never block a prompt submission.
 */

const MAX_STDIN = 1024 * 1024;

const DEFAULT_MIN_LENGTH = 150;

// Japanese imperative task-request shapes ("実装して[ください]" etc.) plus a
// standalone politeness marker, and common English imperative task verbs.
const DEFAULT_TASK_REGEX_SOURCE =
  '(?:(?:実装|作成|修正|追加|削除|リファクタ(?:リング)?|設計|書き直|直)して(?:ください)?' +
  '|お願いします' +
  '|\\b(?:implement|create|refactor|fix|design|build|write)\\b)';

// Skill / prompt-authoring vocabulary — the domain prompt-conform itself targets.
const DEFAULT_KEYWORD_REGEX_SOURCE =
  '(?:skill|SKILL\\.md|slash\\s*command|prompt-conform' +
  '|システムプロンプト|プロンプト(?:設計|作成|最適化|エンジニアリング)|指示文|エージェント定義|CLAUDE\\.md)';

function warnOnce(message) {
  process.stderr.write(`[prompt-conform-suggest] ${message}\n`);
}

/**
 * Read `PROMPT_CONFORM_SUGGEST_MIN_LENGTH` / `_TASK_REGEX` / `_KEYWORD_REGEX`
 * from env. Any missing or invalid value falls back to the built-in default
 * (fail-open) rather than throwing.
 *
 * @param {NodeJS.ProcessEnv} env
 * @returns {{ minLength: number, taskRegex: RegExp, keywordRegex: RegExp }}
 */
function resolveConfig(env) {
  let minLength = DEFAULT_MIN_LENGTH;
  const rawMinLength = env.PROMPT_CONFORM_SUGGEST_MIN_LENGTH;
  if (rawMinLength) {
    const parsed = Number(rawMinLength);
    if (Number.isFinite(parsed) && parsed >= 0) {
      minLength = parsed;
    } else {
      warnOnce(`ignoring invalid PROMPT_CONFORM_SUGGEST_MIN_LENGTH: ${rawMinLength}`);
    }
  }

  return {
    minLength,
    taskRegex: buildRegex(env.PROMPT_CONFORM_SUGGEST_TASK_REGEX, DEFAULT_TASK_REGEX_SOURCE, 'PROMPT_CONFORM_SUGGEST_TASK_REGEX'),
    keywordRegex: buildRegex(
      env.PROMPT_CONFORM_SUGGEST_KEYWORD_REGEX,
      DEFAULT_KEYWORD_REGEX_SOURCE,
      'PROMPT_CONFORM_SUGGEST_KEYWORD_REGEX'
    ),
  };
}

function buildRegex(fromEnv, defaultSource, envVarName) {
  if (fromEnv) {
    try {
      return new RegExp(fromEnv, 'i');
    } catch (err) {
      warnOnce(`ignoring invalid ${envVarName} regex: ${err.message}`);
    }
  }
  return new RegExp(defaultSource, 'i');
}

/**
 * @param {unknown} promptText
 * @param {{ minLength: number, taskRegex: RegExp, keywordRegex: RegExp }} config
 * @returns {boolean}
 */
function isOptimizationWorthy(promptText, config) {
  if (typeof promptText !== 'string') {
    return false;
  }
  if (promptText.length < config.minLength) {
    return false;
  }
  return config.taskRegex.test(promptText) || config.keywordRegex.test(promptText);
}

const SUGGESTION_MESSAGE =
  'このプロンプトは分量が多くタスク性が強いため、実行前に $prompt-conform でのプロンプト最適化をユーザーに提案することを検討してください。' +
  '有用と判断した場合は AskUserQuestion 等でユーザーに実行可否を確認し、ユーザーが明示的に希望した場合のみ実行してください。' +
  'ユーザーが急いでいる、または最適化が不要と判断できる場合は提案を省略して構いません。';

/**
 * @param {string} rawInput
 * @returns {string} stdout content (empty string = silent pass-through)
 */
function run(rawInput) {
  let input = null;
  try {
    input = JSON.parse(rawInput);
  } catch {
    return '';
  }

  const config = resolveConfig(process.env);
  const prompt = input && input.prompt;

  if (!isOptimizationWorthy(prompt, config)) {
    return '';
  }

  return JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'UserPromptSubmit',
      additionalContext: SUGGESTION_MESSAGE,
    },
  });
}

// Write stdout and exit only once the buffer is fully flushed — see the same
// rationale in home/dot_claude/hooks-fork/governance-capture.js (a bare
// process.exit() after a write can truncate output larger than the OS pipe
// buffer). Output here is always small, but the safe pattern costs nothing.
function writeAndExit(output) {
  process.exitCode = 0;
  if (!output) {
    process.exit(0);
    return;
  }
  try {
    process.stdout.write(output, () => process.exit(0));
  } catch {
    process.exit(0);
  }
}

if (require.main === module) {
  let raw = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => {
    if (raw.length < MAX_STDIN) {
      raw += chunk.substring(0, MAX_STDIN - raw.length);
    }
  });
  process.stdin.on('error', () => {
    writeAndExit('');
  });
  process.stdin.on('end', () => {
    let output = '';
    try {
      output = run(raw);
    } catch (err) {
      warnOnce(`unexpected error: ${err.message}`);
      output = '';
    }
    writeAndExit(output);
  });
}

module.exports = { resolveConfig, isOptimizationWorthy, run };
