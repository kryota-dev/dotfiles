# ADR 0001: fh の承認チャネルは MCP permission-prompt tool を維持する

🌐 English (canonical): [0001-fh-approval-channel.md](0001-fh-approval-channel.md)

← [ドキュメント目次](../README.ja.md)

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-09-04 |
| **Issue** | kryota-dev/dotfiles#630 |
| **Scope** | 判断の記録のみ。この ADR はコードを一切変更せず、実装を承認するものでもない。 |

## 背景

Frontier Harness は wave の各子セッションを `claude -p` プロセスとして起動し、`fh approve-server`
を MCP サーバーとして配線したうえで、そのツール名を `--permission-prompt-tool` に渡している。
承認の escalation も `AskUserQuestion` も、**同期的な MCP ツール呼び出し**として届く ——
呼ばれた時点が問いであり、返り値が回答である。escalation は state root 配下に 1 要求 1 ファイルで
永続化され、応答者が `fh approve` で答え、Leader は `fh approvals --json` をポーリングする。

その仕組みの参照先は
[Frontier Harness → 承認チャネル](../agents/frontier-harness.ja.md#承認チャネル) であり、
load-bearing な定数の SSOT もそこにある。この ADR では**それらの数値を再掲しない** ——
ここに複製すると必ず drift するからである。

issue #630 は、この構成を Claude Code 公式の 2 つの機構で置き換えられるかを問うた:

- `PreToolUse` hook の `defer` 判定
- `PermissionRequest` hook

**issue 本文の記述はどちらも部分的に誤っていた**ため、以下はすべて issue 本文ではなく、
読者が再検証できる情報源に基づく。

## これらの主張をどう検証したか

3 種類の情報源を使った。1 つ目だけでは信用できないと実際に分かったからである。

**1. 公開ドキュメント**（`code.claude.com/docs`）。要約ツール経由で取得した記述は、手がかりであって
根拠ではないものとして扱うこと。実際、hooks リファレンスをそう取得したところ `permissionDecision`
の値表が `allow` / `deny` / `dontAsk` として返ってきたが、これは二重に誤っている ——
`ask` と `defer` が欠落しており、`dontAsk` はそもそも hook の判定値ではなく**パーミッションモード**
である。この ADR の引用は、丸ごと取得できる程度に小さいページから採り、以下で相互検証した。

**2. 配布されている CLI バイナリ**。判定値の語彙・ガード条件・その診断メッセージが埋め込み文字列
として入っており、これが実挙動の正本である。バイト単位の grep で再現できる —— harness の `grep`
ラッパーは `-a` を付けない限りバイナリファイルを黙って飛ばすので注意する:

```bash
claude --version
grep -a -c -F 'permissionDecision' "$(mise which claude)"
grep -a -b -o -F 'tool_deferred' "$(mise which claude)" | head
```

**3. 公開 changelog**（`anthropics/claude-code` の `CHANGELOG.md`）。挙動が導入されたリリースを確認する。

Codex 側にはさらに強い情報源がある —— pin 済みの CLI が自分自身のプロトコルスキーマを生成できる。
ここで唯一、本リポジトリの `codex` ランチャーを迂回する必要があるコマンドである: ランチャーは
argv に `--profile` が無いとき `--profile shared` を注入するが、`app-server` は `--profile` 自体を
拒否する。Apple Silicon だけでなく両方の Homebrew prefix で動くよう、**ランチャー自身と同じ方法で**
実バイナリを解決する:

```bash
codex --version
CODEX_BIN="${CODEX_LAUNCHER_BIN:-$(ls /opt/homebrew/bin/codex /usr/local/bin/codex 2>/dev/null | head -1)}"
OUTDIR="$(mktemp -d)"
"$CODEX_BIN" app-server generate-json-schema --out "$OUTDIR"
grep -o '"[a-z][a-zA-Z]*/[A-Za-z/]*"' "$OUTDIR/ServerRequest.json" | sort -u
```

ランチャーの迂回は、スキーマを書き出すだけのこの読み取り専用コマンド 1 本に限定される。
**一般化してはならない。** `codex exec` のような実行系サブコマンドを `--profile` 無しで呼ぶと、
[Codex CLI ハーネス設定](../agents/codex.ja.md) が「既知のギャップがある」と述べている
ガバナンスされていない権限経路に乗ることになる。

この ADR が挙げるツールのバージョン（Claude Code 2.1.259、Codex CLI 0.150.1）は、**何をいつ
確認したか**の記録である。日付付きの判断記録における出所情報であって、本リポジトリが他所で
表明している pin ではない。`<!-- FACT -->` マーカーを付けていないのはそのためである。

## 検討した選択肢

### 選択肢 A — `--permission-prompt-tool` と MCP 承認サーバーを維持する *(採用)*

背景で述べた現行方式。

### 選択肢 B — `PermissionRequest` hook

**却下: fh の実行形態では利用できない。** hooks ガイドの Limitations にこうある:

> `PermissionRequest` hooks fire when Claude Code is about to ask you for permission.
>
> * In non-interactive mode with the `-p` flag, that prompt only exists when the Agent SDK's
>   `canUseTool` callback supplies it. **In plain `-p` runs or with `--permission-prompt-tool`,
>   use `PreToolUse` hooks for automated permission decisions instead.**

fh の子セッションはまさに「`--permission-prompt-tool` を伴う plain な `-p` 実行」である。
障害はパーミッション**モード**ではない —— `-p` セッションは確かに `default` で始まる ——
障害は「聞く相手が居ないので prompt そのものが存在せず、hook が発火する対象が無い」ことである。

issue は `PermissionRequest` について「未応答なら自動 deny する」とも述べていた。この挙動は
実在するが、述べられていたより範囲が狭い。同じ Limitations がバックグラウンドのサブエージェントに
限定している:

> Background subagents can't show a prompt in non-interactive mode. Claude Code still runs the
> hooks for their tool calls, and if no hook returns a decision, it denies the call.

さらに 2 つの性質があり、いずれにせよ失格である。判定語彙が allow/deny のみで「まだ待っている」
状態を表現できないため保留中の escalation を表せない。また判定しか運べないため、
`AskUserQuestion` の**回答**を届けられない。

### 選択肢 C — `defer` を返す `PreToolUse` hook

**`defer` は実在し、公式にも記載がある。** hooks ガイドより:

> A fourth value, `"defer"`, is available in non-interactive mode with the `-p` flag. It exits
> the process with the tool call preserved so an Agent SDK wrapper can collect input and resume.

複数 hook の出力を統合する際の規則:

> For `PreToolUse` permission decisions, the most restrictive answer applies, in the order
> `deny`, `defer`, `ask`, `allow`.

導入時の changelog エントリ（2.1.89）:

> Added `"defer"` permission decision to `PreToolUse` hooks — headless sessions can pause at a
> tool call and resume with `-p --resume` to have the hook re-evaluate

配布バイナリもすべて一致する。未知の値に対する拒否メッセージは
`Valid types are: allow, deny, ask, defer` であり、同じ優先順位が明示的な連鎖として実装され
（`deny` が `defer` に勝ち、`defer` が `ask` に、`ask` が `allow` に勝つ）、defer した実行は
`stop_reason: "tool_deferred"` で終了して result メッセージに `deferred_tool_use` payload を
載せる。失敗系には別の `tool_deferred_unavailable` 理由がある。

**fh にとっての本物の利点。** 却下が「代替案に見るべきものが無かった」と読まれないよう、
実在する利点を 2 点記録する:

- *在プロセスの待機が不要になる。* 現在、escalation は待機期間のあいだ MCP ツール呼び出しを
  塞ぎ続け、stdio の idle timeout に殺されないよう定期的な progress 通知で生かしている。
  `defer` なら子は終了する。この機構は一切不要になり、人を待つ子はリソースを保持せず、
  Leader の再起動も跨げる。
- *終了そのものが通知になる。* 子が止まったことは直接観測できるので、Leader の
  `fh approvals` ポーリングをイベント駆動にできる —— issue が挙げた「Leader への push」の軸。

**それでも現行チャネルの置き換えにならない理由。**

1. **バッチ呼び出しでは deferral が黙って捨てられ、hook 側で埋め合わせられない。**
   ランタイムは、同一バッチに複数のツール呼び出しがあるとき deferral を拒否する
   （resume 時に兄弟が孤児になるため）。警告をログに出して判定を破棄する。**この検査は hook の
   出力を消費する側で走る** —— つまり hook が既に返った後である。したがって hook は、自分の
   deferral が捨てられようとしていることを知る術がなく、`deny` へフォールバックすることも
   できない。呼び出しは残りのパーミッション機構によって、**user を介さずに**解決される ——
   wave が依存しているのはまさにその escalation である。

   これは例外的な形ではない。独立した呼び出しを 1 バッチにまとめて発行するのは通常の、
   むしろ推奨される形であり、gate は最も一般的な経路で失われ、子のログの警告としてしか現れない。

2. **print-mode 専用である。** 対話セッションではランタイムが deferral を無視する。wave の子に
   とっては無害だが、1 つの hook で対話・非対話の両方を賄えないため、ポリシーが二重化する。

3. **クラウドセッションに供された呼び出しには適用されない。** resume 機構が無いことを理由に
   ランタイムが明示的に拒否する。

4. **起動前の positive control が失われる。** `approval-channel.mjs` は、**子を起こす前に**
   宣言した承認サーバーを実際に起動して MCP handshake を完了させ、`child-runner.mjs` が続けて
   `system/init` を検査し、チャネルを欠く子をその場で終了させる。hook には等価物が無い ——
   宣言を誤った hook は沈黙し、子は escalation しないまま普通に走る。これは現行設計が
   起こり得なくするために作られた故障そのものである（user へ到達できない子が、それでも走り出す）。

5. **hook の配信が fh の分離設計と噛み合わない。** 承認サーバーはコマンドラインの
   `--mcp-config` で子ごとに宣言され、`--strict-mcp-config` と `--setting-sources user` が、
   チェックアウトされたリポジトリによる差し込みを止めている。hook は代わりに settings source
   経由で届くため、承認 hook を user の settings ファイルに置くと、fh の子だけでなく**その
   マシン上の全 Claude セッションにグローバルに効く**。呼び出しごとの `--settings` payload で
   運べる可能性はあるが **これは未検証**であり、いずれにせよ 4 は解決しない。

### 選択肢 D — `defer` と既存の prompt tool の併用

1 の穴を塞げる唯一の構成 —— `defer` が取りこぼすバッチ呼び出しが user に届くよう
`--permission-prompt-tool` を残し、`defer` は適用できる場面だけで使う。hook はパーミッション
prompt tool より先に評価されるため、両者は曖昧さなく合成でき、「在プロセス待機の解消」という
利点も得られる。

**現時点では却下**する。これは機構を**足す**方向だからである。issue #630 の動機はポーリングと
独自サーバーの保守を**減らす**ことだったが、選択肢 D は両方を残したうえで、意味論の異なる
2 本目の escalation 経路をその横に足す。しかも escalation ルールを 2 経路で一致させ続ける
必要が生じる。複雑さは消えるのではなく移動するだけである。

## 決定

**選択肢 A を維持する。** fh は引き続き、承認と `AskUserQuestion` を
`--permission-prompt-tool` と MCP 承認サーバー経由で往復させる。

現行チャネルを維持するのは、代替案が粗悪だからではない。`PermissionRequest` は fh が子を
走らせるモードでは単純に利用できない。`defer` はほぼこの問題のために設計された良い機構だが、
gate 全体を単独では担えない。そして担える唯一の構成（選択肢 D）は、解決する問題より
コストが大きい。

## 帰結

選択肢 A を維持することで受け入れるコスト:

- 独自 MCP サーバーがツリーに残る（プロトコルバージョンのネゴシエーション、progress 通知、
  idle timeout の予算管理を含む）。
- escalation は待機期間のあいだ MCP ツール呼び出しを開いたままにするため、人を待つ子は
  常駐し続ける。
- Leader は push を受けるのではなく `fh approvals` をポーリングする。
- 子セッションは claude 専用のままである。`approval-channel.mjs` は `SESSION_PROVIDER` を
  `claude` に固定する意図的な fail-closed 境界を持ち、この決定はそれを広げない。

維持される保証:

- 子は、承認チャネルが実際の MCP handshake に応答しない限り起動できず、`system/init` が
  チャネルの欠落を示せば終了させられる。
- `AskUserQuestion` の回答は値として往復し、書き込み側と読み出し側が同じ検証関数を通る。
- escalation キューは 1 ファイルにつき writer がちょうど 1 つで、回答は `O_EXCL` と `link(2)`
  で publish されるため、1 要求は 1 度だけ answer される。
- escalation ルールは作業ツリーの外にあり、チェックアウトされたリポジトリから弱められない。

## 再検討トリガ

次のいずれかが真になったとき、この決定を開き直すべきである。願望ではなく**検査可能**な形で書く。

- **T1 — `defer` がバッチ呼び出しで使えるようになる。** ランタイムが兄弟のいるバッチで
  deferral を破棄しなくなるか、`PreToolUse` の payload がバッチについて十分な情報を露出して
  hook 自身が fail closed にできるようになるか、どちらか。配布バイナリのガードと、hooks
  リファレンスの "Defer a tool call for later" 節を再確認すること。
- **T2 — 子スコープの hook 配信経路が検証される。** `--strict-mcp-config` と
  `--setting-sources user` を緩めずに承認 hook を呼び出しごとに注入でき、**かつ**現行の
  handshake probe に相当する起動前 positive control がその経路に存在すること。**両方**が必要で、
  前者だけでは 4 の問題を移動させるだけである。
- **T3 — 維持コストが具体化する。** 在プロセスの escalation 保持、または MCP idle timeout
  機構に起因すると追跡できた実際の障害。仮定の話ではなく。

トリガが発火した後に `defer` を採用することは実装変更であり、独自の issue が必要である。
この ADR はそれを承認しない。

## Codex app-server の再評価

`adapter-codex.mjs` は `approvalChannel: "agent-review"` を宣言しており、これは「人の判断を
要する task を Codex へ route しない」ことを意味する。issue #630 は、Codex app-server に
サーバー発の承認要求がある今もその判断が成り立つのかを問うた。

**この宣言は、adapter が実際に使っている transport については正しい。** `adapter-codex.mjs` が
駆動するのは `codex exec` で、承認要求を外部プロセスへ渡すチャネルを持たない。この宣言は
「Codex という製品」についての主張として読むべきではない。

**`codex app-server` transport では話が異なり、これは upstream の散文ではなく pin 済み CLI に
対して検証した。** Codex CLI 0.150.1 が自分自身のために生成するスキーマは、`ServerRequest`
（サーバーがクライアントへ向けて開始する要求）に次を含む:

- `item/commandExecution/requestApproval`
- `item/fileChange/requestApproval`
- `item/permissions/requestApproval`
- `item/tool/requestUserInput`
- `mcpServer/elicitation/request`

これは本物の外部承認チャネルである。クライアントが decision を返すとターンが再開または辞退し、
`item/tool/requestUserInput` は「人を待つべき入力」を示す blocking フラグを持つ。この transport
の下では、軸の値は `agent-review` ではなく `external` になる。

**未検証:** issue が併せて挙げた `thread/queue/add` は upstream の app-server README に記載が
あるが、**pin 済み CLI の生成スキーマには存在しない**。upstream は experimental とし、
`experimentalApi` capability の背後に置いている。この ADR は一切これに依存しておらず、
利用可能なものとして扱うべきではない。

**この ADR はいかなる宣言も変更しない。** fh を app-server へ移すことは、fh を thread と turn の
ライフサイクルを所有する JSON-RPC クライアントにすることであり、capability 文字列よりはるかに
大きな変更である。`approval-channel.mjs` は既に、2 つ目のセッション provider が何を揃える必要が
あるかを記録している —— 配線、封印した argv の検証、provider 固有の起動時健全性検査であって、
capability の値だけではない。この作業は独自の issue に属する。

**この節は、その issue の起点であって、通りすがりの観察記録ではない。** issue を立てる人が
スキーマ検査をやり直さなくて済むようにしてある —— 上記の method 一覧、pin 済みスキーマに
`thread/queue/add` が無いこと、`codex exec` transport と Codex 全体との区別が、その入力である。
issue を実際に立てるかどうかは別の判断であり、ここでは行わない。

## 未決の選択をどう解決したか

この ADR は非対話セッションで書かれたため、依拠する選択は端末で尋ねるのではなく、上で述べた
承認チャネルに掛けて解決した。**そのチャネル自体がこの ADR の対象である**以上、各選択が
どう解決されたかを記録しておくことに意味がある。

3 つとも承認チャネル経由で確認が取れた:

1. **結論** —— `defer`（選択肢 C）や併用（選択肢 D）を採用するのではなく、現行チャネルを
   維持して再検討トリガを記録する。
2. **置き場と書式** —— `design-rationale.md` への節追加や `docs/explanation/` 配下のページでは
   なく、`docs/decisions/` 配下の番号付き ADR とする。本リポジトリには既存の ADR 慣習が無く、
   これがその慣習を新設することになる。
3. **Codex のスコープ** —— 検証結果を、将来の app-server issue の**明示的な起点**として残し、
   ここでは issue を立てない。この ADR の初稿はより弱い既定（結果を記録し、追随は別に属すると
   述べるに留める）で決めていたが、レビューがそれを明示化する側へ押した。上の節が自らを
   「その起点である」と名乗っているのはそのためである。

ひとつ運用上の観察を残す。この ADR が判断対象としているチャネルそのものについての実測だからで
ある —— ここで最初に上げた escalation（3 つの問いを 1 要求にまとめたもの）は待機上限に達して
`denied automatically` を返したが、その後の単一論点の escalation は通常どおり回答された。
これは 1 件の観察であって原因の診断ではないため、説明を付けずに事実として記録する。

## 出典

| 主張 | 出典 |
|---|---|
| `PermissionRequest` は plain な `-p` 実行では利用不可。バックグラウンドサブエージェントの自動 deny | [Hooks guide → Limitations](https://code.claude.com/docs/en/hooks-guide) |
| `defer` の実在、print-mode 専用、優先順位 `deny` → `defer` → `ask` → `allow` | [Hooks guide](https://code.claude.com/docs/en/hooks-guide) / [Hooks reference → Defer a tool call for later](https://code.claude.com/docs/en/hooks#defer-a-tool-call-for-later) |
| `defer` の導入と `-p --resume` での再開 | `anthropics/claude-code` `CHANGELOG.md` 2.1.89 |
| 判定語彙、solo-only / print-mode ガード、`tool_deferred` / `deferred_tool_use` | 配布 Claude Code バイナリの埋め込み文字列（執筆時点 2.1.259） |
| `-p` セッションは `default` モードで始まる | [Permission modes → Which mode a session starts in](https://code.claude.com/docs/en/permission-modes) |
| hook はパーミッション prompt tool / `canUseTool` より先に走る | [Agent SDK → Configure permissions](https://code.claude.com/docs/en/agent-sdk/permissions) |
| Codex のサーバー発 承認要求 | pin 済み Codex CLI が生成したプロトコルスキーマ（執筆時点 0.150.1） |
| `thread/queue/add` は記載はあるが pin 済みスキーマに不在 | [`codex-rs/app-server/README.md`](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md) と生成スキーマの差 |
