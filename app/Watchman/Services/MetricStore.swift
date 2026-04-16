import Foundation
import SQLite3

/// Thread-safe SQLite-backed store for per-worker metric samples.
///
/// Ingestion is fire-and-forget from `MetricsPoller`; aggregation queries run
/// on a background executor so the UI never blocks.
actor MetricStore {
    static let shared = MetricStore()

    private var db: OpaquePointer?
    private var insertStmt: OpaquePointer?

    private let dbURL: URL
    private static let retentionDays: Double = 90
    private static let idleThresholdPct: Double = 5.0
    /// Treat gaps larger than this as missing data (ignore their energy
    /// contribution) — avoids inflating totals after suspend/reboot.
    private static let maxGapSeconds: Double = 30.0

    private static let SQLITE_TRANSIENT = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )

    init() {
        let fm = FileManager.default
        let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = (appSupport ?? fm.temporaryDirectory)
            .appendingPathComponent("Watchman", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dbURL = dir.appendingPathComponent("power.sqlite")

        openAndMigrate()
        schedulePurge()
    }

    deinit {
        if let stmt = insertStmt { sqlite3_finalize(stmt) }
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Ingest

    func ingest(_ sample: MetricSample) {
        if sample.cpuW == nil && sample.gpuW == nil { return }
        guard let stmt = insertStmt else { return }

        sqlite3_reset(stmt)
        sqlite3_bind_int64(stmt, 1, Int64(sample.timestamp.timeIntervalSince1970))
        sample.hostname.withCString { ptr in
            sqlite3_bind_text(stmt, 2, ptr, -1, Self.SQLITE_TRANSIENT)
        }
        if let cpu = sample.cpuW { sqlite3_bind_double(stmt, 3, cpu) }
        else { sqlite3_bind_null(stmt, 3) }
        if let gpu = sample.gpuW { sqlite3_bind_double(stmt, 4, gpu) }
        else { sqlite3_bind_null(stmt, 4) }
        sqlite3_bind_double(stmt, 5, sample.cpuUsagePct)
        sqlite3_bind_double(stmt, 6, sample.gpuUsagePct)
        sqlite3_step(stmt)
    }

    // MARK: - Query

    /// Returns bucketed aggregates for the selected host and window.
    /// If `hostname` is nil, sums across all hosts.
    func aggregate(hostname: String?, window: PowerWindow) -> [PowerAggregate] {
        guard let db = db else { return [] }
        let since = Date().addingTimeInterval(-window.lookback)
        let sinceTs = Int64(since.timeIntervalSince1970)

        let hostFilter = hostname == nil ? "" : "AND hostname = ?"
        let sql = """
        WITH filtered AS (
            SELECT timestamp, hostname,
                   COALESCE(cpu_w, 0) AS cpu_w,
                   COALESCE(gpu_w, 0) AS gpu_w,
                   cpu_w IS NULL AS cpu_null,
                   gpu_w IS NULL AS gpu_null,
                   cpu_pct, gpu_pct
            FROM power_samples
            WHERE timestamp >= ? \(hostFilter)
        ),
        windowed AS (
            SELECT *,
                   timestamp - LAG(timestamp) OVER (PARTITION BY hostname ORDER BY timestamp) AS dt
            FROM filtered
        )
        SELECT
            strftime(?, timestamp, 'unixepoch', 'localtime') AS bucket,
            MIN(timestamp) AS bucket_ts,
            SUM(CASE WHEN dt IS NULL OR dt > ? THEN 0
                     ELSE (cpu_w + gpu_w) * dt / 3600.0 END) AS energy_wh,
            AVG(CASE WHEN cpu_null THEN NULL ELSE cpu_w END) AS mean_cpu_w,
            AVG(CASE WHEN gpu_null THEN NULL ELSE gpu_w END) AS mean_gpu_w,
            MAX(cpu_w + gpu_w) AS peak_w,
            MIN(cpu_w + gpu_w) AS min_w,
            SUM(CASE WHEN dt IS NULL OR dt > ? THEN 0
                     WHEN cpu_pct < ? AND gpu_pct < ? THEN (cpu_w + gpu_w) * dt / 3600.0
                     ELSE 0 END) AS idle_wh,
            SUM(CASE WHEN dt IS NULL OR dt > ? THEN 0
                     WHEN NOT (cpu_pct < ? AND gpu_pct < ?) THEN (cpu_w + gpu_w) * dt / 3600.0
                     ELSE 0 END) AS active_wh
        FROM windowed
        GROUP BY bucket
        ORDER BY bucket_ts ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        sqlite3_bind_int64(stmt, idx, sinceTs); idx += 1
        if let host = hostname {
            host.withCString { ptr in
                sqlite3_bind_text(stmt, idx, ptr, -1, Self.SQLITE_TRANSIENT)
            }
            idx += 1
        }
        window.bucketFormat.withCString { ptr in
            sqlite3_bind_text(stmt, idx, ptr, -1, Self.SQLITE_TRANSIENT)
        }
        idx += 1
        sqlite3_bind_double(stmt, idx, Self.maxGapSeconds); idx += 1
        sqlite3_bind_double(stmt, idx, Self.maxGapSeconds); idx += 1
        sqlite3_bind_double(stmt, idx, Self.idleThresholdPct); idx += 1
        sqlite3_bind_double(stmt, idx, Self.idleThresholdPct); idx += 1
        sqlite3_bind_double(stmt, idx, Self.maxGapSeconds); idx += 1
        sqlite3_bind_double(stmt, idx, Self.idleThresholdPct); idx += 1
        sqlite3_bind_double(stmt, idx, Self.idleThresholdPct); idx += 1

        var rows: [PowerAggregate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let bucketTs = sqlite3_column_int64(stmt, 1)
            let energyWh = sqlite3_column_double(stmt, 2)
            let meanCpuW = sqlite3_column_double(stmt, 3)
            let meanGpuW = sqlite3_column_double(stmt, 4)
            let peakW = sqlite3_column_double(stmt, 5)
            let minW = sqlite3_column_double(stmt, 6)
            let idleWh = sqlite3_column_double(stmt, 7)
            let activeWh = sqlite3_column_double(stmt, 8)
            rows.append(PowerAggregate(
                bucketStart: Date(timeIntervalSince1970: TimeInterval(bucketTs)),
                energyWh: energyWh,
                meanCpuW: meanCpuW,
                meanGpuW: meanGpuW,
                peakW: peakW,
                minW: minW,
                idleWh: idleWh,
                activeWh: activeWh
            ))
        }
        return rows
    }

    func summary(hostname: String?, window: PowerWindow) -> PowerSummary {
        let buckets = aggregate(hostname: hostname, window: window)
        if buckets.isEmpty { return .empty }
        let totalWh = buckets.reduce(0.0) { $0 + $1.energyWh }
        let idleWh = buckets.reduce(0.0) { $0 + $1.idleWh }
        let activeWh = buckets.reduce(0.0) { $0 + $1.activeWh }
        let meanW = buckets.reduce(0.0) { $0 + $1.meanTotalW } / Double(buckets.count)
        let peakW = buckets.map(\.peakW).max() ?? 0
        let minW = buckets.map(\.minW).min() ?? 0
        return PowerSummary(
            totalKwh: totalWh / 1000.0,
            meanW: meanW,
            peakW: peakW,
            minW: minW,
            idleKwh: idleWh / 1000.0,
            activeKwh: activeWh / 1000.0
        )
    }

    // MARK: - Private

    private func openAndMigrate() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            db = nil
            return
        }
        runRaw("PRAGMA journal_mode=WAL;")
        runRaw("PRAGMA synchronous=NORMAL;")
        runRaw("""
        CREATE TABLE IF NOT EXISTS power_samples (
            timestamp INTEGER NOT NULL,
            hostname  TEXT    NOT NULL,
            cpu_w     REAL,
            gpu_w     REAL,
            cpu_pct   REAL NOT NULL,
            gpu_pct   REAL NOT NULL,
            PRIMARY KEY (hostname, timestamp)
        );
        """)
        runRaw("CREATE INDEX IF NOT EXISTS idx_host_ts ON power_samples(hostname, timestamp);")

        let insertSQL = """
        INSERT OR REPLACE INTO power_samples
            (timestamp, hostname, cpu_w, gpu_w, cpu_pct, gpu_pct)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil)
    }

    private func runRaw(_ sql: String) {
        guard let db = db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func schedulePurge() {
        Task.detached { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000) // 1 hour
                await self?.purgeOldSamples()
            }
        }
    }

    private func purgeOldSamples() {
        guard let db = db else { return }
        let cutoff = Int64(
            Date().addingTimeInterval(-Self.retentionDays * 86400).timeIntervalSince1970
        )
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(
            db, "DELETE FROM power_samples WHERE timestamp < ?;", -1, &stmt, nil
        ) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, cutoff)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }
}
