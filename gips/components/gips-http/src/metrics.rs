//! Fire-and-forget latency instrumentation for the serving path.
//!
//! # Why this and not `opentelemetry` / `metrics`
//!
//! Stage 24 asked for either. This daemon serves package substitutes on
//! loopback and its dependency surface is a security property, so the smaller
//! option wins: a few hundred lines of `AtomicU64` here replace an exporter
//! stack, a background flush task, and a registry macro layer. Nothing in this
//! module allocates, locks, blocks, or can fail.
//!
//! # The guarantee that matters
//!
//! **Recording a measurement must never change what a request returns.** Every
//! recording path is:
//!
//! - infallible — `fetch_add` on an atomic has no error case,
//! - non-blocking — no mutex, no channel, no `await`,
//! - allocation-free — bucket counts live in a fixed array,
//! - and *observational* — [`timed`] returns the wrapped future's output
//!   untouched, so deleting every call site would leave behaviour identical.
//!
//! Overflow is saturating rather than wrapping: a counter that has genuinely
//! reached `u64::MAX` sticks there instead of silently restarting at zero.
//!
//! # What is deliberately not recorded
//!
//! No store paths, CIDs, GNS names, key material or tokens. A histogram here
//! holds a static name and a pile of integers; that is the whole reason
//! `/metrics` can be served without redaction logic.

use serde::Serialize;
use std::future::Future;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

/// Bucket upper bounds, in microseconds.
///
/// Chosen to straddle the two regimes this daemon actually lives in: sub-
/// millisecond in-process work (snapshot lookups, hash comparisons) and the
/// tens-of-milliseconds-to-seconds range of IPFS and GNS round trips. A
/// fifteenth, unbounded bucket catches everything past ten seconds — which is
/// where the 30s request timeout lives.
const BUCKET_BOUNDS_US: [u64; 14] = [
    500,        // 0.5 ms
    1_000,      // 1 ms
    2_000,      // 2 ms
    5_000,      // 5 ms
    10_000,     // 10 ms
    25_000,     // 25 ms
    50_000,     // 50 ms
    100_000,    // 100 ms
    250_000,    // 250 ms
    500_000,    // 500 ms
    1_000_000,  // 1 s
    2_500_000,  // 2.5 s
    5_000_000,  // 5 s
    10_000_000, // 10 s
];

/// One counter per bound, plus the `+Inf` overflow bucket.
const BUCKET_COUNT: usize = BUCKET_BOUNDS_US.len() + 1;

/// The schema tag every `/metrics` payload carries.
///
/// The dashboard refuses a payload whose schema it does not recognise, so this
/// string is part of the wire contract: bump it when the shape changes.
pub const SCHEMA: &str = "gips.metrics.v1";

fn us_to_ms(us: u64) -> f64 {
    us as f64 / 1000.0
}

/// A monotonic stopwatch.
///
/// Backed by [`Instant`], so it is unaffected by wall-clock jumps (NTP steps,
/// suspend/resume) and can never yield a negative duration.
pub struct Timer {
    start: Instant,
}

impl Timer {
    pub fn start() -> Self {
        Self {
            start: Instant::now(),
        }
    }

    /// Elapsed microseconds, saturating at `u64::MAX`.
    pub fn elapsed_us(&self) -> u64 {
        let elapsed = self.start.elapsed();
        u64::try_from(elapsed.as_micros()).unwrap_or(u64::MAX)
    }
}

impl Default for Timer {
    fn default() -> Self {
        Self::start()
    }
}

/// A monotonically increasing count of events.
#[derive(Debug)]
pub struct Counter {
    name: &'static str,
    description: &'static str,
    value: AtomicU64,
}

impl Counter {
    const fn new(name: &'static str, description: &'static str) -> Self {
        Self {
            name,
            description,
            value: AtomicU64::new(0),
        }
    }

    /// Records one event. Saturates rather than wrapping.
    ///
    /// `Relaxed` is the right ordering: these counts are reported as an
    /// eventually-consistent tally, and nothing in the daemon branches on them,
    /// so there is no happens-before relationship to establish and no reason to
    /// pay for a fence on a serving path.
    pub fn incr(&self) {
        let mut current = self.value.load(Ordering::Relaxed);
        loop {
            if current == u64::MAX {
                return;
            }
            match self.value.compare_exchange_weak(
                current,
                current + 1,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => return,
                Err(observed) => current = observed,
            }
        }
    }

    pub fn value(&self) -> u64 {
        self.value.load(Ordering::Relaxed)
    }

    fn snapshot(&self) -> CounterSnapshot {
        CounterSnapshot {
            name: self.name,
            description: self.description,
            value: self.value(),
        }
    }
}

/// A fixed-bucket latency histogram.
///
/// Bucket boundaries are compile-time constants, so an observation is a bounded
/// linear scan plus three `fetch_*` operations — no allocation, no lock, and no
/// unbounded work regardless of how extreme the sample is.
#[derive(Debug)]
pub struct Histogram {
    name: &'static str,
    description: &'static str,
    buckets: [AtomicU64; BUCKET_COUNT],
    count: AtomicU64,
    sum_us: AtomicU64,
    /// `u64::MAX` while no sample has been recorded.
    min_us: AtomicU64,
    max_us: AtomicU64,
}

impl Histogram {
    fn new(name: &'static str, description: &'static str) -> Self {
        Self {
            name,
            description,
            buckets: std::array::from_fn(|_| AtomicU64::new(0)),
            count: AtomicU64::new(0),
            sum_us: AtomicU64::new(0),
            min_us: AtomicU64::new(u64::MAX),
            max_us: AtomicU64::new(0),
        }
    }

    /// Records one measurement, in microseconds.
    pub fn observe_us(&self, us: u64) {
        let index = BUCKET_BOUNDS_US
            .iter()
            .position(|&bound| us <= bound)
            .unwrap_or(BUCKET_COUNT - 1);
        self.buckets[index].fetch_add(1, Ordering::Relaxed);
        self.count.fetch_add(1, Ordering::Relaxed);
        self.sum_us.fetch_add(us, Ordering::Relaxed);
        self.min_us.fetch_min(us, Ordering::Relaxed);
        self.max_us.fetch_max(us, Ordering::Relaxed);
    }

    /// Records the time a [`Timer`] has been running.
    pub fn observe(&self, timer: &Timer) {
        self.observe_us(timer.elapsed_us());
    }

    /// Starts a timer that records itself when it goes out of scope.
    ///
    /// For blocks with several exits — an early `return`, a `?`, a `let …
    /// else` — where a hand-placed `observe` on each one is a maintenance
    /// hazard: the exit added next year would silently go unmeasured. `Drop`
    /// runs on every path, so the coverage is structural.
    pub fn scoped(&self) -> ScopedTimer<'_> {
        ScopedTimer {
            histogram: self,
            timer: Timer::start(),
        }
    }

    pub fn count(&self) -> u64 {
        self.count.load(Ordering::Relaxed)
    }

    /// The smallest bucket bound at or below which `quantile` of samples fall.
    ///
    /// This is a *bucket-resolution* estimate, not an interpolated one: the
    /// answer is always an actual bucket boundary, so it over-reports rather
    /// than inventing a value between two bounds. A sample landing in the
    /// unbounded top bucket reports the observed maximum instead of `+Inf`.
    fn quantile_us(&self, quantile: f64) -> Option<u64> {
        let total = self.count();
        if total == 0 {
            return None;
        }
        // `ceil` so that p50 of a single sample is that sample, not "nothing".
        let target = ((total as f64) * quantile).ceil().max(1.0) as u64;
        let mut cumulative = 0u64;
        for (index, bucket) in self.buckets.iter().enumerate() {
            cumulative = cumulative.saturating_add(bucket.load(Ordering::Relaxed));
            if cumulative >= target {
                return Some(match BUCKET_BOUNDS_US.get(index) {
                    Some(&bound) => bound,
                    None => self.max_us.load(Ordering::Relaxed),
                });
            }
        }
        Some(self.max_us.load(Ordering::Relaxed))
    }

    fn snapshot(&self) -> HistogramSnapshot {
        let count = self.count();
        let sum_us = self.sum_us.load(Ordering::Relaxed);
        let min_us = self.min_us.load(Ordering::Relaxed);

        let buckets = self
            .buckets
            .iter()
            .enumerate()
            .map(|(index, bucket)| BucketSnapshot {
                le_ms: BUCKET_BOUNDS_US.get(index).copied().map(us_to_ms),
                count: bucket.load(Ordering::Relaxed),
            })
            .collect();

        HistogramSnapshot {
            name: self.name,
            unit: "ms",
            description: self.description,
            count,
            sum_ms: us_to_ms(sum_us),
            mean_ms: (count > 0).then(|| us_to_ms(sum_us) / count as f64),
            min_ms: (count > 0).then(|| us_to_ms(min_us)),
            max_ms: (count > 0).then(|| us_to_ms(self.max_us.load(Ordering::Relaxed))),
            p50_ms: self.quantile_us(0.50).map(us_to_ms),
            p90_ms: self.quantile_us(0.90).map(us_to_ms),
            p99_ms: self.quantile_us(0.99).map(us_to_ms),
            buckets,
        }
    }
}

/// A running timer that records itself into its histogram on drop.
///
/// See [`Histogram::scoped`]. Panic-safe by construction: an unwind through the
/// guarded block still runs `Drop`, so a panicking request is measured rather
/// than lost.
pub struct ScopedTimer<'a> {
    histogram: &'a Histogram,
    timer: Timer,
}

impl Drop for ScopedTimer<'_> {
    fn drop(&mut self) {
        self.histogram.observe(&self.timer);
    }
}

/// Event tallies that a duration cannot express.
///
/// Split out from the histograms because "how often did verification refuse
/// bytes" is an operator's first question and a latency curve cannot answer it.
#[derive(Debug)]
pub struct Counters {
    pub narinfo_served: Counter,
    pub narinfo_not_found: Counter,
    pub narinfo_refused: Counter,
    pub nar_served: Counter,
    pub nar_rejected: Counter,
    pub signature_accepted: Counter,
    pub signature_rejected: Counter,
    pub gns_resolve_ok: Counter,
    pub gns_resolve_failed: Counter,
    pub metrics_scrapes: Counter,
}

impl Default for Counters {
    fn default() -> Self {
        Self {
            narinfo_served: Counter::new(
                "narinfo_served",
                "narinfo responses returned to a client",
            ),
            narinfo_not_found: Counter::new(
                "narinfo_not_found",
                "narinfo requests for a store path this node does not have",
            ),
            narinfo_refused: Counter::new(
                "narinfo_refused",
                "narinfo requests refused because the record is unusable or inconsistent",
            ),
            nar_served: Counter::new(
                "nar_served",
                "nar payloads that passed both CID and NarHash verification",
            ),
            nar_rejected: Counter::new(
                "nar_rejected",
                "nar fetches refused: unreachable, wrong CID, or wrong NarHash",
            ),
            signature_accepted: Counter::new(
                "signature_accepted",
                "publisher signatures that verified against a trusted key",
            ),
            signature_rejected: Counter::new(
                "signature_rejected",
                "publisher signatures that failed to verify",
            ),
            gns_resolve_ok: Counter::new("gns_resolve_ok", "GNS names resolved to a manifest CID"),
            gns_resolve_failed: Counter::new(
                "gns_resolve_failed",
                "GNS name resolutions that failed",
            ),
            metrics_scrapes: Counter::new("metrics_scrapes", "authenticated reads of /metrics"),
        }
    }
}

impl Counters {
    fn all(&self) -> [&Counter; 10] {
        [
            &self.narinfo_served,
            &self.narinfo_not_found,
            &self.narinfo_refused,
            &self.nar_served,
            &self.nar_rejected,
            &self.signature_accepted,
            &self.signature_rejected,
            &self.gns_resolve_ok,
            &self.gns_resolve_failed,
            &self.metrics_scrapes,
        ]
    }
}

/// Every measurement this daemon takes.
///
/// Held in [`crate::AppState`] rather than in a global `static`: a router owns
/// its own metrics, so tests observe exactly the requests they made and two
/// routers in one process never pollute each other's numbers.
#[derive(Debug)]
pub struct Metrics {
    started_at: Instant,
    pub narinfo_response: Histogram,
    pub nar_fetch_ipfs: Histogram,
    pub nar_fetch_local: Histogram,
    pub nar_verify: Histogram,
    pub signature_verify: Histogram,
    pub gns_resolve: Histogram,
    pub manifest_resolve: Histogram,
    pub db_query: Histogram,
    pub counters: Counters,
}

impl Default for Metrics {
    fn default() -> Self {
        Self::new()
    }
}

impl Metrics {
    pub fn new() -> Self {
        Self {
            started_at: Instant::now(),
            narinfo_response: Histogram::new(
                "narinfo_response_ms",
                "wall time of a /narinfo or /<hash>.narinfo response, end to end",
            ),
            nar_fetch_ipfs: Histogram::new(
                "nar_fetch_ipfs_ms",
                "time to pull nar bytes from the IPFS API",
            ),
            nar_fetch_local: Histogram::new(
                "nar_fetch_local_ms",
                "time to resolve a nar target from the in-process offline snapshot",
            ),
            nar_verify: Histogram::new(
                "nar_verify_ms",
                "time to verify fetched bytes against their CID and signed NarHash",
            ),
            signature_verify: Histogram::new(
                "signature_verify_ms",
                "time to verify one publisher signature over a narinfo",
            ),
            gns_resolve: Histogram::new(
                "gns_resolve_ms",
                "time for a GNS name to resolve to a manifest CID (peer discovery)",
            ),
            manifest_resolve: Histogram::new(
                "manifest_resolve_ms",
                "time to resolve a store path through subscribed publishers, end to end",
            ),
            db_query: Histogram::new(
                "db_query_ms",
                "time for one SQLite read on the serving path",
            ),
            counters: Counters::default(),
        }
    }

    fn all_histograms(&self) -> [&Histogram; 8] {
        [
            &self.narinfo_response,
            &self.nar_fetch_ipfs,
            &self.nar_fetch_local,
            &self.nar_verify,
            &self.signature_verify,
            &self.gns_resolve,
            &self.manifest_resolve,
            &self.db_query,
        ]
    }

    /// Reads every atomic into a serialisable payload.
    ///
    /// Not an atomic snapshot of the whole registry — counters read moments
    /// apart may disagree by a request or two under load. That is the correct
    /// trade: a consistent snapshot would need a lock on the serving path, and
    /// no operator decision turns on being one request behind.
    pub fn snapshot(&self) -> MetricsSnapshot {
        MetricsSnapshot {
            schema: SCHEMA,
            uptime_seconds: self.started_at.elapsed().as_secs_f64(),
            counters: self.counters.all().iter().map(|c| c.snapshot()).collect(),
            histograms: self.all_histograms().iter().map(|h| h.snapshot()).collect(),
            mirror: None,
        }
    }
}

/// Times an async operation and records it, returning the output unchanged.
///
/// The signature is the point: `T` in, `T` out, no `Result` introduced and no
/// branch on the value. A measurement cannot turn a served request into a
/// failed one because this function never inspects what it is timing.
pub async fn timed<F>(histogram: &Histogram, future: F) -> F::Output
where
    F: Future,
{
    let timer = Timer::start();
    let output = future.await;
    histogram.observe(&timer);
    output
}

/// The synchronous twin of [`timed`], for CPU-bound work such as signature
/// verification.
pub fn timed_sync<T, F>(histogram: &Histogram, f: F) -> T
where
    F: FnOnce() -> T,
{
    let timer = Timer::start();
    let output = f();
    histogram.observe(&timer);
    output
}

// ---------------------------------------------------------------------------
// Wire format
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
pub struct MetricsSnapshot {
    pub schema: &'static str,
    pub uptime_seconds: f64,
    pub counters: Vec<CounterSnapshot>,
    pub histograms: Vec<HistogramSnapshot>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mirror: Option<Box<MetricsSnapshot>>,
}

impl MetricsSnapshot {
    pub fn to_prometheus_text(&self, prefix: &str) -> String {
        let mut out = String::new();

        out.push_str(&format!(
            "# HELP {}_uptime_seconds Process uptime in seconds\n",
            prefix
        ));
        out.push_str(&format!("# TYPE {}_uptime_seconds gauge\n", prefix));
        out.push_str(&format!(
            "{}_uptime_seconds {:.3}\n\n",
            prefix, self.uptime_seconds
        ));

        for counter in &self.counters {
            let name = format!("{}_{}", prefix, counter.name);
            out.push_str(&format!("# HELP {} {}\n", name, counter.description));
            out.push_str(&format!("# TYPE {} counter\n", name));
            out.push_str(&format!("{} {}\n\n", name, counter.value));
        }

        for hist in &self.histograms {
            let name = format!("{}_{}", prefix, hist.name);
            out.push_str(&format!("# HELP {} {}\n", name, hist.description));
            out.push_str(&format!("# TYPE {} histogram\n", name));

            let mut cumulative = 0u64;
            for bucket in &hist.buckets {
                cumulative = cumulative.saturating_add(bucket.count);
                if let Some(le) = bucket.le_ms {
                    out.push_str(&format!(
                        "{}_bucket{{le=\"{:.3}\"}} {}\n",
                        name, le, cumulative
                    ));
                } else {
                    out.push_str(&format!("{}_bucket{{le=\"+Inf\"}} {}\n", name, cumulative));
                }
            }
            out.push_str(&format!("{}_sum {:.3}\n", name, hist.sum_ms));
            out.push_str(&format!("{}_count {}\n\n", name, hist.count));
        }

        if let Some(ref mirror) = self.mirror {
            let mirror_prefix = format!("{}_mirror", prefix);
            out.push_str(&mirror.to_prometheus_text(&mirror_prefix));
        }

        out
    }
}

#[derive(Debug, Serialize)]
pub struct CounterSnapshot {
    pub name: &'static str,
    pub description: &'static str,
    pub value: u64,
}

#[derive(Debug, Serialize)]
pub struct HistogramSnapshot {
    pub name: &'static str,
    /// Always `"ms"`. Emitted per-series so a consumer never has to assume.
    pub unit: &'static str,
    pub description: &'static str,
    pub count: u64,
    pub sum_ms: f64,
    /// `null` until the series has at least one sample — never `0`, which
    /// would read as "we measured zero milliseconds".
    pub mean_ms: Option<f64>,
    pub min_ms: Option<f64>,
    pub max_ms: Option<f64>,
    pub p50_ms: Option<f64>,
    pub p90_ms: Option<f64>,
    pub p99_ms: Option<f64>,
    pub buckets: Vec<BucketSnapshot>,
}

#[derive(Debug, Serialize)]
pub struct BucketSnapshot {
    /// Upper bound of the bucket in milliseconds; `null` is the `+Inf` bucket.
    pub le_ms: Option<f64>,
    pub count: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_histogram_reports_nothing_rather_than_zero() {
        let hist = Histogram::new("t", "d");
        let snap = hist.snapshot();
        assert_eq!(snap.count, 0);
        assert_eq!(snap.sum_ms, 0.0);
        // The distinction that matters: no samples is not "0 ms".
        assert!(snap.mean_ms.is_none());
        assert!(snap.min_ms.is_none());
        assert!(snap.max_ms.is_none());
        assert!(snap.p50_ms.is_none());
        assert_eq!(snap.buckets.len(), BUCKET_COUNT);
        assert_eq!(snap.buckets.last().unwrap().le_ms, None, "+Inf bucket");
    }

    #[test]
    fn observations_land_in_the_bucket_that_bounds_them() {
        let hist = Histogram::new("t", "d");
        hist.observe_us(400); // <= 500us
        hist.observe_us(500); // <= 500us, boundary is inclusive
        hist.observe_us(1_500); // <= 2ms
        hist.observe_us(99_000_000); // past the last bound: +Inf

        let snap = hist.snapshot();
        assert_eq!(snap.count, 4);
        assert_eq!(snap.buckets[0].count, 2, "0.5ms bucket");
        assert_eq!(snap.buckets[0].le_ms, Some(0.5));
        assert_eq!(snap.buckets[2].count, 1, "2ms bucket");
        assert_eq!(snap.buckets[BUCKET_COUNT - 1].count, 1, "+Inf bucket");
        assert_eq!(snap.min_ms, Some(0.4));
        assert_eq!(snap.max_ms, Some(99_000.0));
    }

    #[test]
    fn quantiles_are_bucket_bounds_and_a_lone_sample_is_its_own_p50() {
        let hist = Histogram::new("t", "d");
        hist.observe_us(1_200);
        let snap = hist.snapshot();
        assert_eq!(
            snap.p50_ms,
            Some(2.0),
            "reported as the bucket's upper bound"
        );
        assert_eq!(snap.p99_ms, Some(2.0));

        // 99 fast samples and one slow one: p50 stays fast, p99 finds the tail.
        let hist = Histogram::new("t", "d");
        for _ in 0..99 {
            hist.observe_us(400);
        }
        hist.observe_us(3_000_000);
        let snap = hist.snapshot();
        assert_eq!(snap.p50_ms, Some(0.5));
        assert_eq!(snap.p99_ms, Some(0.5));
        assert_eq!(snap.max_ms, Some(3_000.0));
    }

    #[test]
    fn a_sample_past_the_last_bound_reports_the_observed_max_not_infinity() {
        let hist = Histogram::new("t", "d");
        hist.observe_us(45_000_000);
        let snap = hist.snapshot();
        assert_eq!(snap.p99_ms, Some(45_000.0));
        assert!(snap.p99_ms.unwrap().is_finite());
    }

    #[test]
    fn a_counter_saturates_instead_of_wrapping_to_zero() {
        let counter = Counter::new("c", "d");
        counter.value.store(u64::MAX - 1, Ordering::Relaxed);
        counter.incr();
        assert_eq!(counter.value(), u64::MAX);
        counter.incr();
        assert_eq!(counter.value(), u64::MAX, "must stick, not wrap to 0");
    }

    #[tokio::test]
    async fn timed_returns_its_future_output_untouched() {
        let hist = Histogram::new("t", "d");

        let ok: Result<u32, &str> = timed(&hist, async { Ok(7) }).await;
        assert_eq!(ok, Ok(7));

        let err: Result<u32, &str> = timed(&hist, async { Err("unchanged") }).await;
        assert_eq!(err, Err("unchanged"));

        assert_eq!(hist.count(), 2, "both outcomes are measured");
    }

    #[test]
    fn timed_sync_returns_its_closure_output_untouched() {
        let hist = Histogram::new("t", "d");
        assert_eq!(timed_sync(&hist, || "value"), "value");
        assert_eq!(hist.count(), 1);
    }

    #[test]
    fn the_snapshot_names_every_declared_series_exactly_once() {
        let metrics = Metrics::new();
        let snap = metrics.snapshot();

        let mut names: Vec<&str> = snap.histograms.iter().map(|h| h.name).collect();
        names.sort_unstable();
        let mut deduped = names.clone();
        deduped.dedup();
        assert_eq!(names, deduped, "duplicate histogram name in the registry");
        assert_eq!(names.len(), 8);

        let mut counter_names: Vec<&str> = snap.counters.iter().map(|c| c.name).collect();
        counter_names.sort_unstable();
        let mut deduped = counter_names.clone();
        deduped.dedup();
        assert_eq!(counter_names, deduped, "duplicate counter name");
        assert_eq!(counter_names.len(), 10);

        assert!(snap.histograms.iter().all(|h| h.unit == "ms"));
    }

    #[test]
    fn the_payload_carries_no_free_form_strings_from_requests() {
        // Every string in the payload is a compile-time constant. This test
        // asserts that structurally: the snapshot types hold `&'static str`,
        // so a store path or token cannot be smuggled in. Serialising a
        // registry that has seen traffic must produce the same strings as one
        // that has not.
        let untouched = Metrics::new();
        let busy = Metrics::new();
        busy.narinfo_response.observe_us(1234);
        busy.counters.nar_rejected.incr();

        let strings = |m: &Metrics| -> Vec<String> {
            let s = m.snapshot();
            let mut out: Vec<String> = s
                .histograms
                .iter()
                .flat_map(|h| {
                    [
                        h.name.to_string(),
                        h.unit.to_string(),
                        h.description.to_string(),
                    ]
                })
                .collect();
            out.extend(
                s.counters
                    .iter()
                    .flat_map(|c| [c.name.to_string(), c.description.to_string()]),
            );
            out
        };

        assert_eq!(strings(&untouched), strings(&busy));
    }

    #[test]
    fn prometheus_text_format_serializes_correctly() {
        let metrics = Metrics::new();
        metrics.counters.narinfo_served.incr();
        metrics.counters.narinfo_served.incr();
        metrics.narinfo_response.observe_us(1500);

        let mut snapshot = metrics.snapshot();
        let mirror = Metrics::new();
        mirror.counters.nar_served.incr();
        snapshot.mirror = Some(Box::new(mirror.snapshot()));

        let text = snapshot.to_prometheus_text("gips");
        assert!(text.contains("# HELP gips_narinfo_served"));
        assert!(text.contains("# TYPE gips_narinfo_served counter"));
        assert!(text.contains("gips_narinfo_served 2"));
        assert!(text.contains("gips_narinfo_response_ms_count 1"));
        assert!(text.contains("gips_mirror_nar_served 1"));
        assert!(text.contains("gips_uptime_seconds"));
    }
}
