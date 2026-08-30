# Stage 14 — GIPS Swarm Telemetry, Live Terminal Monitor, and Dashboard Service

## Motivation (measured)

Operators running GIPS nodes across multiple machines (Framework laptop, home server, and Oracle Always Free instance) need real-time visibility into swarm health, peer connectivity, bandwidth utilization, substitute hit rates, and request latencies.

GIPS contains a rich internal metrics and telemetry subsystem (`gips-dashboard`, `/metrics`, `/metrics/history`, `/status`, and `gips monitor`). Stage 14 integrates these monitoring capabilities into the installer's post-install toolchain and service definitions, providing:
1. Terminal monitor integration (`guix-customize` and `gips monitor`).
2. Optional lightweight dashboard web service (embedded single-page telemetry app).
3. Metric export hooks for system monitoring daemons.

## The change

1. Add terminal swarm monitor launching options to `postinstall/recipes/add/gips.scm` and `guix-customize`.
2. Add dashboard service configuration fields to `<gips-configuration>` in `gips/scheme/gips/config.scm` and `gips/scheme/gips/service.scm`.
3. Add offline test coverage in `gips/tests/test_api.scm` validating metrics retrieval, latency histogram rendering, and structured JSON output.
4. Document monitoring and telemetry operations in `gips/docs/user_guide.md` and `postinstall/CUSTOMIZATION.md`.

## Ground rules

- Guile for all configuration helpers and Scheme APIs.
- ASCII-only terminal rendering in the console monitor (`[OK]`, `[WARN]`, `[ERROR]`, plain box grids).
- Metric endpoints must be read-only and unauthenticated (safe for local scraping).
- Mutating actions remain protected behind authentication tokens.

## Allowed files (whitelist)

```
gips/scheme/gips/config.scm
gips/scheme/gips/service.scm
gips/scheme/gips/api.scm
postinstall/recipes/add/gips.scm
gips/docs/user_guide.md
postinstall/CUSTOMIZATION.md
docs/stages/stage-14-REPORT.md
```

## Tests (enumerated — all required)

1. `(gips-metrics)` and `(gips-metrics-history)` parse JSON metrics payloads without throwing exceptions.
2. `(gips-monitor)` renders ASCII health tables and latency distributions cleanly.
3. `(gips-monitor #:json? #t)` emits valid, parseable JSON status dictionaries.
4. Enabling dashboard configuration in `<gips-configuration>` emits valid TOML flags for `gipsd`.
5. All 15 existing verdicts in `gips/test_api.scm` remain green.

## Definition of Done

```sh
lib/validate-before-deploy.sh --verbose   # exit 0; Failed: 0
make gips-test                            # exit 0
git diff --check                         # exit 0
```

## Commit message (exact, single line)

```
feat(gips): add swarm telemetry, live monitor, and dashboard integration
```

## Report requirements

Write `docs/stages/stage-14-REPORT.md` with:
- Summary of changes per file.
- Example terminal monitor output and JSON telemetry payload.
- Offline test evidence.
- Whitelist audit.
- Unverified claims section.

## Blocked protocol

If dashboard integration requires external Node/npm dependencies or dynamic asset downloads at build time, stop and report `Blocked:`. All dashboard assets must remain self-contained.
