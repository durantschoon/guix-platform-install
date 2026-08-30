# Stage 37 — Telemetry: Persist Rolling Latency & Metrics History Across Daemon Restarts

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

In `gipsd`, latency histograms and event counters are in-memory since startup. When the daemon restarts, counters reset to zero and the telemetry trend view on `/dashboard` resets.

`docs/TODO.md` line 156 states:

- *"Persist a rolling latency history across restarts. Histograms are in-memory and cumulative since startup, so the dashboard's trend view resets when the daemon does."*

Persisting periodic metrics snapshots into SQLite (`metrics_history` table) ensures:

1. Historical performance trends and scrape counters survive daemon reboots, crashes, and upgrades.
2. Operators and dashboard frontends can query historical latency percentiles and query distributions via `GET /metrics/history`.
3. A rolling window (e.g. 7 days or 1000 snapshots) bounds database storage growth automatically.

## The Change

1. **Database Schema & Methods in `components/gips-db`**:
   - In `Database::connect`, create table `metrics_history (id INTEGER PRIMARY KEY AUTOINCREMENT, recorded_at INTEGER NOT NULL, snapshot_json TEXT NOT NULL)` and index `idx_metrics_history_recorded_at`.
   - Add `Database::record_metrics_history(&self, recorded_at: i64, snapshot_json: &str) -> Result<()>` with automated retention pruning (pruning entries older than 7 days).
   - Add `Database::get_metrics_history(&self, limit: i64) -> Result<Vec<MetricsHistoryRecord>>`.
   - Add unit tests for metrics history recording and pruning.
2. **HTTP API in `components/gips-http`**:
   - Add authenticated route `GET /metrics/history` returning `Vec<MetricsHistoryRecord>`.
   - Add helper `record_current_metrics(&state)` that snapshots `state.metrics` (and `mirror_metrics`) and stores it in the database.
   - Add unit tests for `GET /metrics/history`.
3. **Background Periodic Flusher in `gipsd/src/main.rs`**:
   - Spawn a background task in `gipsd` that records a metrics snapshot periodically (e.g. every 5 minutes) and once at startup.
4. **CLI & Scheme Parity in `gips/src/main.rs`, `scheme/gips/api.scm`, `test_api.scm`**:
   - Add `gips metrics history [--limit <N>]` CLI command.
   - Add `(gips-metrics-history #:limit ...)` in `scheme/gips/api.scm` and unit test in `test_api.scm`.
5. **Docs**:
   - Mark rolling latency history item as completed in `docs/TODO.md`.

## Allowed Files Whitelist

- `components/gips-db/src/lib.rs`
- `components/gips-http/src/lib.rs`
- `gipsd/src/main.rs`
- `gips/src/main.rs`
- `scheme/gips/api.scm`
- `test_api.scm`
- `docs/TODO.md`

## Enumerated Tests

1. **Database history recording & pruning**: `record_metrics_history` persists snapshot JSON with timestamps and prunes aged records beyond the retention window.
2. **Authenticated endpoint `GET /metrics/history`**: Valid bearer token receives recorded history in descending order; unauthenticated requests are refused with 401.
3. **Scheme & CLI parity**: `gips metrics history` and `(gips-metrics-history)` query the endpoint and decode the history payloads.

## Definition of Done

- All enumerated tests implemented and green.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.
- `docs/TODO.md` updated.

## Commit Message

`[stage-37] feat: persist rolling metrics history across restarts and add GET /metrics/history endpoint`
