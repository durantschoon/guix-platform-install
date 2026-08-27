# Stage 05 — Freeze the bounded one-shot remote-compute contract

## Motivation (measured)

Live OV-4 proved that the controller can execute both a passing and a failing
command on a disposable Guix instance. Live OV-5 proved durable sequenced
telemetry across a forced SSH disconnect and permanent guest loss. The latest
controller also exposes lifecycle `status --json`, but `result.json` is still
written by a small positional helper and does not carry the complete identity
and policy facts needed for a release contract.

The release target is one remotely executed computation requiring a live Guix
environment. Retained instances and MCP tools are deferred. This stage freezes
the one-shot boundary while keeping the later path open: instance identity,
execution identity, and source-snapshot identity must never be aliases.

## The change

1. Define versioned, documented request, status, and result schemas for the
   one-shot controller. Existing human output may remain human-oriented.
2. Give each execution an explicit collision-resistant `execution_id`. For the
   current one-shot path it may equal the existing `run_id`, but both named
   fields must exist and consumers must not infer either from `instance_ocid`.
3. A terminal result must identify the exact `run_id`, `execution_id`,
   `instance_ocid` when launch reached OCI, source SHA-256, declared command,
   exit status or controller failure class, start/end timestamps, duration,
   cleanup disposition, and evidence paths.
4. Add fail-closed execution policy for timeout, maximum retained output,
   allowed shape, and declared command. Defaults must preserve the already
   accepted Stage 1 invocation. Invalid or unsupported policy is rejected
   before launch.
5. Bound output without silently losing information: the durable event stream
   records that truncation occurred, the byte limit, and the full-output
   location if one exists. It must never present truncated output as complete.
6. Document the compatibility boundary: this stage does not implement instance
   retention, synchronization, task joining, a daemon, or MCP tools.

## Ground rules

- Guile for controller and guest scripts. ASCII-only console-visible output.
- Parse policy once at the boundary; downstream code consumes parsed values.
- No OCI credential or SSH private-key path/content enters result JSON or the
  guest.
- No new cloud mutation and no live launch in this stage.
- Preserve OV-3 ownership gates and OV-5 journal/replay behavior.
- A new lifecycle state, automatic retention, or implicit command allowlist is
  an architectural expansion: **STOP and ask**.
- Do not implement `.guix-validation.scm` yet; its merge and precedence rules
  belong to a later stage unless this stage proves they are necessary.

## Allowed files (whitelist)

```
oracle/scripts/validation-common.scm
oracle/scripts/validate.scm
oracle/scripts/validation-lifecycle.scm
oracle/scripts/validation-guest-runner.scm
oracle/scripts/oracle-scripts_purpose.txt
oracle/tests/test-oracle-validation.scm
docs/ORACLE_VALIDATION_RUNNER.md
docs/stages/stage-05-REPORT.md
```

Do not edit `Makefile`, `run-tests.sh`, `CHECKLIST.md`,
`SOURCE_MANIFEST.txt`, or any OCI credential/default file.

## Tests (enumerated — all required)

1. Request, status, and result JSON carry explicit schema versions.
2. Instance, execution, run, and source identities round-trip without
   derivation or substitution.
3. Pre-launch parsing rejects zero, negative, malformed, and over-policy
   timeout/output values.
4. Shape policy accepts the current default and rejects an undeclared shape
   before any launch command is called.
5. Passing, command-failure, launch-failure, guest-loss, and cleanup-failure
   fixtures produce distinguishable terminal results.
6. Output at the byte limit remains complete; output beyond it records explicit
   truncation and never produces malformed JSONL or JSON.
7. Results contain no OCI credential path, private-key path, or private-key
   material fixture.
8. Existing overlap replay, forced-reconnect, ownership, handoff-refusal, and
   permanent-loss offline checks remain green.
9. Source inspection proves this stage added no daemon, MCP server, retained
   instance default, or new cloud mutation path.

## Definition of Done

```sh
lib/validate-before-deploy.sh --verbose   # exit 0; "Failed:" must be 0
./run-tests.sh                            # exit 0
guile --no-auto-compile -s oracle/tests/test-oracle-validation.scm   # exit 0
git diff --check                         # exit 0
```

Inherited baseline: validation has 15 warnings and zero failures. In a
Guix-capable environment, `run-tests.sh` reports 14/14 converted-script
failures but exits 0. On the coordinator's macOS host it currently exits 2
because `(guix read-print)` is unavailable and the pre-existing runner then
uses `return` outside a function. Use the repository's established split
host/Guix verification when necessary and report the literal commands; do not
claim the host gate passed. Do not fix either inherited condition as unrelated
work. No live acceptance claim is permitted by this stage; its highest
evidence phase is offline controller execution.

## Commit message (exact, single line)

```
feat(oracle): freeze bounded one-shot compute contract
```

## Report requirements

Write `docs/stages/stage-05-REPORT.md` with: changes per file; the three schemas
with one example each; identity and truncation invariants; pasted gate output;
whitelist audit; deviations; open questions; and an Unverified claims section
that names the highest evidence phase reached.

## Blocked protocol

If the existing one-shot state cannot represent separate execution/source
identity without introducing a new lifecycle state, or if output bounding
requires discarding evidence without an explicit truncation fact, stop and
write a `Blocked:` report with the exact conflicting state transitions. Do not
silently widen this stage into the retained-instance design.
