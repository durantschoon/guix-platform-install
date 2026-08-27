# Oracle Guix Validation Runner

The ordered implementation and live-acceptance work is tracked in
[`ORACLE_VALIDATION_STAGES.md`](ORACLE_VALIDATION_STAGES.md).

**Status (2026-08-27): Stage 0 metadata-only SSH and the Stage 1 pass/fail
contract passed live acceptance; every disposable instance terminated. OV-5
resilient telemetry, forced reconnect, periodic lifecycle/console capture, and
permanent guest-loss evidence all passed live acceptance. OV-6 is next.**

## Timing and prediction

Timed entry points print a historical-median prediction before work and the
actual duration plus delta afterward. Samples are kept in ignored local state
under `.oracle-validation/`; `make oracle-timings` reports sample count,
failures, median, p90, and latest duration per phase. Predictions are evidence,
not deadlines: with only one sample, median and p90 are the same and should be
treated as a provisional baseline.

## Goal

Give a local coding agent a disposable, real Guix System on Oracle Cloud for
validation without giving the agent or the guest the user's OCI credentials.
The local controller launches the instance, sends an exact source snapshot,
runs a declared command, incrementally saves output on the local machine,
collects a result, and terminates the instance.

This is a validation executor, not a remote autonomous agent.  Builds, tests,
polling, transfer, and logging are deterministic programs.  The model that
writes code consumes only the summarized result and evidence paths.  See
[`MODEL.md`](../MODEL.md) for the planner/executor policy.

## Trust boundary

```text
local trusted controller                         disposable untrusted guest

OCI config/API key ----> OCI CLI ----> Compute API
ephemeral SSH private key |                           |
source snapshot ------------ SSH ------------------> validation user
local run log <------------- SSH output ------------ test process
```

- OCI credentials and the ephemeral SSH private key remain local.
- The guest receives only the corresponding public key through
  `ssh_authorized_keys` instance metadata.
- The validation command receives no forge or cloud credentials by default.
- No instance-principal IAM policy is attached.
- OCI control-plane operations remain in the local controller.
- IMDSv2 is required at launch; IMDSv1 should be disabled.

Code under test must be treated as untrusted.  Stage 1 bounds its lifetime but
does not yet provide strong workload isolation inside the guest.  Do not use it
to execute code from an untrusted third party in a tenancy containing sensitive
networks or data.

## Stage 0 -- prove the launch substrate

Stage 0 closes the prerequisite recorded in
[`ORACLE_ONE_CLICK_ROADMAP.md`](ORACLE_ONE_CLICK_ROADMAP.md): the metadata SSH
service must admit a real login when the image contains no baked-in key.

Deliverables:

1. A preflight that checks the OCI CLI/profile, source path, SSH tools, explicit
   image OCID, subnet OCID, and local run directory before creating anything.
2. A dedicated live probe that generates a one-run SSH key, launches the image
   with that public key only, requires IMDSv2, waits for SSH, records the
   instance OCID and public IP, proves an authenticated `guix` login, captures
   diagnostics, and terminates the probe instance.
3. Offline tests for identifiers, quoting/encoding, lifecycle decisions, and
   command construction.  Offline success must never be described as the live
   metadata test passing.
4. Explicit image selection for the first release.  Image publication and
   checksum pinning remain later work.

Live acceptance criteria:

- the selected image was built with no `oracle/image/authorized-key.pub`;
- the launch supplies only the generated public key through metadata;
- password authentication remains disabled;
- `ssh guix@IP true` succeeds with the generated private key;
- the local record contains the launch identity and outcome;
- the probe instance reaches `TERMINATED` after evidence collection.

## Stage 1 -- one-shot validation

The first useful interface is intentionally small:

```sh
oracle/scripts/validate.scm start \
  --image-id ocid1.image... \
  --subnet-id ocid1.subnet... \
  --source . \
  --command './run-tests.sh'
```

Optional policy flags may include `--shape`, `--timeout`, and
`--keep-on-failure`.  Keeping a failed instance is opt-in because an abandoned
cloud resource is a worse default than losing an interactive debugging shell.

Each run receives a collision-resistant ID and a local directory:

```text
.oracle-validation/runs/<run-id>/
|-- state.scm
|-- source-manifest.txt
|-- remote-output.log
|-- result.json
`-- ssh/
    |-- id_ed25519
    `-- id_ed25519.pub
```

`state.scm` is the native, atomically replaced recovery record. `result.json`
is the stable machine-readable handoff to an LLM or other caller.

For lifecycle polling, use:

    oracle/scripts/validation-lifecycle.scm status --run-dir DIR --json

This emits one JSON object with schema_version 1, the exact run_id and
instance_ocid, local_phase, local and remote artifact states,
remote_lifecycle, and an ownership_match boolean. The JSON shape is the
stable caller interface; human-oriented status output and evidence files may
grow without changing it. A restart may resume only a checkpoint whose phase
is prepared, snapshotted, launching, launched, ssh, or running. Terminal and
HANDED_OFF checkpoints are intentionally refused.

The source transfer excludes `.git`, `.oracle-validation`, sockets, device
files, and other paths that cannot be represented by the chosen archive.  The
record states whether the source came from a clean commit or a working-tree
snapshot and includes a content manifest so a result names exactly what ran.

The controller streams combined remote stdout/stderr to the terminal and
`remote-output.log` as it arrives.  Stage 1 does not promise replay across an
SSH reconnection; that belongs to Stage 2.  It does promise that output already
received remains local if the instance disappears.

Stage 1 acceptance criteria:

- a passing command produces exit status 0, `result.json`, and a terminated
  instance;
- a failing command produces its nonzero status and log, then terminates unless
  `--keep-on-failure` was explicitly requested;
- the source hash/run ID and exact command are recorded before remote execution;
- launch or SSH failure still leaves enough local state to identify and clean
  up the instance;
- no OCI credential path or contents are copied to the guest;
- pure/offline tests cover parsing, command construction, state transitions,
  and cleanup policy.

## Later stages

### Stage 2 -- resilient telemetry

Add sequenced JSONL events, a remote journal, heartbeat records, reconnect and
replay, OCI lifecycle polling, periodic serial-console history capture, and
`status`, `logs`, `collect`, and `stop` commands.  A forced SSH interruption
must reconnect without a gap in event sequence numbers.  Permanent instance
loss must still leave the locally received events and most recent console
history.

### Stage 3 -- incremental agent loop

Add `sync`, `run`, and `watch` so one instance can validate multiple source
snapshots.  Every attempt records its own source hash and result; a result must
never be attributed to files that were synchronized later.

### Stage 4 -- policy and ergonomics

Add `.guix-validation.scm`, allowlisted commands/artifacts, resource and output
limits, shape/cost policy, temporary OCI security-token support, expired-run
cleanup, and a stable machine-readable result schema for coding-agent tools.

## Failure and cleanup policy

The local run record is written before launch and updated immediately after an
instance OCID is received.  Cleanup targets the recorded OCID, never a display
name alone.  Before terminating any pre-existing instance to free capacity, the
controller or operator must list its OCID, display name, lifecycle state, and
tags explicitly.

Success always terminates the validation instance.  Failure terminates by
default.  `--keep-on-failure` records the retained OCID and an explicit stop
command.  A later TTL reaper may automate that cleanup, but Stage 1 must not
claim a TTL it has no persistent process to enforce.

## Known constraints

- The current generic-image metadata SSH path has failed its live proof and is
  being repaired in OV-1; it remains unverified until OV-2 passes.
- `VM.Standard.E2.1.Micro` has only 1 GiB RAM.  The image's swap helps, but
  substantial Guix builds may need a larger paid shape.
- Stage 1 requires an already imported image and an existing public subnet.
- Stage 1 captures the SSH stream but not yet an independently replayable
  remote event journal or continuous OCI serial history.
