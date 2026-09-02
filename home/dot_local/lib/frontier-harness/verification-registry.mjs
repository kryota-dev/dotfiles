// 決定的チェックの**記録側の語彙**。`review-registry.mjs` と同じ位置づけのモジュールで、
// state にも CLI にも触れない純粋なドメイン層である。
//
// なぜ切り出すか。`fh verify` と `fh session --gate` は、どちらも承認済みチェックを走らせて
// 同じ形の `verification_results` 行と `verification_run` evidence を残す。共有が要るのに
// 置き場所が `verify-command.mjs`（コマンド実装）しか無いと、もう一方のコマンド実装が
// そこを import することになり、このリポジトリに command → command の依存が生まれる。
// `command-paths.mjs` が cli.mjs から切り出されたときと同じ判断（共有が要るなら中立モジュールへ）
// をここでも採る。
//
// 制限時間の定数（`DEFAULT_CHECK_TIMEOUT_MS` / `MAX_CHECK_TIMEOUT_MS`）はここではなく
// `check-runner.mjs` にある。あちらは「チェックをどう走らせるか」を所有しており、
// 制限時間はその実行の性質だからである。ここが持つのは「走った結果をどう記録するか」に限る。

// `--kind` を省いたときのチェック種別。`fh session --gate` の `<kind>:` 接頭辞の既定でもある。
export const DEFAULT_CHECK_KIND = "test";

// evidence の kind。`fh verify` と `fh session --gate` が同じ値を書くことで、
// 「どの経路から走ったチェックか」ではなく「決定的チェックが走った」という事実で引ける。
export const VERIFICATION_EVIDENCE_KIND = "verification_run";

// evidence に載せてよいのは固定語彙だけ。status と checkKind はどちらも閉じた enum なので、
// ここから組み立てた文が自由文になることはない（`session-command.mjs` の sessionClaims と同じ規律）。
export function verificationClaims({ checkKind, status, timedOut }) {
  const claims = [`the deterministic ${checkKind} check ${status}`];
  if (timedOut) {
    claims.push("the check was terminated for exceeding its time limit");
  }
  return claims;
}
