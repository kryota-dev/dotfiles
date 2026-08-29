// CLI の終了コード。複数のコマンド実装が共有するので 1 か所に置く。
//
// 呼び出し側スクリプトが「承認が要る」「子が失敗した」「使い方が違う」を 0 と区別できないと、
// 止まった理由を成功として読んでしまう。値そのものが契約なので、意味ごとに名前を付ける。

// 承認待ちで実行を止めたときの終了コード。`onboard` が「まだ承認していない」に使っていた
// ものを、承認境界が実行を止めた全経路（run / verify / session）へ広げる。
export const BLOCKED_PENDING_APPROVAL = 2;

// 子セッションが起動できなかった、または起動したが失敗した。
// 承認境界による停止（2）と区別する: こちらは「承認はあるが実行が失敗した」である。
export const CHILD_RUN_FAILED = 1;

// 決定的チェックが通らなかった（failed / errored）。値は CHILD_RUN_FAILED と同じだが、
// 意味が違うので別の名前を与える —— 呼び出し側にとって「子が起動できなかった」と
// 「チェックが赤だった」は同じ 1 でも次の行動が違う。0 は「検証が通った」だけを指す。
export const VERIFICATION_FAILED = 1;

// candidate を取り込めなかった（検証未達、または衝突）。どちらも user の判断へ戻すので、
// 承認境界による停止と同じ 2 を使う: 呼び出し側から見れば「人が見るまで進めない」で同じ意味になる。
export const CANDIDATE_NOT_ADOPTED = 2;

// 未知のコマンド。sysexits.h の EX_USAGE。
export const USAGE = 64;

// 想定外の例外で終わった。sysexits.h の EX_SOFTWARE。
// 承認待ち（2）・実行失敗（1）・使い方の誤り（64）のいずれでもない、内部の不整合を指す。
export const INTERNAL_ERROR = 70;
