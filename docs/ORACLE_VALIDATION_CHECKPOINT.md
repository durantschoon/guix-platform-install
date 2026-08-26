# Oracle validation restart checkpoint

Update this file after every meaningful live-cloud action.  A future session
should be able to resume from this file without relying on chat history.

## Last update

- Time: 2026-08-25 23:25 America/New_York
- Objective: prove that the generic Guix image accepts an ephemeral SSH key
  supplied only through OCI instance metadata.
- Last verified fact: OV-3 Stage 0 and Stage 1 pass/fail acceptance runs all
  completed with automatic termination.

## Live resources

Inventory was read from OCI at the time above.

- `guix-metadata-diagnostic-session-20260825`
  - OCID: `ocid1.instance.oc1.iad.anuwcljth2vmswacutivrrz2zekevq5zyrjg2ydq6ywd2v4fbcspeinakppq`
  - Shape: `VM.Standard.E2.1.Micro`
  - State: `TERMINATED` (termination work request `SUCCEEDED`, 100%, at 09:35
    EDT)
  - Ownership: created for this metadata diagnostic; termination requested with
    boot-volume preservation disabled after evidence collection.
- `oracle-linux-e2-micro-20260822`
  - OCID: `ocid1.instance.oc1.iad.anuwcljth2vmswacrabzv72oinsxfebo7ryzftn2vspbkpvkrz6g2k6yeqna`
  - Shape: `VM.Standard.E2.1.Micro`
  - State: `RUNNING`
  - Ownership: pre-existing and unrelated.  Do not stop, modify, or terminate.
- OV-3 handed-off fixture `20260826T104020Z-34fa-6776a`
  - OCID: `ocid1.instance.oc1.iad.anuwcljth2vmswaccugdhkwcxdtnay2j3ryx4zdru5ih5vus3bw4kqwmzzhq`
  - State: `RUNNING`; local and OCI artifact state both `HANDED_OFF`
  - Ownership: protected after live handoff. Automation must not modify or
    terminate it without a new explicit instruction.

Never select a cleanup target by display name.  Re-read its OCID and lifecycle
state before terminating it.

The `IN_TEST` ownership policy is defined in
`docs/ORACLE_TEST_ARTIFACT_LIFECYCLE.md`.  It is not retroactive: the current
diagnostic instance must be explicitly adopted before the new policy can
authorize unattended mutation or destruction.

## Evidence so far

- OV-2 run `20260825T213011Z-14e40-69253` reproduced the key rejection on the
  revised image: the instance reached `RUNNING`, port 22 became reachable, and
  repeated logins returned `Permission denied (publickey)`.  This distinguishes
  the failure from instance launch, routing, or slow sshd startup.  Evidence is
  under `.oracle-validation/runs/20260825T213011Z-14e40-69253/`; after the
  controller finishes, inspect its serial console specifically for
  `metadata-ssh-keys:` and confirm termination before another launch.
- That run finished after 729 seconds and its exact instance reached
  `TERMINATED`.  The serial console contained no `metadata-ssh-keys:` output.
  Local generation of the Shepherd service then reproduced Guix's warning that
  `metadata-install-from-oci!` was possibly unbound: the compiled service made
  a direct reference to a definition introduced later by `load`.  The fix uses
  `module-ref` after loading and logs service start/runtime exceptions directly
  to `/dev/console`.  All 18 image checks and 35 controller checks pass.
- The corrected OV-3 artifact is
  `.oracle-validation/builds/ov3-runtime-lookup/guix-oracle-generic.qcow2`,
  665,387,008 bytes, SHA-256
  `7a09c626f74d1e86a9b63bf0df122160be00f3a527c3f76b48ba24c6bcb62c77`;
  `qemu-img check` reports no errors.  OCI image OCID:
  `ocid1.image.oc1.iad.aaaaaaaalntwxbrflr5nz6h2d3kuseodvnjhledqrd4khk7moflfrjegrwja`.
- Timing history is stored under ignored `.oracle-validation/` state and shown
  by `make oracle-timings`.  Current first-sample baselines are build 256s,
  upload 421s, import-to-available 478s, and failed Stage 0 total 729s.  Timed
  jobs print their prediction before starting and actual/delta afterward.
- OV-3 Stage 0 run `20260826T040146Z-b39-9e2ba` passed in 99 seconds versus
  the 729-second prediction. Serial evidence shows service start, four retries,
  and `installed 1 key(s); directory mode 0700, file mode 0600`; metadata-only
  SSH then succeeded. The exact instance OCID and termination are recorded in
  that run's `state.scm`. The early Guile segfault remains a separate follow-up.

- The first Stage 0 run is under
  `.oracle-validation/runs/20260824T200854Z-2573-13e84/`.
- That image reached a Guix login prompt, but ephemeral-key SSH authentication
  failed.  The probe instance was terminated.
- The console log contains an early Guile segfault, followed by an otherwise
  successful boot to the login prompt.
- A revised generic image was imported and the diagnostic instance listed
  above was launched from it.  OCI metadata contained the exact intended key,
  IMDSv1 was disabled, and the image booted, but `guix` SSH authentication
  failed with `Permission denied (publickey)`.
- Complete diagnostic evidence is under
  `.oracle-validation/evidence/metadata-diagnostic-20260825/`.
- `~/.oci/config` and its configured private key exist with mode 600.  The
  private key's derived public-key fingerprint matches the configured
  fingerprint.  Do not copy either credential into the repository or guest.

## Exact next action

OV-4 is complete for the one-shot pass/fail contract. OV-5 offline
implementation is active: the JSONL event/replay layer validates monotonic
sequences, permits reconnect overlap, and fails on gaps or malformed records.
Next, connect that layer to a durable guest journal and bounded reconnect loop.
OV-3 now performs the required fresh OCI-tag ownership comparison before
cleanup, so the OV-5 forced-disconnect live gate may proceed after its offline
implementation passes.

OV-3 is complete. It records the declared ownership/scope fields and gates
both Stage 0 and Stage 1 termination on a fresh exact-instance OCI read. The
OCI CLI `join`/`to_string` query shape was verified read-only against the
protected Oracle Linux instance: its absent ownership tags returned `null`, so
the pure gate denies mutation. Guarded `status`, `cleanup`, and fail-safe
`handoff` commands pass 54 offline checks. Purpose-built live cleanup and
handoff/refusal acceptance both passed. OV-5 durable guest telemetry is next.

Preferred build entry point remains `make oracle-build-generic`; use an explicit
`BUILD_NAME` for each diagnostic generation so prior artifacts remain intact.

## Worktree state

The Oracle validation implementation is intentionally still uncommitted.  It
includes the Stage 0 probe, Stage 1 validator, helpers, tests, macOS OCI client
resolution, documentation, and manifest/test integration.  Run `git status
--short` before editing and preserve all existing changes.

Standing workflow rule: watch for repeated actions and approval prompts.  Turn
them into narrow tested scripts or Make targets where useful, and request
persistent pre-authorization only for command prefixes whose effects are safely
bounded.  Record the first successful live test here.

The root `.env` is gitignored and supplies non-secret `ORACLE_IMAGE_ID`,
`ORACLE_SUBNET_ID`, `ORACLE_INSTANCE_ID`, and `ORACLE_EVIDENCE_DIR` defaults to
Make.  Update or clear the instance/evidence values when the active test
artifact changes.  Never place OCI credentials or private-key paths there.

## Session log

- 2026-08-26: Wired the OV-3 deny-by-default ownership gate into both
  disposable controllers. The Oracle suite passes 51 checks, including absent
  tags, stale run IDs, OCID mismatch, undeclared scope, both handoff states,
  and an interrupted local handoff marker.
- 2026-08-26: Added exact-run lifecycle commands. Handoff records local
  protection before OCI mutation and confirms exact OCID/run/state afterward.
  Syntax loading, 54 Oracle checks, and diff checks pass.
- 2026-08-26: OV-3 live acceptance passed. Run
  `20260826T103552Z-f33-2b88d` terminated through the fresh ownership gate and
  OCI confirmed `TERMINATED`. Run `20260826T104020Z-34fa-6776a` was handed
  off, confirmed by fresh OCI read, and guarded cleanup correctly refused it.
- 2026-08-26: Began OV-5 offline. Added dependency-free sequenced JSONL event
  encoding and replay validation. All 41 Oracle validation checks pass,
  including deliberate gap, malformed-event, and reconnect-overlap cases.
- 2026-08-26: OV-4 passing run `20260826T040957Z-556e-be8fb` completed in
  103s (prediction 89s); failing run `20260826T041155Z-5ed1-4bec7` correctly
  returned failure for `exit 7` in 119s. Both disposable instances terminated.
- 2026-08-26: Added bounded authenticated-SSH readiness polling to prevent
  Stage 1 racing the metadata key installation service.

- 2026-08-24: first live metadata-only probe booted but SSH failed; instance
  terminated and evidence retained locally.
- 2026-08-25: OCI access restored from the existing `~/.oci` key pair and
  config.  Authentication verified with a read-only region-subscription call.
- 2026-08-25: corrected live inventory found the diagnostic instance and the
  unrelated Oracle Linux instance both running.  An initial inventory using an
  obsolete tenancy OCID failed read-only with `NotAuthorizedOrNotFound`; no
  cloud state changed.
- 2026-08-25: added the non-destructive `oci-inspect.scm` interface.  Its
  `auth` and `inventory` commands passed a live smoke test, and all 34 offline
  Oracle validation checks passed.
- 2026-08-25: defined the `IN_TEST` / `HANDED_OFF` ownership boundary.  New
  validation launches carry the required OCI tags; existing resources remain
  protected unless explicitly adopted with a matching local record.
- 2026-08-25: added GNU Make entry points for tests, read-only OCI inspection,
  evidence capture, and Stage 0/1 disposable runs.  Generic destruction remains
  unavailable until the ownership gate is executable.
- 2026-08-25 08:48 EDT: refreshed inventory through `make oracle-inventory`.
  Both recorded instances remain `RUNNING`; the diagnostic instance still
  needs evidence collection and cleanup.  The OCI response took about three
  minutes, so a future status helper should expose an explicit timeout.
- 2026-08-25 09:01-09:32 EDT: captured instance, VNIC, console, and SSH
  evidence.  Stage 0 failed despite an exact metadata/local-key match.  The
  diagnostic instance was submitted for termination without preserving its
  boot volume; its VNIC is gone and the termination work request remains in
  progress.  The unrelated Oracle Linux instance was not modified.
- 2026-08-25 09:35 EDT: termination work request reached `SUCCEEDED` at 100%.
  Cleared the stale instance and evidence defaults from `.env`; retained the
  generic image and subnet defaults for the next Stage 0 attempt.
- 2026-08-25: OV-1 completed. Added bounded metadata retry, serial-console plus
  stderr outcomes, generic-image failure visibility, baked-key fallback
  behavior, deterministic ownership/modes, pure retry/parsing tests, and OCI
  connection/read timeouts. Pre-deploy validation passed 6/15/0; all Go suites
  passed on the host and all Guile/Guix suites passed in the existing local
  Guix container. OV-2 is active; runtime success remains unverified.
- 2026-08-25 13:26 EDT: OV-2 generic image build completed. The first build
  attempt downloaded the closure but Docker's default seccomp profile denied
  Guix's cross-build `personality(2)` call. The store layer was committed to
  `guix-oracle-build-cache:ov2-current`; the build wrapper now uses
  `seccomp=unconfined` and resumes from that cache. Guix then produced
  `/gnu/store/h1j10hi7ngz4g1vls189immr0g6yjdlx-image.qcow2`. The local copy's
  SHA-256 matches its sidecar, and `qemu-img info` reports clean, non-corrupt
  QCOW2 with virtual size 53,730,082,816 bytes and actual size 665,124,864
  bytes. A checksum-sidecar path bug was corrected to use a portable basename.
- 2026-08-25 21:30-21:42 EDT: OV-2 Stage 0 reproduced `Permission denied
  (publickey)` after sshd became reachable.  The instance was terminated.  Its
  console lacked every metadata-helper marker; generated-service inspection
  identified the compiled/dynamic-load unbound-reference defect.
- 2026-08-25 23:05-23:25 EDT: built, structurally verified, uploaded, and
  imported OV-3 with explicit runtime lookup and serial-visible boundaries.
  Added resumable image import and historical prediction/actual timing tooling.
