# A/B の手順と採点

## 原則

- 役割を普段起動する形（effort と本文）はそのままにし、モデルだけを替えて、現行と候補に同じ入力を渡す（モデルの差を比べるため）。
- 題材は、対象のモデルが担う作業の種類ごとに 1 件（実装・レビューなど）。
- 各 1 回の小さい標本であることを結果に書く。
- 役割として起動できない箇所（advisor など）は、この手順では比べられない。その箇所の問いには「A/B で確かめる」を入れず、比べられない旨を含意に書く。

## 題材の選び方

- 実装: マージ済みのコミットの一部を、その親コミットから再実装させる。仕様を数行で書け、テストがあり、数ファイルに収まるものを選ぶ。
- レビュー: マージ済みの PR の diff を渡す。
- 題材はこのリポジトリの履歴から選ぶ（手元の構成で実際に担う作業に近いため）。

## 準備と片付け

```bash
AB=<スクラッチ>/model-update/<対象>/ab
git worktree add --detach "$AB/impl-current" <親コミット>
git worktree add --detach "$AB/impl-candidate" <親コミット>
# 実際のコミットのテストは、実装者に見せないよう、$AB の外に取り出す
HIDDEN=$(mktemp -d)
git show <コミット>:<テストのパス> > "$HIDDEN/test"
# 終わったら、実装の変更を保存してから消す（未追跡のファイルも diff に入れる）
for w in impl-current impl-candidate; do git -C "$AB/$w" add -N . && git -C "$AB/$w" diff > "$AB/$w.diff"; done
git worktree remove --force "$AB/impl-current"
git worktree remove --force "$AB/impl-candidate"
```

- レビューの題材は PR の base と head の SHA を固定する。head の SHA で読み取り用の worktree を 1 つ作り（`git worktree add --detach "$AB/rev" <head の SHA>`）、現行と候補の両方をそこで起動する。指摘の裏取りもその版のコードで行う（後の変更が入った今のコードで採点すると、正誤を取り違えるため）。
- レビュー用の worktree も、終わったら同じに消す。

## モデルだけを替える起動

- GPT の役割: [model-roles.md](../../pr-workflow/references/model-roles.md) の「GPT の役割の起動」の形で起動し、`-m` だけを現行と候補で替える。それ以外（effort・本文・sandbox）は普段の起動形のまま、現行と候補で同じにする（普段と違う条件で比べると、実際の使い方での差が分からないため）。`--json` を付けてトークンを記録する。
- Claude の役割: model-roles.md の関数を読み込み、`claude_role` を上書きしてモデルだけを差し替え、`claude_leg`（レビュー）か `claude_impl`（実装）で起動する。次の形は実機で確かめてある。
- Claude の結果は、model-roles.md の「結果の判定」の `claude_check` で判定する。要求したモデルには、その回の起動に渡した ID（候補の回は差し替えた候補の ID）を渡す。`ok` でない回と判定が失敗した回は無効にし、同節の実行記録の欄とともに結果に書く。

```bash
# bash で実行する（model-roles.md の関数は bash 向け）。AB は上と同じ値を入れ直す
AB=<スクラッチ>/model-update/<対象>/ab
cd "$AB/rev"
ROLES="$HOME/.agents/skills/pr-workflow/references/model-roles.md"
awk '/^```bash$/{f=1;next} /^```$/{f=0} f' "$ROLES" > "$AB/helpers.sh"
source "$AB/helpers.sh"
eval "orig_$(declare -f claude_role)"
claude_role() {
  if [ "$2" = model ] && [ -n "${AB_MODEL:-}" ]; then echo "$AB_MODEL"; else orig_claude_role "$@"; fi
}
AB_MODEL="<候補の ID>" claude_leg <役割> "$AB/rev-candidate.json" "Read(/$AB/input/**)" < "$AB/prompt.md"
claude_leg <役割> "$AB/rev-current.json" "Read(/$AB/input/**)" < "$AB/prompt.md"
```

diff や PR の本文を渡すときの囲み方は、model-roles.md の「弱点への対策」に従う。

## 採点

実装:

- 検証の順は、codex skill の「親の手順」に従う。
- 自作のテストが通るか、実際のコミットのテスト（見せなかったもの）が通るか、lint を見る。
- 実装者のログで、題材のコミットや題材のツリーの外を読んでいないかを見る。読んでいたら、その回を無効にする（worktree は元のリポジトリの履歴を共有するので、正解を読めるため）。
- 範囲（指定したファイルだけか）、変更のしかた（頼んでいない書き直し、既存の規約、コメントの有無）、端のケースを実際に実行した結果を見る。

レビュー:

- 指摘の数ではなく、検証して採った指摘の数と、棄却した指摘の数を、現行と候補で比べる。

共通:

- 所要時間とトークン（入力・出力）、CLI の版を記録する。

## 結果の形

- 表（行は見る点、列は現行と候補）と、数行の読み取りを書く。
- 第三者の評価や利用者の声と、合うか合わないかを書く。
- 生の出力の置き場所を書く。
- 結果を比較の HTML に足し、Phase 4 に戻る。

## つまずき

- macOS の標準の bash（3.2）には `wait -n` が無い。並列に走らせるときは PID を控え、`wait <PID>` で個別に待つ。
- CLI を並列に走らせる本数は、multi-review の leg の起動の決まりに従う。
- `codex exec` をバックグラウンドで走らせる前に、codex skill の「stdin の落とし穴」を読む。
