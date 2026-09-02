import { readFileSync } from "node:fs";

import { classifyDomainLiteral } from "./address-classifier.mjs";
import { analyzeShellCommand } from "./approval-command.mjs";
import { sha256Hex } from "./hash.mjs";
import { requireObject } from "./record-validation.mjs";

// 承認済み repository capability manifest の検証・突合・照合。
//
// これまで manifest は `fh onboard` が書き出すだけで、読む実装がどこにも無かった。
// このファイルがその読み手であり、承認を「記録」から「実行を止めるゲート」へ変える。
//
// 改竄検知の要は、**承認の記録先を manifest の保管先と分けている**こと。
// `.harness/policy.json` は repository 側にあり、`git pull` / 悪意ある PR / checkout の
// 差し替えで変わりうる。一方 approvals 台帳は state root（`git rev-parse --git-common-dir`
// 配下・0700・git 非追跡）にあり、checkout に付いてこない。照合時に policy.json の manifest を
// 再ハッシュして台帳と突き合わせるため、policy.json だけを書き換えた改竄は通らない
// —— hash を一緒に書き換えても、台帳側に対応する行が無いから。
//
// **残余リスク**: 同一 uid で動くコードは台帳ファイルごと書き換えられるため、これは
// 同一 uid の攻撃者に対する境界ではない。`approvals.granted_by` について docs が述べている
// のと同じ但し書きが、そのままここにも当てはまる。

export const POLICY_VERSION = 1;
export const REPOSITORY_MANIFEST_APPROVAL_KIND = "repository_manifest";

export const MANIFEST_KEYS = new Set(["commands", "domains", "capabilities"]);
const POLICY_KEYS = new Set([
  "version",
  "approvedAt",
  "approvalHash",
  "approvalId",
  "manifest",
]);

// 承認できるコマンドの形。実行を許すのはプロジェクトのタスクランナーに限る。
// これは「何を承認しうるか」の上限であって、照合そのものではない（照合は下の
// `matchCommand` がトークン化した完全一致で行う）。
//
// **引数の字集合はランナーごとに分ける。** 下の 2 本は「承認できる形」という同じ役目を持つが、
// 通してよい引数の範囲が違う。1 本の alternation へ畳むと、片方のために広げた字集合が
// もう片方にも効いてしまう。
const APPROVABLE_RUNNER_COMMAND =
  /^(?:npm run|pnpm run|yarn run|bun run|uv run|pytest|go test|cargo test)(?: [A-Za-z0-9_./:@=-]+)+$/;

// `make` の引数は**ターゲット名だけ**に絞る。上の字集合を流用してはならない。
//
// `make` の承認が意味するのは「このリポジトリの Makefile に定義された recipe を走らせてよい」で
// あって、任意の makefile ではない。ところが上の字集合は `-` と `=` を含むので、そのまま流用すると
// `make -f /tmp/evil.mk all` / `make --file=/tmp/evil.mk all` / `make -C /tmp/evil all` が承認できる形に
// 入り、**リポジトリ外の makefile を読ませられる** —— 承認の意味そのものが外れる。
// `make SHELL=/tmp/evil test` のような command-line variable override も同じで、recipe の展開先を
// 変えるため、承認した文字列から実行内容が読めなくなる。`npm run <script>` にはこれに対応する引数が
// 無い（引数は `package.json` の scripts へ渡るだけ）ので、ここだけを非対称に狭くする。
//
// 「Makefile の内容次第で任意のコマンドが走る」という懸念のほうは `make` 固有ではない。
// `npm run test` が実行するのもその時点の `package.json` が書いてある内容で、docs の
// 「What "approved" actually authorizes」が既にその前提を述べている。狭めるのは、そこに書かれた
// 前提から**外れる**引数だけでよい。
//
// 先頭 1 文字を `[A-Za-z0-9_]` に固定すると、`-` 始まり（フラグ）と `.` 始まり（`../` のような相対
// パス）が同時に閉じる。`:` を落とすのは `session-gate.mjs` の `parseGateDeclaration` が
// `<kind>:<command>` を最初の `:` で割るためでもある（`make` は check kind の閉じた語彙に無いので
// 衝突は起きないが、字集合としても重ならないほうが安全側に倒れる）。
//
// 引数を必須にする（`+`）のは既存ランナーと同じ規律。`make` 単体は既定ターゲットを走らせるので、
// 何が起きるかが承認文字列から読めなくなる。
const APPROVABLE_MAKE_COMMAND = /^make(?: [A-Za-z0-9_][A-Za-z0-9_./-]*)+$/;

const CAPABILITY_NAME = /^[a-z][a-z0-9._-]*$/;

function isApprovableCommand(command) {
  return APPROVABLE_RUNNER_COMMAND.test(command) || APPROVABLE_MAKE_COMMAND.test(command);
}

// 承認できる形でなかったときの理由。
//
// 単一の理由文（「タスクランナーに引数を付けた形だけが承認できる」）だと、`make -f x.mk all` を
// 弾いたときに「`make` はそもそも対象外」と読める。#617 の診断が手間取ったのはまさにこの不透明さ
// だったので、`make` で始まる入力には「どう書けば承認できるか」が分かる文を返す。
function approvableRejectionReason(command) {
  if (/^make(?:\s|$)/.test(command)) {
    return "make can only be approved as `make <target>`; options and variable overrides are not approvable";
  }
  return "only a project task runner command with arguments can be approved";
}

export const EMPTY_MANIFEST = Object.freeze({
  commands: Object.freeze([]),
  domains: Object.freeze([]),
  capabilities: Object.freeze([]),
});

// manifest に載せられない値を、載せる前に 1 件ずつ判定する。
// `--from-gaps` の一括承認が「1 件でも不正なら全部落ちる」形にならないようにするため、
// 検証を項目単位で呼べる形にしてある。
export function manifestEntryRejection(kind, value) {
  if (typeof value !== "string" || value.length === 0) {
    return "entries must be non-empty strings";
  }
  if (kind === "commands") {
    if (!isApprovableCommand(value)) {
      return approvableRejectionReason(value);
    }
    if (commandSegments(value) === null) {
      return "the command cannot be interpreted statically";
    }
    return null;
  }
  if (kind === "domains") return classifyDomainLiteral(value);
  if (kind === "capabilities") {
    return CAPABILITY_NAME.test(value) ? null : "capability names must be lowercase tokens";
  }
  return `unsupported manifest key: ${kind}`;
}

export function normalizeManifest(input) {
  requireObject(input, "manifest");
  const unknownKey = Object.keys(input).find((key) => !MANIFEST_KEYS.has(key));
  if (unknownKey) {
    throw new TypeError(`manifest contains unsupported key: ${unknownKey}`);
  }
  for (const key of MANIFEST_KEYS) {
    if (!Array.isArray(input[key])) {
      throw new TypeError(`manifest.${key} must be an array`);
    }
    for (const value of input[key]) {
      const rejection = manifestEntryRejection(key, value);
      if (rejection) throw new TypeError(`manifest.${key} rejects ${rejection}`);
    }
  }
  return {
    commands: [...input.commands],
    domains: [...input.domains],
    capabilities: [...input.capabilities],
  };
}

export function manifestHash(manifest) {
  return sha256Hex(manifest);
}

// ---------------------------------------------------------------------------
// command の照合
// ---------------------------------------------------------------------------

// `analyzeShellCommand` は生文字列に続けて「binary + 正規化した語」のセグメントを返す。
// `;` `&&` `|` で連結されたコマンドはセグメントに割れるため、連結された 2 本目以降も
// 照合対象になる（`npm run test; curl …` の `curl …` が承認済みに無ければ不一致）。
// 静的に解釈できない場合（動的構築・ネストシェル）は null を返し、呼び出し側が拒否へ倒す。
export function commandSegments(command) {
  const { candidates, ambiguous } = analyzeShellCommand(command);
  if (ambiguous) return null;
  const segments = candidates.slice(1);
  return segments.length > 0 ? segments : null;
}

export function approvedCommandSegments(commands) {
  const approved = new Set();
  for (const command of commands) {
    const segments = commandSegments(command);
    // 承認側が解釈不能なものは照合の材料にしない（解釈できない承認で実行を通さない）。
    if (segments === null) continue;
    for (const segment of segments) approved.add(segment);
  }
  return approved;
}

// 空白の揺れだけを畳む。承認できる形かどうかを見るための正規化なので、引用符や
// 制御構文はそのまま残す（残っていれば下の文法検査が弾く）。
//
// **照合と実行で同じ正規化を使う。** export しているのは `check-runner.mjs` が実行直前の
// 再検査でこれを共有するためで、片方だけが畳むと「承認は通るのに実行が落ちる」コマンドが
// できる（`npm  run   test` のような空白の揺れがまさにそれだった）。
export function collapseWhitespace(command) {
  return command.trim().replace(/\s+/g, " ");
}

export function matchCommand(command, approvedSegments) {
  const segments = commandSegments(command);
  if (segments === null) {
    return { allowed: false, reason: "the command cannot be interpreted statically" };
  }
  // 照合側にも「承認できる形か」の文法検査をかける。
  //
  // `analyzeShellCommand` は binary を basename へ畳む。同ファイルが明記するとおり
  // 「候補を増やす方向にしか働かない」正規化で、escalation（deny リスト）では安全側だが、
  // **allowlist では方向が逆**になる —— `/tmp/evil/npm run test` が承認済みの
  // `npm run test` と同じセグメントへ畳まれ、未承認の絶対パスのバイナリが一致してしまう。
  // セグメントは basename 化された後なのでこの差を復元できないため、生のコマンド文字列に
  // 対して承認可能な形（プロジェクトのタスクランナーで始まり、引数が安全な字集合）を要求する。
  const rejection = manifestEntryRejection("commands", collapseWhitespace(command));
  if (rejection) {
    return { allowed: false, reason: `the command is not in an approvable form: ${rejection}` };
  }
  const unapproved = segments.filter((segment) => !approvedSegments.has(segment));
  if (unapproved.length > 0) {
    return {
      allowed: false,
      reason: `no approved command matches ${unapproved.join(" | ")}`,
    };
  }
  return { allowed: true, reason: null };
}

// ---------------------------------------------------------------------------
// policy の読み出しと台帳突合
// ---------------------------------------------------------------------------

export function readPolicyFile(policyPath) {
  try {
    return JSON.parse(readFileSync(policyPath, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

export function normalizePolicy(input) {
  requireObject(input, "repository policy");
  const unknownKey = Object.keys(input).find((key) => !POLICY_KEYS.has(key));
  if (unknownKey) {
    throw new TypeError(`repository policy contains unsupported key: ${unknownKey}`);
  }
  if (input.version !== POLICY_VERSION) {
    throw new TypeError(`repository policy version must be ${POLICY_VERSION}`);
  }
  return { ...input, manifest: normalizeManifest(input.manifest) };
}

// policy.json を読み、approvals 台帳に裏付けがあるものだけを manifest として返す。
//
// 裏付けが取れない場合でも throw せず、空 manifest と理由を返す。呼び出し側（`fh run`）は
// これを route: escalation として**記録**したいので、例外にすると gap も route も残らず、
// 「なぜ止まったか」の監査証跡が消える。実行が止まる点は変わらない（空 manifest = 全部未承認）。
export function loadVerifiedManifest({
  policyPath,
  approvals,
  scope,
  currentApproval = null,
}) {
  let policy;
  try {
    policy = readPolicyFile(policyPath);
  } catch (error) {
    return {
      manifest: EMPTY_MANIFEST,
      integrity: { ok: false, reason: `repository policy is unreadable: ${error.message}` },
    };
  }
  if (policy === null) {
    return {
      manifest: EMPTY_MANIFEST,
      integrity: {
        ok: true,
        reason: "no repository capability manifest is approved for this repository",
      },
    };
  }

  let manifest;
  try {
    manifest = normalizePolicy(policy).manifest;
  } catch (error) {
    return {
      manifest: EMPTY_MANIFEST,
      integrity: { ok: false, reason: `repository policy is invalid: ${error.message}` },
    };
  }

  const hash = manifestHash(manifest);

  // 有効な認可状態はポインタが持つ。台帳のどの行かに一致すれば良い形にすると、
  // 過去に承認した内容へ policy を差し戻すだけで承認が復活する（approved-manifest.mjs 参照）。
  if (!currentApproval) {
    return {
      manifest: EMPTY_MANIFEST,
      integrity: {
        ok: false,
        reason:
          "no approval is currently in force for this repository policy; run the onboarding ceremony",
      },
    };
  }
  if (currentApproval.manifestHash !== hash) {
    return {
      manifest: EMPTY_MANIFEST,
      integrity: {
        ok: false,
        reason:
          "repository policy does not match the approval currently in force; it may have been modified, copied, or reverted to a previously approved version",
      },
    };
  }

  // 台帳側にも裏付けを要求する。ポインタだけを信頼すると、監査証跡を消しても認可が残る。
  const matched = (approvals ?? []).some(
    (approval) =>
      approval.kind === REPOSITORY_MANIFEST_APPROVAL_KIND &&
      approval.id === currentApproval.approvalId &&
      approval.subjectHash === hash &&
      approval.scope === scope,
  );
  if (!matched) {
    return {
      manifest: EMPTY_MANIFEST,
      integrity: {
        ok: false,
        reason:
          "the approval in force has no matching row in the approvals ledger for this repository",
      },
    };
  }
  return { manifest, integrity: { ok: true, reason: null } };
}

// ---------------------------------------------------------------------------
// 照合
// ---------------------------------------------------------------------------

// 承認済み manifest に対して task の要求を突き合わせ、未承認のものを列挙する。
// 空配列なら実行してよい。1 件でもあれば呼び出し側が実行を止めて queue に積む。
// capability は配列で受ける。`chooseRoute` は writer-plus-reviewer route のとき主 capability に
// 加えて `reviewerCapability` を返し、そちらも実際に provider を選ぶ軸になる。単数で受けると
// reviewer 側が承認照合をすり抜ける（#556 レビュー指摘）。
export function findManifestGaps({ manifest, commands = [], domains = [], capabilities = [] }) {
  const gaps = [];
  const approvedSegments = approvedCommandSegments(manifest.commands);
  for (const command of commands) {
    const match = matchCommand(command, approvedSegments);
    if (!match.allowed) {
      gaps.push({ kind: "command", value: command, reason: match.reason });
    }
  }
  const approvedDomains = new Set(manifest.domains);
  for (const domain of domains) {
    if (!approvedDomains.has(domain)) {
      gaps.push({
        kind: "domain",
        value: domain,
        reason: "the domain is not in the approved manifest",
      });
    }
  }
  // 同じ capability が主・reviewer 双方に現れても gap は 1 件に畳む。
  for (const capability of new Set(capabilities.filter(Boolean))) {
    if (!manifest.capabilities.includes(capability)) {
      gaps.push({
        kind: "capability",
        value: capability,
        reason: "the routed capability is not in the approved manifest",
      });
    }
  }
  return gaps;
}

// ---------------------------------------------------------------------------
// gap からの候補 manifest 組み立て
// ---------------------------------------------------------------------------

export const GAP_KIND_TO_MANIFEST_KEY = Object.freeze({
  command: "commands",
  domain: "domains",
  capability: "capabilities",
});

// `fh onboard --from-gaps` の候補 manifest。承認済み manifest に、queue に溜まった gap のうち
// manifest へ載せられるものを足す。載せられないもの（`curl …` のように承認対象外の形、
// 内部アドレスを指す domain など）は落として理由と一緒に報告する。1 件の不正で一括承認全体が
// 止まると、wave 境界でまとめて承認するという目的が果たせない。落とした側は未承認のまま残る
// ので、fail-closed は維持される。
export function candidateFromGaps(approvedManifest, gaps) {
  const candidate = {
    commands: [...approvedManifest.commands],
    domains: [...approvedManifest.domains],
    capabilities: [...approvedManifest.capabilities],
  };
  const included = [];
  const rejected = [];
  for (const gap of gaps) {
    const key = GAP_KIND_TO_MANIFEST_KEY[gap.kind];
    const rejection = manifestEntryRejection(key, gap.value);
    if (rejection) {
      rejected.push({ kind: gap.kind, value: gap.value, reason: rejection });
      continue;
    }
    if (!candidate[key].includes(gap.value)) candidate[key].push(gap.value);
    included.push(gap);
  }
  return { candidate, included, rejected };
}
