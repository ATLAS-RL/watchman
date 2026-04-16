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
        guard let stmt = insertStmt else { return }

        sqlite3_reset(stmt)
        sqlite3_bind_int64(stmt, 1, Int64(sample.timestamp.timeIntervalSince1970))
        sample.hostname.withCString { ptr in
            sqlite3_bind_text(stmt, 2, ptr, -1, Self.SQLITE_TRANSIENT)
        }
        bindOptionalDouble(stmt, 3, sample.cpuW)
        bindOptionalDouble(stmt, 4, sample.gpuW)
        sqlite3_bind_double(stmt, 5, sample.cpuUsagePct)
        sqlite3_bind_double(stmt, 6, sample.gpuUsagePct)
        bindOptionalDouble(stmt, 7, sample.gpuTempC)
        bindOptionalDouble(stmt, 8, sample.cpuTempC)
        bindOptionalUInt64(stmt, 9, sample.vramUsedMb)
        bindOptionalUInt64(stmt, 10, sample.vramTotalMb)
        bindOptionalUInt64(stmt, 11, sample.memUsedMb)
        bindOptionalUInt64(stmt, 12, sample.memTotalMb)
        bindOptionalUInt64(stmt, 13, sample.diskUsedGb)
        bindOptionalUInt64(stmt, 14, sample.diskTotalGb)
        bindOptionalUInt64(stmt, 15, sample.diskReadBps)
        bindOptionalUInt64(stmt, 16, sample.diskWriteBps)
        bindOptionalUInt64(stmt, 17, sample.netRxBps)
        bindOptionalUInt64(stmt, 18, sample.netTxBps)
        sqlite3_step(stmt)
    }

    private func bindOptionalDouble(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Double?) {
        if let v = value { sqlite3_bind_double(stmt, idx, v) }
        else { sqlite3_bind_null(stmt, idx) }
    }

    private func bindOptionalUInt64(_ stmt: OpaquePointer?, _ idx: Int32, _ value: UInt64?) {
        if let v = value { sqlite3_bind_int64(stmt, idx, Int64(bitPattern: v)) }
        else { sqlite3_bind_null(stmt, idx) }
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
            FROM metric_samples
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

    // MARK: - Gauge aggregates

    func gpuAggregate(hostname: String?, window: PowerWindow) -> [GpuAggregate] {
        let sql = """
        SELECT strftime(?, timestamp, 'unixepoch', 'localtime') AS bucket,
               MIN(timestamp) AS bucket_ts,
               AVG(gpu_pct)    AS mean_gpu_pct,
               MAX(gpu_pct)    AS peak_gpu_pct,
               AVG(gpu_temp_c) AS mean_gpu_temp,
               MAX(gpu_temp_c) AS peak_gpu_temp,
               AVG(CASE WHEN vram_total_mb > 0 THEN 100.0 * vram_used_mb / vram_total_mb END) AS mean_vram_pct,
               MAX(CASE WHEN vram_total_mb > 0 THEN 100.0 * vram_used_mb / vram_total_mb END) AS peak_vram_pct
        FROM metric_samples
        WHERE timestamp >= ? \(hostFilter(hostname))
        GROUP BY bucket
        ORDER BY bucket_ts ASC;
        """
        return runAggregate(sql: sql, hostname: hostname, window: window) { stmt in
            GpuAggregate(
                bucketStart: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1))),
                meanGpuPct: sqlite3_column_double(stmt, 2),
                peakGpuPct: sqlite3_column_double(stmt, 3),
                meanGpuTemp: sqlite3_column_double(stmt, 4),
                peakGpuTemp: sqlite3_column_double(stmt, 5),
                meanVramPct: sqlite3_column_double(stmt, 6),
                peakVramPct: sqlite3_column_double(stmt, 7)
            )
        }
    }

    func systemAggregate(hostname: String?, window: PowerWindow) -> [SystemAggregate] {
        let sql = """
        SELECT strftime(?, timestamp, 'unixepoch', 'localtime') AS bucket,
               MIN(timestamp) AS bucket_ts,
               AVG(cpu_pct) AS mean_cpu_pct,
               MAX(cpu_pct) AS peak_cpu_pct,
               AVG(CASE WHEN mem_total_mb > 0 THEN 100.0 * mem_used_mb / mem_total_mb END) AS mean_ram_pct,
               MAX(CASE WHEN mem_total_mb > 0 THEN 100.0 * mem_used_mb / mem_total_mb END) AS peak_ram_pct,
               AVG(cpu_temp_c) AS mean_cpu_temp,
               MAX(cpu_temp_c) AS peak_cpu_temp
        FROM metric_samples
        WHERE timestamp >= ? \(hostFilter(hostname))
        GROUP BY bucket
        ORDER BY bucket_ts ASC;
        """
        return runAggregate(sql: sql, hostname: hostname, window: window) { stmt in
            SystemAggregate(
                bucketStart: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1))),
                meanCpuPct: sqlite3_column_double(stmt, 2),
                peakCpuPct: sqlite3_column_double(stmt, 3),
                meanRamPct: sqlite3_column_double(stmt, 4),
                peakRamPct: sqlite3_column_double(stmt, 5),
                meanCpuTemp: sqlite3_column_double(stmt, 6),
                peakCpuTemp: sqlite3_column_double(stmt, 7)
            )
        }
    }

    func diskAggregate(hostname: String?, window: PowerWindow) -> [DiskAggregate] {
        let sql = """
        SELECT strftime(?, timestamp, 'unixepoch', 'localtime') AS bucket,
               MIN(timestamp) AS bucket_ts,
               AVG(CASE WHEN disk_total_gb > 0 THEN 100.0 * disk_used_gb / disk_total_gb END) AS mean_disk_pct,
               MAX(CASE WHEN disk_total_gb > 0 THEN 100.0 * disk_used_gb / disk_total_gb END) AS peak_disk_pct,
               AVG(disk_used_gb)  AS mean_used_gb,
               AVG(disk_total_gb) AS mean_total_gb
        FROM metric_samples
        WHERE timestamp >= ? \(hostFilter(hostname))
        GROUP BY bucket
        ORDER BY bucket_ts ASC;
        """
        return runAggregate(sql: sql, hostname: hostname, window: window) { stmt in
            DiskAggregate(
                bucketStart: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1))),
                meanDiskPct: sqlite3_column_double(stmt, 2),
                peakDiskPct: sqlite3_column_double(stmt, 3),
                meanUsedGb: sqlite3_column_double(stmt, 4),
                meanTotalGb: sqlite3_column_double(stmt, 5)
            )
        }
    }

    // MARK: - Raw CSV export

    /// Stream every row in the selected range to `destination` as CSV. The
    /// file is written through a `FileHandle` so a 90-day export (millions
    /// of rows) doesn't materialise in memory. Returns the number of data
    /// rows written (excluding the header).
    func exportRawCsv(
        workers: [String]?,
        from: Date,
        to: Date,
        destination: URL
    ) throws -> Int {
        guard let db = db else {
            throw MetricsExporter.Failure.storeUnavailable
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw MetricsExporter.Failure.writeFailed("could not create file")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        // Header
        let header = "timestamp,hostname,cpu_w,gpu_w,cpu_pct,gpu_pct,gpu_temp_c,cpu_temp_c,vram_used_mb,vram_total_mb,mem_used_mb,mem_total_mb,disk_used_gb,disk_total_gb,disk_read_bps,disk_write_bps,net_rx_bps,net_tx_bps\n"
        try handle.write(contentsOf: Data(header.utf8))

        // Build the SELECT with optional IN (...) filter for hostnames.
        var sql = """
        SELECT timestamp, hostname, cpu_w, gpu_w, cpu_pct, gpu_pct,
               gpu_temp_c, cpu_temp_c, vram_used_mb, vram_total_mb,
               mem_used_mb, mem_total_mb, disk_used_gb, disk_total_gb,
               disk_read_bps, disk_write_bps, net_rx_bps, net_tx_bps
        FROM metric_samples
        WHERE timestamp BETWEEN ? AND ?
        """
        if let workers, !workers.isEmpty {
            let placeholders = Array(repeating: "?", count: workers.count).joined(separator: ",")
            sql += " AND hostname IN (\(placeholders))"
        }
        sql += " ORDER BY hostname, timestamp;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MetricsExporter.Failure.writeFailed("prepare failed")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(from.timeIntervalSince1970))
        sqlite3_bind_int64(stmt, 2, Int64(to.timeIntervalSince1970))
        if let workers {
            for (i, w) in workers.enumerated() {
                w.withCString { ptr in
                    sqlite3_bind_text(stmt, Int32(3 + i), ptr, -1, Self.SQLITE_TRANSIENT)
                }
            }
        }

        // 16 KiB batch buffer: flushing after each row shows up as a
        // noticeable syscall cost on big exports.
        var buffer = Data()
        buffer.reserveCapacity(16 * 1024)
        var rowCount = 0

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_int64(stmt, 0)
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            let hostPtr = sqlite3_column_text(stmt, 1)
            let host = hostPtr.map { String(cString: $0) } ?? ""

            var fields: [String] = []
            fields.reserveCapacity(18)
            fields.append(iso.string(from: date))
            fields.append(csvEscape(host))
            // cpu_w, gpu_w (nullable REAL)
            fields.append(nullableRealColumn(stmt, 2))
            fields.append(nullableRealColumn(stmt, 3))
            // cpu_pct, gpu_pct (non-null REAL)
            fields.append(realColumn(stmt, 4))
            fields.append(realColumn(stmt, 5))
            // gpu_temp_c, cpu_temp_c (nullable REAL)
            fields.append(nullableRealColumn(stmt, 6))
            fields.append(nullableRealColumn(stmt, 7))
            // vram_used_mb .. net_tx_bps (nullable INTEGER)
            for col: Int32 in 8...17 {
                fields.append(nullableIntColumn(stmt, col))
            }

            let line = fields.joined(separator: ",") + "\n"
            buffer.append(contentsOf: line.utf8)
            rowCount += 1

            if buffer.count >= 16 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }

        return rowCount
    }

    private func realColumn(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return "" }
        let v = sqlite3_column_double(stmt, idx)
        return formatReal(v)
    }

    private func nullableRealColumn(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return "" }
        return formatReal(sqlite3_column_double(stmt, idx))
    }

    private func nullableIntColumn(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return "" }
        return String(sqlite3_column_int64(stmt, idx))
    }

    private func formatReal(_ v: Double) -> String {
        if v.rounded() == v && abs(v) < 1e15 {
            return String(Int64(v))
        }
        return String(format: "%.3f", v)
    }

    /// Quote a CSV field if it contains commas, quotes, or newlines.
    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }

    // MARK: - Aggregate helper

    /// Shared runner for the three gauge aggregates. Binds the bucket format,
    /// timestamp lower bound, and optional hostname — all gauge queries share
    /// this exact binding order.
    private func runAggregate<T>(
        sql: String,
        hostname: String?,
        window: PowerWindow,
        decode: (OpaquePointer?) -> T
    ) -> [T] {
        guard let db = db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let sinceTs = Int64(Date().addingTimeInterval(-window.lookback).timeIntervalSince1970)
        window.bucketFormat.withCString { ptr in
            sqlite3_bind_text(stmt, 1, ptr, -1, Self.SQLITE_TRANSIENT)
        }
        sqlite3_bind_int64(stmt, 2, sinceTs)
        if let host = hostname {
            host.withCString { ptr in
                sqlite3_bind_text(stmt, 3, ptr, -1, Self.SQLITE_TRANSIENT)
            }
        }

        var rows: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(decode(stmt))
        }
        return rows
    }

    private func hostFilter(_ hostname: String?) -> String {
        hostname == nil ? "" : "AND hostname = ?"
    }

    // MARK: - Private

    private func openAndMigrate() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            db = nil
            return
        }
        runRaw("PRAGMA journal_mode=WAL;")
        runRaw("PRAGMA synchronous=NORMAL;")

        // Also re-enter migration when user_version claims v2 but a stray
        // `power_samples` table is still around — early builds of this
        // feature could leave the DB in that state.
        let version = readUserVersion()
        if version < 3 || tableExists("power_samples") {
            migrate(from: version)
        }

        let insertSQL = """
        INSERT OR REPLACE INTO metric_samples
            (timestamp, hostname, cpu_w, gpu_w, cpu_pct, gpu_pct,
             gpu_temp_c, cpu_temp_c, vram_used_mb, vram_total_mb,
             mem_used_mb, mem_total_mb, disk_used_gb, disk_total_gb,
             disk_read_bps, disk_write_bps, net_rx_bps, net_tx_bps)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil)
    }

    private func readUserVersion() -> Int {
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// Brings the DB to the current version (v3) regardless of the previous
    /// state. Driven by table presence rather than `user_version` alone, so
    /// we can recover from an earlier buggy migration that created an empty
    /// `metric_samples` next to the legacy `power_samples` table without
    /// merging them.
    private func migrate(from version: Int) {
        runRaw("BEGIN;")
        defer { runRaw("COMMIT;") }

        let legacy = tableExists("power_samples")
        let modern = tableExists("metric_samples")

        if legacy && modern {
            // Recovery path: merge legacy rows into the new table (using
            // NULL for the new columns) and drop the legacy table. Stale
            // rows already present in `metric_samples` are preserved via
            // INSERT OR IGNORE, since (hostname, timestamp) is the key.
            runRaw("""
            INSERT OR IGNORE INTO metric_samples
                (timestamp, hostname, cpu_w, gpu_w, cpu_pct, gpu_pct)
            SELECT timestamp, hostname, cpu_w, gpu_w, cpu_pct, gpu_pct
            FROM power_samples;
            """)
            runRaw("DROP TABLE power_samples;")
        } else if legacy {
            // v1 upgrade: rename the table, then add the new columns.
            runRaw("ALTER TABLE power_samples RENAME TO metric_samples;")
        } else if !modern {
            // Fresh install.
            runRaw("""
            CREATE TABLE metric_samples (
                timestamp      INTEGER NOT NULL,
                hostname       TEXT    NOT NULL,
                cpu_w          REAL,
                gpu_w          REAL,
                cpu_pct        REAL    NOT NULL,
                gpu_pct        REAL    NOT NULL,
                gpu_temp_c     REAL,
                cpu_temp_c     REAL,
                vram_used_mb   INTEGER,
                vram_total_mb  INTEGER,
                mem_used_mb    INTEGER,
                mem_total_mb   INTEGER,
                disk_used_gb   INTEGER,
                disk_total_gb  INTEGER,
                disk_read_bps  INTEGER,
                disk_write_bps INTEGER,
                net_rx_bps     INTEGER,
                net_tx_bps     INTEGER,
                PRIMARY KEY (hostname, timestamp)
            );
            """)
        }

        // ADD COLUMN on an already-present column is a no-op here because
        // runRaw swallows the error. Safe to call on every migration path.
        for col in [
            "gpu_temp_c     REAL",
            "cpu_temp_c     REAL",
            "vram_used_mb   INTEGER",
            "vram_total_mb  INTEGER",
            "mem_used_mb    INTEGER",
            "mem_total_mb   INTEGER",
            "disk_used_gb   INTEGER",
            "disk_total_gb  INTEGER",
            "disk_read_bps  INTEGER",
            "disk_write_bps INTEGER",
            "net_rx_bps     INTEGER",
            "net_tx_bps     INTEGER",
        ] {
            runRaw("ALTER TABLE metric_samples ADD COLUMN \(col);")
        }

        runRaw("DROP INDEX IF EXISTS idx_host_ts;")
        runRaw("CREATE INDEX IF NOT EXISTS idx_host_ts ON metric_samples(hostname, timestamp);")
        runRaw("PRAGMA user_version = 3;")
    }

    private func tableExists(_ name: String) -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        name.withCString { ptr in
            sqlite3_bind_text(stmt, 1, ptr, -1, Self.SQLITE_TRANSIENT)
        }
        return sqlite3_step(stmt) == SQLITE_ROW
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
            db, "DELETE FROM metric_samples WHERE timestamp < ?;", -1, &stmt, nil
        ) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, cutoff)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }
}
