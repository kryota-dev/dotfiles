// baseline の escalation ルール（データ）。ルールの読み込み・検証・照合ロジックは
// approval-rules.mjs にある。両者は変更理由が異なる（ルールを 1 件足すのはデータ変更、
// 検証を直すのはエンジン変更）ため、ファイルを分けている。
//
// baseline を「コード内の定数」として持つのが本設計の要である。deny ルールの漏れは
// fail-open（人に聞かずに実行される）なので、「ファイルが無い / 壊れている」ときに
// ルールが消える構造を許さない。ファイルからは追加しかできない。
//
// 照合対象は approval-command.mjs が作る候補（生文字列 ＋ global option を読み飛ばして
// 正規化した各セグメント）である。したがって各パターンは「binary の直後に subcommand が
// 来る形」だけを書けばよく、`git -C <path> merge` のような形は正規化側が吸収する。

// 正規表現の部品
// ---------------------------------------------------------------------------

// シェルのコマンド境界。行頭、または空白 / 区切り記号の直後。
const SHELL_BOUNDARY = String.raw`[\s;&|(){}<>$"'\x60]`;
// 直前の境界 + 省略可能なパス接頭辞。`/usr/bin/git` や `./bin/gh` も拾い、
// `mygit` のような別コマンドは拾わない。
const COMMAND_PREFIX = String.raw`(?:^|${SHELL_BOUNDARY})(?:[\w.~/-]*/)?`;
// 語の終端。`git merge` は拾い、`git merge-base` / `git mergetool` は拾わない。
const WORD_END = String.raw`(?![\w-])`;
// コマンドの後ろに任意個の引数が挟まりうる形。次のコマンドまで越えないよう区切りを除外する。
const SAME_COMMAND = String.raw`[^;&|\n]*?`;
// パス文字列の中の要素境界。`/home/u/.ssh/id_rsa` は拾い、`foo.ssh` は拾わない。
const PATH_BOUNDARY = String.raw`(?:^|[^\w.-])`;

// `<binary> <subcommand>` の形。dashed 形式（`git-merge`）も同時に拾う。
function commandPattern(binaries, subcommand) {
  return String.raw`${COMMAND_PREFIX}(?:${binaries})[\s-]+(?:${subcommand})${WORD_END}`;
}

// `<binary> <subcommand> ... <flag>` の形。flag は引数のどこに現れてもよい。
function subcommandFlagPattern(binaries, subcommand, flags) {
  return String.raw`${COMMAND_PREFIX}(?:${binaries})[\s-]+(?:${subcommand})${WORD_END}${SAME_COMMAND}\s(?:${flags})(?:[\s=]|$)`;
}

// `<binary> ... <flag>` の形（subcommand を取らないコマンド用）。
function commandFlagPattern(binaries, flags) {
  return String.raw`${COMMAND_PREFIX}(?:${binaries})${WORD_END}${SAME_COMMAND}\s(?:${flags})(?:[\s=]|$)`;
}

function anyOf(...patterns) {
  return patterns.join("|");
}

// 資格情報が入るパス。同じ表現を 2 つのルール（Bash のコマンド文字列と、
// 任意ツールのパス引数）が共有する。
function credentialPathPattern() {
  return anyOf(
    String.raw`${PATH_BOUNDARY}\.(?:ssh|aws|gnupg|docker|kube)/`,
    String.raw`${PATH_BOUNDARY}id_(?:rsa|dsa|ecdsa|ed25519)${WORD_END}`,
    String.raw`${PATH_BOUNDARY}\.netrc${WORD_END}`,
    String.raw`${PATH_BOUNDARY}\.env(?:\.[\w-]+)?${WORD_END}`,
  );
}

function approvalChannelPathPattern() {
  return String.raw`frontier-harness[\\/]approvals|\.answer\.json${WORD_END}`;
}

// 語彙
// ---------------------------------------------------------------------------

// risk 語彙は出荷 config の `risk.alwaysEscalate` を**包含する** superset とする。
// config 側は task 単位の routing 判断に使う語彙で、こちらは tool call 単位の
// escalation カテゴリなので粒度が違い、承認チャネル固有のカテゴリを追加で持つ。
// config の語を欠かさないことは tests/frontier_harness_approval.test.mjs が機械検査する。
export const CONFIG_RISK_VOCABULARY = Object.freeze(
  new Set([
    "credential",
    "data-migration",
    "deploy",
    "external-contract",
    "force-push",
    "merge",
    "migration",
    "release",
  ]),
);

// 承認チャネル固有のカテゴリ。config の routing 語彙には対応物が無い。
const APPROVAL_ONLY_RISKS = Object.freeze(
  new Set([
    "approval-channel",
    "external-publish",
    "history-rewrite",
    "opaque-command",
    "unmatched",
    "user-question",
    "working-tree-rollback",
  ]),
);

export const APPROVAL_RISKS = Object.freeze(
  new Set([...CONFIG_RISK_VOCABULARY, ...APPROVAL_ONLY_RISKS]),
);

// baseline ルール
// ---------------------------------------------------------------------------

export const BASELINE_APPROVAL_RULES = Object.freeze(
  [
    {
      id: "git-merge",
      risk: "merge",
      tool: "Bash",
      field: "command",
      pattern: commandPattern("git", "merge"),
      reason: "マージは gate を経ずに実行しない",
    },
    {
      id: "gh-pr-merge",
      risk: "merge",
      tool: "Bash",
      field: "command",
      pattern: commandPattern("gh", String.raw`pr[\s-]+merge`),
      reason: "PR のマージは user の判断",
    },
    {
      id: "git-force-push",
      risk: "force-push",
      tool: "Bash",
      field: "command",
      pattern: anyOf(
        subcommandFlagPattern(
          "git",
          "push",
          String.raw`--force(?:-with-lease|-if-includes)?|-f`,
        ),
        // refspec の先頭 `+` も強制更新を意味する。フラグを使わない強制 push。
        String.raw`${COMMAND_PREFIX}git[\s-]+push${WORD_END}${SAME_COMMAND}\s\+[A-Za-z0-9_./-]`,
      ),
      reason: "強制 push は他者の履歴を壊しうる",
    },
    {
      id: "git-delete-remote-ref",
      risk: "force-push",
      tool: "Bash",
      field: "command",
      pattern: anyOf(
        subcommandFlagPattern("git", "push", String.raw`--delete|-d`),
        String.raw`${COMMAND_PREFIX}git[\s-]+push${WORD_END}${SAME_COMMAND}\s:`,
      ),
      reason: "リモート参照の削除は取り消せない",
    },
    {
      id: "git-history-rewrite",
      risk: "history-rewrite",
      tool: "Bash",
      field: "command",
      pattern: commandPattern(
        "git",
        String.raw`rebase|filter-branch|filter-repo|reflog[\s-]+(?:expire|delete)|update-ref[\s-]+-d`,
      ),
      reason: "履歴の書き換えは取り消せない",
    },
    {
      id: "git-amend",
      risk: "history-rewrite",
      tool: "Bash",
      field: "command",
      pattern: subcommandFlagPattern("git", "commit", String.raw`--amend`),
      reason: "既存コミットの書き換えは履歴を変える",
    },
    {
      id: "git-hard-reset",
      risk: "history-rewrite",
      tool: "Bash",
      field: "command",
      pattern: subcommandFlagPattern("git", "reset", String.raw`--hard`),
      reason: "hard reset は未コミットの作業を失わせる",
    },
    {
      id: "git-branch-delete",
      risk: "history-rewrite",
      tool: "Bash",
      field: "command",
      pattern: subcommandFlagPattern("git", "branch", String.raw`-[dD]|--delete`),
      reason: "ブランチの削除は取り消しに手間がかかる",
    },
    {
      id: "git-worktree-rollback",
      risk: "working-tree-rollback",
      tool: "Bash",
      field: "command",
      pattern: anyOf(
        commandPattern("git", "restore|stash"),
        String.raw`${COMMAND_PREFIX}git[\s-]+checkout[\s-]+--\s`,
        subcommandFlagPattern("git", "clean", String.raw`-[a-zA-Z]*f[a-zA-Z]*`),
      ),
      reason:
        "共有作業ツリーの巻き戻しは他セッションの未コミット編集を静かに消す（#524）",
    },
    {
      id: "gh-release",
      risk: "release",
      tool: "Bash",
      field: "command",
      pattern: commandPattern(
        "gh",
        String.raw`release[\s-]+(?:create|edit|delete|upload)`,
      ),
      reason: "リリースは外部に公開される",
    },
    {
      id: "package-publish",
      risk: "release",
      tool: "Bash",
      field: "command",
      pattern: anyOf(
        commandPattern("npm|pnpm|yarn|bun|uv", "publish"),
        commandPattern("cargo", "publish"),
        commandPattern("gem", "push"),
        commandPattern("twine", "upload"),
        commandPattern("docker|podman", "push"),
      ),
      reason: "パッケージの公開は取り消せない",
    },
    {
      id: "git-push-tags",
      risk: "release",
      tool: "Bash",
      field: "command",
      pattern: subcommandFlagPattern(
        "git",
        "push",
        String.raw`--tags|--follow-tags`,
      ),
      reason: "タグの push はリリース手順の起点になりうる",
    },
    {
      id: "gh-external-write",
      risk: "external-publish",
      tool: "Bash",
      field: "command",
      pattern: commandPattern(
        "gh",
        String.raw`pr[\s-]+(?:create|ready|comment|review|edit|close|reopen)|issue[\s-]+(?:create|comment|edit|close|reopen)|repo[\s-]+(?:create|delete|edit)|workflow[\s-]+run`,
      ),
      reason: "GitHub への書き込みは外部に見える",
    },
    {
      id: "gh-api-write",
      risk: "external-contract",
      tool: "Bash",
      field: "command",
      pattern: String.raw`${COMMAND_PREFIX}gh[\s-]+api${WORD_END}${SAME_COMMAND}\s(?:-X|--method)[\s=]*(?:POST|PUT|PATCH|DELETE)${WORD_END}`,
      reason: "GitHub API への書き込みは外部に見える",
    },
    {
      id: "http-write",
      risk: "external-publish",
      tool: "Bash",
      field: "command",
      pattern: commandFlagPattern(
        "curl|wget|http|xh",
        String.raw`-X[\s=]*(?:POST|PUT|PATCH|DELETE)|--request[\s=]*(?:POST|PUT|PATCH|DELETE)|--data(?:-raw|-binary|-urlencode|-ascii)?|-d|--upload-file|-T|--form|-F`,
      ),
      reason: "外部への送信は取り消せない",
    },
    {
      id: "credential-command",
      risk: "credential",
      tool: "Bash",
      field: "command",
      pattern: anyOf(
        commandPattern("op", "read|item|signin|inject|document"),
        commandPattern(
          "security",
          String.raw`find-generic-password|find-internet-password|dump-keychain`,
        ),
        String.raw`${COMMAND_PREFIX}gh[\s-]+auth[\s-]+token${WORD_END}`,
        commandPattern("aws", "sts"),
        commandPattern("gcloud", "auth"),
      ),
      reason: "資格情報の読み出しは user の判断",
    },
    {
      id: "credential-path-command",
      risk: "credential",
      tool: "Bash",
      field: "command",
      pattern: credentialPathPattern(),
      reason: "資格情報を含むパスへのアクセスは user の判断",
    },
    {
      id: "credential-path-argument",
      risk: "credential",
      tool: "*",
      field: "paths",
      pattern: credentialPathPattern(),
      reason: "資格情報を含むパスへのアクセスは user の判断",
    },
    {
      id: "infrastructure-deploy",
      risk: "deploy",
      tool: "Bash",
      field: "command",
      pattern: anyOf(
        commandPattern("terraform|tofu", "apply|destroy"),
        commandPattern("kubectl", "apply|delete|rollout|patch|replace"),
        commandPattern("helm", "install|upgrade|uninstall|rollback"),
        commandPattern("flyctl|fly", "deploy"),
        commandPattern("wrangler", "deploy|publish"),
        commandPattern("serverless|sls", "deploy"),
        commandPattern("vercel", "deploy"),
        commandFlagPattern("vercel", String.raw`--prod`),
        String.raw`${COMMAND_PREFIX}(?:gcloud|aws|az)[\s-]+${SAME_COMMAND}\sdeploy${WORD_END}`,
      ),
      reason: "デプロイは外部環境を変える",
    },
    {
      id: "chezmoi-apply",
      risk: "deploy",
      tool: "Bash",
      field: "command",
      pattern: commandPattern("chezmoi", "apply|init|update|destroy|forget"),
      reason: "chezmoi apply はワークツリーの外（HOME）を書き換える",
    },
    {
      id: "database-migration",
      risk: "data-migration",
      tool: "Bash",
      field: "command",
      pattern: String.raw`${COMMAND_PREFIX}(?:prisma[\s-]+migrate|(?:rails|rake)[\s-]+db:migrate|alembic[\s-]+(?:upgrade|downgrade)|drizzle-kit[\s-]+(?:push|migrate)|supabase[\s-]+db[\s-]+(?:push|reset)|sqlx[\s-]+migrate|atlas[\s-]+migrate[\s-]+apply|knex[\s-]+migrate|artisan[\s-]+migrate|goose[\s-]+(?:up|down)|flyway[\s-]+(?:migrate|clean)|dbmate[\s-]+(?:up|down))${WORD_END}`,
      reason: "マイグレーションはデータを不可逆に変える",
    },
    {
      id: "approval-channel-command",
      risk: "approval-channel",
      tool: "Bash",
      field: "command",
      pattern: anyOf(
        approvalChannelPathPattern(),
        String.raw`${COMMAND_PREFIX}(?:fh|frontier-harness)[\s-]+approve`,
      ),
      reason: "承認チャネル自身への書き込みは自己承認を成立させうる",
    },
    {
      id: "approval-channel-argument",
      risk: "approval-channel",
      tool: "*",
      field: "paths",
      pattern: approvalChannelPathPattern(),
      reason: "承認チャネル自身への書き込みは自己承認を成立させうる",
    },
  ].map((rule) => Object.freeze(rule)),
);

export const BASELINE_RULE_IDS = Object.freeze(
  new Set(BASELINE_APPROVAL_RULES.map((rule) => rule.id)),
);
