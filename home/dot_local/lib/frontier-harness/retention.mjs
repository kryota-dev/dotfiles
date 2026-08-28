// 保持期間の名前付き定数と cutoff 計算の SSOT。
// 以前は cli.mjs が `days * 24 * 60 * 60 * 1000` を直書きしており、
// しかも raw 側しか計算していなかったため aggregateTelemetryDays が死に設定になっていた。

export const MILLISECONDS_PER_DAY = 24 * 60 * 60 * 1000;

// 出荷 config（home/dot_config/frontier-harness/config.json）が満たすべき既定値。
// 運用者は config で上書きできるが、出荷値がこの定数から drift していないことを
// テストで突き合わせる（値が 2 箇所にあるまま静かにずれるのを防ぐ）。
export const DEFAULT_RAW_ARTIFACT_RETENTION_DAYS = 30;
export const DEFAULT_AGGREGATE_TELEMETRY_RETENTION_DAYS = 180;

function cutoffFrom(now, days) {
  return new Date(now.getTime() - days * MILLISECONDS_PER_DAY).toISOString();
}

// raw（evidence と実行系レコード）と集約テレメトリの 2 クラス分の cutoff を返す。
// approvals はどちらのクラスにも属さない（承認は監査証跡なので保持期間で消さない）。
export function retentionCutoffs(retention, now) {
  if (!(now instanceof Date) || Number.isNaN(now.getTime())) {
    throw new TypeError("retention cutoffs require a valid Date");
  }
  return {
    rawCutoff: cutoffFrom(now, retention.rawArtifactsDays),
    telemetryCutoff: cutoffFrom(now, retention.aggregateTelemetryDays),
  };
}
