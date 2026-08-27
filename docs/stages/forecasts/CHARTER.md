# Remote Guix Compute Charter

Recorded 2026-08-27. Forecasts for the next implementation stretch are
conditioned on this release goal.

## User direction (verbatim)

> ok lets aim for the target of being able to remotely run comoutstuons that require a live guix env but build in such a way that we could keep an instance running and letting tasks join MCP style, but defer the more difficult task. we want to release a version when we can aceive the simpler task. can yiu make the documents and stsges align with this view

## Operational reading

- Destination milestone: release a version that can remotely run a declared
  computation requiring a live Guix environment and return attributable
  evidence.
- Compatibility requirement: do not make the one-shot release architecture
  prevent a later retained instance from accepting multiple MCP-style tasks.
- Explicitly deferred: retained-instance task joining and the MCP server/tool
  facade are not release blockers.
- Quality bar: the repository gates in `docs/stages/README.md`, exact-instance
  ownership checks, durable evidence, and live acceptance remain mandatory.
- Cost posture: the release path defaults to disposable instances and guarded
  cleanup; retained paid resources require explicit handoff.

This operational reading narrows ambiguous spelling but does not replace the
verbatim direction. Amendments are append-only and dated.
