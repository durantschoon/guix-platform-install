# Oracle test-artifact lifecycle

This policy separates disposable agent-owned cloud artifacts from resources
that a human may rely on.  Names are descriptive only; OCI tags plus a local
ownership record are authoritative.

## States

`IN_TEST`
: The artifact is disposable working state.  The validation controller may
  create, update, replace, or destroy it without asking again, subject to the
  ownership checks below.

`HANDED_OFF`
: The artifact has crossed the human handoff boundary.  Automation must treat
  it as user data and must not modify or destroy it without a new explicit
  instruction identifying the artifact.

Absent, malformed, or unknown state
: Protected.  Never infer disposability from a display name, age, shape,
  compartment, or apparent inactivity.

## Required OCI tags

Every newly created disposable artifact must carry these free-form tags:

```text
managed-by = guix-platform-install
artifact-state = IN_TEST
run-id = <collision-resistant local run ID>
created-at = <UTC timestamp>
expires-at = <UTC timestamp used for review, not automatic authority>
```

`purpose` remains a descriptive tag.  Expiry does not override `HANDED_OFF`
and does not by itself authorize deletion.

## Destructive-operation gate

Automation may mutate or destroy an artifact without another user decision
only when every condition is true immediately before the operation:

1. The exact OCI OCID is recorded in a local run state beneath
   `.oracle-validation/`.
2. The local record says `artifact-state = IN_TEST`.
3. A fresh OCI read shows `managed-by = guix-platform-install`,
   `artifact-state = IN_TEST`, and the same `run-id` as the local record.
4. The artifact type and intended operation are within that run's declared
   scope.
5. No local handoff marker exists.

Failure or uncertainty in any check protects the artifact.  Cleanup targets
an exact OCID, never a display name or search result.

## Handoff protocol

Handoff is deliberately fail-safe:

1. Write `HANDED_OFF` to the local record first.
2. Update the OCI `artifact-state` tag to `HANDED_OFF`.
3. Re-read OCI and record confirmation locally.
4. Present the artifact and its OCID to the user.

If interruption occurs during handoff, either side being other than `IN_TEST`
blocks automated destruction.  Returning a handed-off artifact to test control
requires a new explicit user instruction; automation never performs that
transition on its own.

Human interaction outside this handoff cannot be detected reliably.  A person
who wants to keep an `IN_TEST` artifact should request handoff before placing
valuable data on it.

## Expired-run review and reaping

The local controller exposes two bounded operations:

```sh
validation-lifecycle.scm review --root ~/.oracle-validation/runs
validation-lifecycle.scm reap --root ~/.oracle-validation/runs --yes
```

`review` is read-only. It inventories immediate local run directories and
emits schema-versioned records containing the run and execution identities,
exact instance OCID, expiry, decision, reason, and state-file evidence path.
Missing or malformed state, missing expiry or OCID, unknown state, handoff,
manager mismatch, and unexpired records are protected. Existing checkpoints
written before local expiry was recorded remain protected and are not guessed
into eligibility.

`reap` requires `--yes` and considers only records reviewed as expired. For
each candidate it performs a fresh exact-OCID ownership read immediately
before calling the existing guarded termination operation. A mismatch, OCI
read error, handoff marker, or any incomplete fact is recorded as `skipped`;
it never falls back to inventory, display names, or adoption. Successful and
failed termination attempts are appended to `reaper-outcomes.jsonl`, with
`terminated` and `termination-failed` kept distinct.

Example review record:

```json
{"schema_version":1,"run_id":"20260827T120000Z-stage6","execution_id":"exec-stage6","instance_ocid":"ocid1.instance.example","expires_at":"2026-08-27T00:00:00Z","decision":"eligible","reason":"expired-awaiting-fresh-ownership","evidence_path":".../state.scm"}
```

The review/reaper implementation is an offline controller surface. It adds no
daemon, retained-instance mode, automatic adoption, MCP server, or OCI
inventory mutation. A live OCI acceptance run is outside this stage.

## Repeatability and pre-authorization

During live work, treat repeated command construction or repeated approval
prompts as a design signal.  Before repeating an action again, consider:

1. Can it become a tested, documented script or Make target with explicit
   inputs and locally retained evidence?
2. Is its underlying executable prefix narrow and non-destructive enough for
   persistent pre-authorization?
3. If it mutates cloud state, can the script enforce the complete `IN_TEST`
   ownership gate before acting?

Prefer persistent approval for narrow read-only OCI operations.  Do not seek
broad approval for a shell, a mutable repository wrapper, or an OCI command
family that also contains destructive subcommands.  Record each new reusable
operation in the restart checkpoint after its first successful live test.

## Existing resources

This policy is not retroactive.  Existing artifacts without all required tags
and a matching local record are protected.  They may be adopted into
`IN_TEST` only through an explicit operation that records their current OCID,
tags, and scope.  The unrelated `oracle-linux-e2-micro-20260822` instance is
protected and must never be adopted implicitly.
