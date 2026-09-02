import { resolveCheckTimeoutMs, runDeterministicCheck } from "./check-runner.mjs";
import { collapseWhitespace } from "./manifest-policy.mjs";
import { VERIFICATION_CHECK_KINDS } from "./record-validation.mjs";
import { DEFAULT_CHECK_KIND } from "./verification-registry.mjs";

// セッションの完了条件（completion gate）—— 「ターンがエラーなく終わったか」と
// 「指示した gate を通ったか」を分けるための連結（#573）。
//
// 分離そのものは設計意図だった（PRD 493 AC-005 / PRD 537 AC-012）。部品も揃っていて、
// `verification_results` には `adapter_run_id` 列が最初からある。欠けていたのはその列を
// 書く実装だけで、そのため `fh session` の結果から検証へ辿る線がどこにも無かった。
//
// 実測された事象: wave 4 本のうち 3 本が「CI の完了通知が来次第レビューへ進みます」と述べて
// turn を終え、PR は立ったがレビューは 0 件で終わった。3 本とも記録は succeeded / exitCode 0 で、
// 完走した子と外形が完全に一致していた。判別できたのは PR のコメント数という外形からだけである。
//
// **判定に使うのは終了コードだけである。** gate は `check-runner.mjs` をそのまま使うので、
// 子の stdout / stderr は端末へ継承され harness は 1 バイトも受け取らない。「記録に自由文が
// 入らない」は規約ではなく、持っていないので載せられないという性質のまま保たれる。

// gate の宣言は `<kind>:<command>` か、kind を省いた `<command>`。
//
// 曖昧にならないのは、承認できるコマンドが必ずタスクランナー名で始まる（`npm run` 等)ためで、
// 最初の `:` の手前が check kind の閉じた語彙に一致することは「kind を書いた」以外にありえない。
// `npm run test -- --grep=a:b` のような値も、手前が `npm run test -- --grep=a` になるので
// kind とは読まれない。
export function parseGateDeclaration(value) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new TypeError("--gate requires an approved command");
  }
  const separator = value.indexOf(":");
  const prefix = separator === -1 ? null : value.slice(0, separator);
  const declaredKind = prefix !== null && VERIFICATION_CHECK_KINDS.has(prefix) ? prefix : null;
  const rawCommand = declaredKind === null ? value : value.slice(separator + 1);
  // 承認ゲートと同じ正規化を通す。`matchCommand` は空白を畳んでから文法を見るので、
  // ここで畳まないと「承認は通ったのに実行できない」宣言ができてしまう。
  const command = collapseWhitespace(rawCommand);
  if (command.length === 0) {
    throw new TypeError(`--gate ${value} declares a check kind but no command`);
  }
  return Object.freeze({ kind: declaredKind ?? DEFAULT_CHECK_KIND, command });
}

// `--gate-timeout-ms` の解決。`fh session --timeout-ms` は承認チャネルの待機時間なので、
// gate は別のフラグを持つ（同じ名前で 2 つの意味を担わせない）。クランプ自体は
// `check-runner.mjs` が持つ（`fh verify` と同じ上限であることを構造で保つ）。
export function gateTimeoutMs(requested) {
  return resolveCheckTimeoutMs(requested);
}

// 1 セッションが宣言できる gate の本数。
//
// **本数にも上限が要る。** 個々のチェックには制限時間があるが、gate は直列に走るので、
// 承認済みコマンドを繰り返し宣言すれば「本数 × 上限」の時間だけ harness を占有できてしまう。
// `check-runner.mjs` が制限時間を置いた理由（チェックが終わらないまま harness を占有しない）は
// 本数についても同じように効かなければならない。実運用の完了条件は test / lint / typecheck の
// 数本で足りるので、余裕を見た小さな値に留める。
export const MAX_SESSION_GATES = 8;

export function assertGateCount(gates) {
  if (gates.length > MAX_SESSION_GATES) {
    throw new TypeError(
      `--gate may be declared at most ${MAX_SESSION_GATES} times, not ${gates.length}`,
    );
  }
  return gates;
}

// 宣言された gate を順に走らせる。
//
// **直列に走らせる。** 同じ作業ツリーで `npm run test` と `npm run lint` を同時に起こすと、
// ビルド生成物や lock ファイルを取り合って、どちらの終了コードもツリーの内容を説明しなくなる。
// gate は「この結果はこのツリーについての判定である」と言えることに価値があるので、
// 速度より逐次性を採る。
export async function runSessionGates({
  gates,
  cwd,
  environment,
  spawn,
  timeoutMs,
  terminationGraceMs,
}) {
  const results = [];
  for (const gate of gates) {
    const outcome = await runDeterministicCheck({
      command: gate.command,
      cwd,
      environment,
      spawn,
      timeoutMs,
      ...(terminationGraceMs === undefined ? {} : { terminationGraceMs }),
    });
    results.push(Object.freeze({ ...gate, ...outcome }));
  }
  return results;
}

// gate 全体の判定。
//
// **`failed` が `errored` に優先する。** 1 本でも赤が確定していれば、他が起動できなかった
// ことは判定を弱めない —— 呼び出し側が次に取る行動（直す）は確定した赤で決まる。逆向きに
// 畳むと、確定した失敗が「判定不能」に薄まる。どちらの順序でも `passed` にはならない。
export function gateVerdict(results) {
  if (results.length === 0) return null;
  if (results.some((result) => result.status === "failed")) return "failed";
  if (results.some((result) => result.status !== "passed")) return "errored";
  return "passed";
}

// 子の 3 値 outcome と gate の判定を合成する。
//
// **下方向にしか動かさない。** gate は子の結果を良くしない。
//
// 判定が無い（verdict が null）ときの扱いは、gate を**宣言したか**で分かれる:
//
//   - 宣言していない: 子の outcome をそのまま返す。ここで一律 `indeterminate` へ落とすと、
//     `--gate` を渡していない既存の呼び出しがすべて非 0 で終わる。「gate を通していない」
//     ことは outcome ではなく、連結された `verification_results` が 0 件であることから読む
//     （`fh runs` がその件数を返す）。
//   - 宣言したのに判定が取れなかった: `indeterminate`。条件を課したうえで測れなかったのだから、
//     通ったとは言えない。これが「判定できないなら成功と言わない」の適用箇所であり、
//     `errored`（起動できなかった / 時間切れ）を `indeterminate` へ写すのと同じ理由である。
export function combineOutcome(childOutcome, verdict, { declared = false } = {}) {
  if (childOutcome !== "succeeded") return childOutcome;
  if (verdict === null) return declared ? "indeterminate" : childOutcome;
  if (verdict === "passed") return "succeeded";
  if (verdict === "failed") return "failed";
  return "indeterminate";
}

// gate が失敗したときに `adapter_runs.failure_reason` へ載せる文。
//
// 固定語彙と件数だけで組み立てる。個々のチェックの `failureReason` は終了コード由来なので
// 自由文ではないが、記録に載せるのは「どれだけ通らなかったか」で足りる。
export function gateFailureReason(results) {
  const notPassed = results.filter((result) => result.status !== "passed").length;
  return `the completion gate did not pass: ${notPassed} of ${results.length} declared check(s) did not pass`;
}

// gate に関する判断を 1 か所で決める。呼び出し側が verdict・status・outcome・理由文を
// それぞれ別の条件式で組み立てると、片方だけ直したときに「outcome は indeterminate なのに
// 理由が空」のような食い違いが生まれる。
export function resolveGate({ gates, results, notRunReason, childOutcome }) {
  const verdict = gateVerdict(results);
  const declared = gates.length > 0;
  return {
    verdict,
    // 呼び出し側が読む status。`not-declared` は「gate を通っていない」を明示する値で、
    // succeeded と取り違えないための手掛かりになる。
    status: verdict ?? (declared ? "not-run" : "not-declared"),
    outcome: combineOutcome(childOutcome, verdict, { declared }),
    failureReason:
      verdict !== null && verdict !== "passed"
        ? gateFailureReason(results)
        : // 宣言したのに測れなかったときだけ、走らなかった理由を失敗理由として採る。
          // 子がそもそも失敗しているときは、子自身の失敗理由のほうが説明になる。
          verdict === null && declared && childOutcome === "succeeded"
          ? notRunReason
          : null,
  };
}

// evidence に載せる claim。固定語彙と件数、および承認済み manifest と完全一致した
// コマンド文字列だけで構成する（`verify-command.mjs` の verificationClaims と同じ規律）。
export function gateClaims({ gates, verdict, reason }) {
  if (gates.length === 0) {
    return ["the session declared no completion gate"];
  }
  const claims = [`the session declared ${gates.length} completion gate check(s)`];
  if (verdict === null) {
    claims.push(`the completion gate did not run: ${reason}`);
    return claims;
  }
  claims.push(`the completion gate ${verdict}`);
  return claims;
}

// 子へ渡す完了条件の説明。
//
// gate を harness だけが知っていると、子にとってこれは罠になる（何で測られるか分からないまま
// 測られる）。ここに置くのは fh 自身が決めた固定の文と、承認済み manifest と一致した
// コマンド文字列だけで、呼び出し側の自由文は入らない —— `SANDBOX_BRIEFING` と同じ扱い。
export function gateBriefing(gates) {
  if (gates.length === 0) return "";
  return [
    "<completion-gate>",
    "このセッションの完了条件は、次の承認済みチェックが**すべて緑で終わること**である。",
    "turn を終える前に、いま作業ツリーにある状態でこれらが通ることを自分で確かめること。",
    "",
    ...gates.map((gate) => `- \`${gate.command}\`（${gate.kind}）`),
    "",
    "harness はセッション終了後に同じチェックを自分で走らせ、**終了コードだけ**を見て結果を",
    "このセッションの記録へ連結する。通っていなければ、turn がエラーなく終わっていても記録は",
    "succeeded にならない。「あとで通します」「通知が来次第確認します」は完了条件を満たさない。",
    "</completion-gate>",
    "",
    "",
  ].join("\n");
}
