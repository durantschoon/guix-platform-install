# Stage 24 — Telemetry, Metrics, and Premium Dashboard Visualization

**Motivation:** GIPS aims to be faster and more resilient than traditional central HTTP substitute servers, but we need hard data to prove it. We must instrument the `gipsd` daemon to collect performance metrics (IPFS fetch latency, DB query times, signature verification overhead, and P2P swarm discovery times) and build a **stunning, premium web dashboard** to visualize this data compared to baseline `guix publish` latency.

**The Change:**

1. **Instrumentation (Rust Backend):**
   - Integrate `opentelemetry` or `metrics` crate into the `gipsd` and `gips-http` crates.
   - Record histograms for: `/narinfo` response time, `/nar` fetch time (from IPFS vs local cache), and signature validation latency.
   - Expose a `/metrics` endpoint in `gipsd` (JSON or Prometheus format, behind the auth token or on a separate local-only admin port).

2. **Premium Visual Dashboard (Web Frontend):**
   - Create a new web frontend (e.g., in `components/gips-dashboard` using Next.js or Vite) that consumes the metrics endpoint.
   - **Aesthetic Requirements:** The UI MUST NOT look like a generic Grafana dashboard. It must be a bespoke, premium web application that WOWs the user.
   - **Design System:** Use modern web design principles (Glassmorphism, backdrop-filters, dark mode, vibrant harmonious gradients).
   - **Animations:** Implement scroll-driven animations, View Transitions, and micro-animations for real-time data pulses (e.g., a live node-graph of the IPFS swarm or pulsing latency charts).

3. **Benchmarking Script:**
   - Create a script (`scripts/benchmark-sync.sh`) that runs `guix pull` and `guix install` against a standard HTTP substitute server vs. the local GIPS proxy, and feeds the comparative timing data to the dashboard.

**Allowed Files Whitelist:**

- `Cargo.toml` (add telemetry crates)
- `components/gips-http/src/*` (add instrumentation)
- `gipsd/src/*` (metrics endpoint)
- `components/gips-dashboard/*` (NEW - modern web frontend)
- `scripts/benchmark-sync.sh` (NEW)
- `docs/TODO.md` (add stage)

**Definition of Done:**
The daemon successfully records its operational latency and exposes it. A premium, highly-polished local web dashboard successfully reads this data and renders beautiful, animated comparative charts proving the performance delta between GIPS and standard Guix servers.

**Commit Message:** `[stage-24] feat: add telemetry instrumentation and premium visual metrics dashboard`

**Status:** Ready to be claimed after core security stages.
