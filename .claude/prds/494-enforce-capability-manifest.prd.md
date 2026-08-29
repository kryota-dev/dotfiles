---
slug: 494-enforce-capability-manifest
feature: frontier-harness の repository capability manifest を実行前照合の承認境界として実効化する
created_at: 2026-08-29T14:14:36+09:00
grill_session: 0142nAqSnSL7Ce5B4pSY6m8t
status: finalized
---

# Background

`fh onboard` は `<repo>/.harness/policy.json` へ承認済み manifest を書き出すが、それを読む実装が
リポジトリ内に存在しない（`home/dot_local/lib/frontier-harness/cli.mjs:337` が唯一の書き手で、
読み手はゼロ）。`docs/agents/frontier-harness.md:50` も "enforcement lands with the onboarding step"
と明記しており、承認境界は実体として存在しない。

あわせて次の 4 つの弱点が指摘されている。

1. 承認ハッシュが manifest 内容から計算され同じファイルに同梱されるため、保存後の改竄を検知できない。
2. `--approve` を同じ 1 回の呼び出しで付けられるため、実質的な自己承認ができる。
3. domain 検証が「ホスト名の形をしていれば通る」形式検査に留まる。
4. command 許可リストが「引数付きであること」しか見ていない。

本 issue は wave3 の律速の先頭であり、#502（rollout を pilot/default へ昇格）が本作業のマージを
待っている。承認境界を実体化してから rollout を昇格させる順序を選んでいる。

# User Story

wave で複数の子セッションを並列に走らせる利用者として、リポジトリごとに一度承認した
command / domain / capability の範囲を harness が実行前に実際に照合し、範囲外の要求は
実行せずに queue へ積んで wave の境界でまとめて承認できるようにしたい。承認が
「記録されているだけ」ではなく「実行を止める」ものであることを、テストで確かめられる形にしたい。

# Acceptance Criteria

- **AC-001** `fh run` は task が宣言した command / domain と、`chooseRoute` が選んだ capability を
  承認済み manifest と照合する。1 つでも未承認なら route を `escalation` として記録し、
  provider 実行経路へ進まない。
- **AC-002** `.harness/policy.json` が存在しない repository は空 manifest として扱い、すべての
  command / domain / capability を未承認とする（fail-closed）。
- **AC-003** 未承認項目は state root 配下の gap queue に 1 項目 1 ファイルで記録される。同一項目の
  重複記録は作成のみ（`O_EXCL`）で冪等とし、並行する wave 子セッションの lost update を
  構造的に回避する。
- **AC-004** `fh gaps --json` が pending gap を列挙する。
- **AC-005** `fh onboard --from-gaps` が「承認済み manifest ∪ pending gaps」を候補 manifest として
  組み立て、通常と同じ 2 段階承認儀式に載せる（wave 境界の一括承認）。承認完了時に
  取り込まれた gap を削除する。
- **AC-006** `fh onboard --manifest X`（`--approve` 無し）は manifest を検証して表示し、単回使用の
  review request を state root（trusted store）へ書き出して exit 2 を返す。
- **AC-007** `fh onboard --manifest X --approve` は `--request <id>` を欠く場合に拒否する
  （同一呼び出しでの自己承認の遮断）。
- **AC-008** `--request <id>` は (a) 存在し、(b) 未期限切れ（既定 24h）で、(c) 現在の pid と異なる
  pid が作成し、(d) 記録された manifestHash が今回正規化した manifest の hash と一致する場合に
  のみ承認を通す。承認後 request は消費され再利用できない。
- **AC-009** 承認は state DB の approvals 台帳へ `kind=repository_manifest` /
  `subjectHash=sha256(manifest)` / `scope=解決済み git common directory` / `grantedBy=user` で
  記録される。
- **AC-010** 照合時に policy.json の manifest を再ハッシュし、台帳に一致行が無ければ改竄として
  拒否する。policy.json のみを書き換えた改竄がテストで検出される。
- **AC-011** 別 repository からコピーした policy.json は scope 不一致で照合を通らない。
- **AC-012** manifest の domain 検証は、169.254.0.0/16（169.254.169.254 を含む）・10.0.0.0/8・
  172.16.0.0/12・192.168.0.0/16・100.64.0.0/10・0.0.0.0/8・127.0.0.0/8・224.0.0.0/4・240.0.0.0/4・
  `::1`・fc00::/7・fe80::/10・IPv4-mapped IPv6 を拒否する。
- **AC-013** 10 進・8 進・16 進・短縮形の IPv4 表記（`2852039166` / `0251.0376.0251.0376` /
  `0xA9FEA9FE` / `169.254.43518`）も同じ判定に載り拒否される。
- **AC-014** loopback は `localhost` / `127.0.0.1` / `::1` のリテラル指定のみ許可し、他の名前が
  loopback へ解決した場合は拒否する。
- **AC-015** `metadata.google.internal` 等のメタデータ用ホスト名を denylist で拒否する。
- **AC-016** `fh onboard` は承認前に各 domain をアドレス解決し、解決先に 1 つでも拒否対象が
  含まれれば承認しない。resolver は注入可能で、公開名が 169.254.169.254 へ解決するケースの
  拒否がテストされる。解決不能は fail-closed とする。
- **AC-017** command 照合は `analyzeShellCommand` によるトークン化を経て、正規化済みの完全一致で
  行う。`npm run test; curl …` や `npm run test && rm -rf /` は一致せず未承認となる。
- **AC-018** 静的解釈できないコマンド（動的構築・ネストシェル）は ambiguous として承認・照合とも
  拒否する（fail-safe）。
- **AC-019** `fh verify --command X` も X を承認済み command として照合し、未承認なら実行計画を
  記録せず gap へ積む。
- **AC-020** docs（en / ja）が実効化後の挙動、2 段階儀式、gap の一括承認、および「同一 uid の
  攻撃者は防げない」残余リスクを記載する。

# Considered Alternatives / Rejection Rationale

1. **改竄検知を HOME 配下の鍵による HMAC で行う**（AC-009 / AC-010）— 却下。同一 uid の攻撃者に
   対する強度は approvals 台帳との突合と同等（鍵も同じ uid で読める）でありながら、鍵の生成・
   保管・ローテーションが純増する。`record-validation.mjs:60` が「出所をどう証明・検証するかは
   #494 が決める」として approvals 台帳の経路を予約済みであり、その経路を使うのが素直。
2. **loopback を全面拒否する**（AC-014）— 却下。ローカル dev サーバは正当な用途で、既存の
   domain regex と既存テストが `localhost` を明示的に許可している。リテラル指定のみ許可すれば
   「公開名 → loopback」の擦り替えは塞げる。
3. **gap queue に `approval-queue.mjs` を流用する**（AC-003）— 却下。あちらは tool call 形状
   （`toolName` / `input` / AskUserQuestion 回答）に密結合しており、両者の統合は
   `approval-queue.mjs` の冒頭コメントが明示的に #534 の所有としている。
4. **gap を SQLite のテーブルにする（schema v3 migration）**（AC-003）— 却下。migration の risk を
   負ううえ、複数 writer による read-modify-write が lost update を生む。file-per-gap + `O_EXCL` は
   同じ問題を構造的に回避する（`approval-queue.mjs` が並行 wave 子セッション向けに選んだ設計と同型）。
5. **`runCli` 全体を async 化する**（AC-016）— 却下。2942 行のテストで `assert.throws` →
   `assert.rejects` の機械変換が必要になり誤りやすい。DNS 解決を要するのは `onboard` だけなので、
   `onboard` のみ Promise を返し、entrypoint は `Promise.resolve` で受ける。
6. **承認時の DNS 解決を省き literal 検査のみ行う**（AC-016）— 却下。AC が「形式検査ではなく
   アドレス解決後の判定」を要求しており、公開名が内部アドレスへ解決するケースを literal 検査は
   捕まえられない。
7. **capability 照合を警告に留める**（AC-001）— 却下。#502 が rollout を pilot/default へ昇格させた
   直後に、capability 承認が効かないまま provider 実行が始まる。

## 自律解決した前提（assumption）

- `.harness/policy.json` は git 追跡下にある（`.gitignore` されていない）。gitignore 化は #508 の
  範囲であり、本 PRD では触れない。改竄検知の脅威モデルは「checkout / pull / 悪意ある PR が
  policy.json を差し替える」を主とし、同一 uid の攻撃者は防げない旨を docs に明記する。
- state root（`git rev-parse --git-common-dir` + `frontier-harness/`、mode 0700、git 非追跡）は
  policy.json とは別の書き込み経路を持つ信頼ストアとして扱う。
- `fh run` の task JSON に `commands` / `domains` を任意フィールドとして追加する
  （`normalizeTask` の既存 `requireStringArray` を再利用、既定は空配列）。
- fail-closed 化により既存の `fh run` テスト 11 本と `verify` テスト 1 本が onboard 前提へ更新される。

# Out of Scope

- rollout の pilot / default 昇格そのもの（#502）
- capability registry への承認チャネル軸の追加（#534）
- deterministic verifier / review registry / candidate worktree（#495）
- `fh` CLI の運用品質残件（#508。route 履歴のページング、cleanup の対象一覧、stack trace 抑止、
  `.harness` の gitignore、`FH_NODE_BIN` の扱い）
- `docs/` のカウンタ型 FACT マーカーの増減（#532 の並行 PR 衝突を避けるため）

# Open Questions

- 承認そのものの有効期限（approvals 台帳の `expires_at`）は本 PRD では設けず NULL とする。
  運用上必要になった時点で別 issue とする。
