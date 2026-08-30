# Stage 36 — Telemetry & Monitoring (Mirror Worker Metrics Export & Prometheus Text Format Exposition)

<!-- markdownlint-disable MD013 -->

## Motivation (measured)

`gipsd` provides instrumentation via `GET /metrics` (`gips.metrics.v1`), but:

1. `start_mirror_worker` builds its own telemetry registry that nothing reads or exports, preventing operators from monitoring background feed synchronization performance and mirror pin operations.
2. The `/metrics` endpoint only renders JSON format. Standard monitoring infrastructure (such as Prometheus scrapers and alerting systems) expects the Prometheus text exposition format (`text/plain; version=0.0.4`).

`docs/TODO.md` documents both items:

- *"Export the mirror worker's metrics too — `start_mirror_worker` builds its own registry that nothing reads (kept separate so background passes do not distort the serving numbers)."*
- *"Optionally add a Prometheus text rendering of `/metrics` for operators who already run a scraper; the JSON schema is the only supported format today."*

> **Anchor by `fn`/struct name + quoted code, not line number.**

## The Change

1. **Prometheus Text Renderer in `components/gips-http/src/metrics.rs`**:
   - Implement `MetricsSnapshot::to_prometheus_text(&self, prefix: &str) -> String` to serialize counters, histograms (with cumulative bucket counts and sum/count), and uptime gauges into standard Prometheus text exposition format (`text/plain; version=0.0.4`).
   - Add unit tests validating the Prometheus text serialization format and bucket calculations.
2. **Mirror Worker Telemetry Export**:
   - Add `mirror_metrics: Arc<metrics::Metrics>` to `AppState`, populated on startup.
   - Update `start_mirror_worker` to record background passes into this shared `mirror_metrics` registry (kept distinct with separate prefix/sub-schema so background synchronization does not distort serving latencies).
   - Include `mirror: Option<Box<MetricsSnapshot>>` in `MetricsSnapshot` JSON, and include `gips_mirror_*` metrics series in Prometheus text output.
3. **Content Negotiation on `GET /metrics` in `components/gips-http`**:
   - Inspect `Accept` header or `?format=prometheus` query parameter.
   - When requested with `Accept: text/plain` (or `text/plain; version=0.0.4` or `?format=prometheus`), respond with `Content-Type: text/plain; version=0.0.4; charset=utf-8` containing the Prometheus text representation.
   - When requested without `Accept: text/plain` (e.g. `Accept: application/json` or default), respond with `Content-Type: application/json` containing `MetricsSnapshot`.
4. **Tests & Docs**:
   - Add tests for `GET /metrics` with `Accept: text/plain` returning valid Prometheus text.
   - Add tests for `GET /metrics` with `Accept: application/json` returning JSON with mirror telemetry included.
   - Update `docs/TODO.md`.

## Non-goals (do not touch)

- No external metrics dependencies (`prometheus` or `opentelemetry` crates); keep the lightweight, zero-allocation atomic metric model.
- No changes to existing JSON schema fields for serving metrics.

## Allowed Files Whitelist

- `components/gips-http/src/metrics.rs`
- `components/gips-http/src/lib.rs`
- `gipsd/src/main.rs`
- `docs/TODO.md`

## Enumerated Tests

1. **Prometheus text rendering**: `MetricsSnapshot::to_prometheus_text` emits valid Prometheus `# HELP`, `# TYPE`, counters, histogram buckets, and gauge lines.
2. **Content negotiation for `/metrics`**: `GET /metrics` with `Accept: text/plain` returns Prometheus text format; `GET /metrics` with `Accept: application/json` returns JSON.
3. **Mirror metrics isolation and export**: `mirror_metrics` records mirror passes and is exported under `gips_mirror_` namespace without mutating serving metrics counters.

## Definition of Done

- All enumerated tests implemented and green.
- Verification gates pass in order: adversarial diff audit, `cargo check`, `just fmt-check`, `just test`, `just audit`, `just lint`, `just scheme-test`.
- `docs/TODO.md` updated.

## Commit Message

`[stage-36] feat: export mirror worker metrics and add Prometheus text format endpoint`
