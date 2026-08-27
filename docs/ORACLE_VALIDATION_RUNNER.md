# Oracle Guix Validation Runner

The ordered implementation and live-acceptance work is tracked in
[`ORACLE_VALIDATION_STAGES.md`](ORACLE_VALIDATION_STAGES.md).

**Status (2026-08-27): Stage 0 metadata-only SSH and the Stage 1 pass/fail
contract passed live acceptance; every disposable instance terminated. OV-5
resilient telemetry, forced reconnect, periodic lifecycle/console capture, and
permanent guest-loss evidence all passed live acceptance. OV-6 is the bounded
one-shot release path; retained instances and MCP tools are deferred.**

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

## Stage 07 one-shot entry point

The release-facing, non-interactive wrapper is the `oracle-run` Make target.
It keeps every cloud resource and guest command explicit while preserving the
controller's bounded policy and guarded cleanup:

```sh
make oracle-run IMAGE_ID=ocid1.image... SUBNET_ID=ocid1.subnet... \
  SOURCE="$PWD" COMMAND='sha256sum known-good/provenance'
```

`YES=--yes` is required for unattended use; it does not bypass ownership
checks. The run directory under `.oracle-validation/runs/` contains the
request, source hash, exact execution and instance identities, result, output,
telemetry, lifecycle, and console evidence. `make oracle-resume-check
RUN_DIR=...` is a read-only exact-checkpoint inspection for a restart rehearsal.
Only non-terminal `IN_TEST` checkpoints with the caller-supplied exact run,
execution, and instance identities are eligible; terminal, handed-off,
malformed, or ambiguous records are refused. This stage rehearses that
decision offline; it does not claim a live restart or OV-6 completion.

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

Optional policy flags include `--shape`, `--timeout`, `--max-output-bytes`, and
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

## Versioned one-shot schemas

All three machine interfaces use `schema_version: 1`. `request.json` records
the explicit `run_id`, `execution_id`, source SHA-256, declared command, and
parsed timeout/output/shape policy. Example:

```json
{"schema_version":1,"run_id":"20260827T120000Z-a-b","execution_id":"20260827T120000Z-a-b","source_sha256":"abc123","command":"./run-tests.sh","policy":{"timeout_seconds":3600,"max_output_bytes":1048576,"shape":"VM.Standard.E2.1.Micro"}}
```

Status adds the same explicit execution and source identities to the existing
exact-instance lifecycle view:

```json
{"schema_version":1,"run_id":"20260827T120000Z-a-b","execution_id":"20260827T120000Z-a-b","source_sha256":"abc123","instance_ocid":"ocid1.instance...","local_phase":"running","artifact_state":"IN_TEST","remote_lifecycle":"RUNNING","remote_artifact_state":"IN_TEST","ownership_match":true}
```

A terminal result records those four identities without deriving one from
another, plus command, exit status or failure class, timestamps, duration,
cleanup disposition, output completeness, and evidence paths:

```json
{"schema_version":1,"run_id":"20260827T120000Z-a-b","execution_id":"20260827T120000Z-a-b","instance_ocid":"ocid1.instance...","source_sha256":"abc123","command":"./run-tests.sh","exit_status":0,"failure_class":null,"started_at":"2026-08-27T12:00:00Z","ended_at":"2026-08-27T12:00:42Z","duration_seconds":42,"cleanup_disposition":"terminated","output_truncated":false,"output_byte_limit":1048576,"full_output_path":null,"evidence_paths":["events.jsonl","console-history.log"]}
```

The boundary accepts only `VM.Standard.E2.1.Micro`, timeouts from 1 through
86400 seconds, and retained-output limits from 1 through 16777216 bytes. The
defaults are 3600 seconds and 1048576 bytes. Invalid policy is rejected before
authentication, key generation, or launch. Output beyond the limit produces a
durable `output-truncated` event naming the byte limit and
`full_output_path=none`; callers must never treat that stream as complete.

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

## Release boundary and later expansion

The first release promises one remotely executed computation per disposable
Guix instance. It does not promise a resident task service. The controller is
nevertheless shaped for that later service: an OCI instance, an execution, and
a source snapshot are separate identities, and a result belongs to one exact
execution and source hash.

This compatibility boundary deliberately adds no retained-instance default,
synchronization, task joining, daemon, or MCP tool. It adds no cloud mutation:
launch and guarded termination remain the only one-shot mutations. A future
retained controller may assign an `execution_id` different from `run_id`
without changing the fact that neither identity is an alias for the instance
OCID or source SHA-256.

### Stage 2 -- resilient telemetry

Add sequenced JSONL events, a remote journal, heartbeat records, reconnect and
replay, OCI lifecycle polling, periodic serial-console history capture, and
`status`, `logs`, `collect`, and `stop` commands.  A forced SSH interruption
must reconnect without a gap in event sequence numbers.  Permanent instance
loss must still leave the locally received events and most recent console
history.

### Stage 3 -- incremental agent loop (deferred until after one-shot release)

Add `sync`, `run`, and `watch` so one instance can validate multiple source
snapshots.  Every attempt records its own source hash and result; a result must
never be attributed to files that were synchronized later.

### Stage 4 -- policy and ergonomics

Add `.guix-validation.scm`, allowlisted commands/artifacts, resource and output
limits, shape/cost policy, temporary OCI security-token support, expired-run
cleanup, and a stable machine-readable result schema for coding-agent tools.

For the one-shot release, only the stable schemas, bounded execution policy,
and expired-run safety are required. Temporary OCI security-token support,
retained-instance synchronization, and MCP tools are post-release.

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

- The generic-image metadata SSH path passed live acceptance in OV-2. This
  proves launch and login, not every future workload or shape.
- `VM.Standard.E2.1.Micro` has only 1 GiB RAM.  The image's swap helps, but
  substantial Guix builds may need a larger paid shape.
- Stage 1 requires an already imported image and an existing public subnet.
- OV-5 provides an independently replayable journal plus periodic OCI
  lifecycle and serial-console evidence. It is still a one-shot execution
  model; retained-instance synchronization is deferred.

## Expired-run review

Interrupted runs can be inspected with `validation-lifecycle.scm review
--root ~/.oracle-validation/runs`. This is a read-only inventory of local
checkpoints. Its versioned records distinguish expired candidates from
unexpired, malformed, missing-identity, and handed-off records; expiry is
never deletion authority. `reap --root ... --yes` is an explicit mutating
operation that re-reads ownership for each exact recorded OCID through the
OV-3 gate immediately before termination. OCI read failures and ownership
mismatches are protected outcomes, and durable results distinguish successful
termination from a failed termination request. No inventory search or
automatic adoption is performed.
