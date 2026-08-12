# Roadmap: "My Friend Clicks a Button and Has Guix on Oracle"

**Status: in progress.** Recorded 2026-08-08. Steps 1, 2, 4, 5 and 6 are done —
step 1 and step 2 both **verified on live instances (2026-08-11)**. Only step 3
(the console-only walkthrough, documentation plus screenshots) remains.

## The target

Someone who has never used Guix System, and does not have Guix installed
anywhere, creates an Oracle Cloud free-tier account, makes a few choices,
waits, and ends up on a running Guix system that looks like theirs.

## Why this was impossible before

Two facts combined to force one image build per person:

1. **The pipeline required Guix on the builder's machine.**
   `oracle/scripts/01-setup-client.scm` runs `guix install python`;
   `02-build-image.scm` runs `guix system image`. Someone who has never used
   Guix cannot run either.
2. **The SSH key was baked into the image**, because Guix has no cloud-init.
   `oracle/README.md` said so outright: "there is no
   `--metadata ssh_authorized_keys` — that only works for images running
   cloud-init."

Fact 2 is what made fact 1 unavoidable. A published image cannot contain a
stranger's key, so everyone needed their own build, so everyone needed Guix.

## Step 1 — Instance-metadata SSH keys (DONE)

`%metadata-ssh-key-service` in `oracle/image/oracle-image.scm`: a shepherd
one-shot that reads
`http://169.254.169.254/opc/v2/instance/metadata/ssh_authorized_keys` and
installs the keys into `~guix/.ssh/authorized_keys`.

That single service breaks the deadlock. `--metadata ssh_authorized_keys=...`
now works at launch — which is also what the OCI console's **Add SSH keys** box
populates — so **one published image serves everyone**.

Design points worth not re-deriving:

- **Writes to `~/.ssh/authorized_keys`, never
  `/etc/ssh/authorized_keys.d/`.** Guix's `openssh-service-type` *deletes and
  recreates* that whole directory at activation
  (`gnu/services/ssh.scm`, `delete-file-recursively`). Both locations are
  consulted, because Guix sets
  `AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2 /etc/ssh/authorized_keys.d/%u`,
  so the baked-in key and the metadata key coexist and neither clobbers the
  other.
- **The baked-in key is now optional.** Absent `authorized-key.pub`, the image
  builds with no key at all — the generic case. Present, it is baked in as
  before, so an existing personal workflow is unchanged. Both paths verified to
  evaluate to an `<operating-system>`.
- **IMDSv2 requires the `Authorization: Bearer Oracle` header.** v1 is a
  fallback for older instances and may be disabled outright.
- **wget, not Guile's `(web client)`.** The header parsers in `(web http)`
  validate known header names against typed values, and `authorization` is one
  of them — passing it a raw string is a trap.
- **Never fails the boot.** A one-shot returning `#f` shows as a failed service;
  "no metadata" is the *correct* state during a local QEMU smoke test. The log
  line is the signal.
- **Only installs lines that look like public keys.** The endpoint returns an
  HTML error body in some failure modes, and writing that into
  `authorized_keys` would fail silently and confusingly.

### Verified on the live instance (2026-08-08)

Probed from the running `guix-oracle` box with `oracle-verify-metadata`:

| Probe | Result |
|---|---|
| `wget` present | OK — `/run/current-system/profile/bin/wget` |
| IMDSv2 **with** the Bearer header | OK — endpoint answers |
| IMDSv2 **without** the header | fails — the header is genuinely required |
| IMDSv1 fallback | OK — live on this tenancy |
| `.../metadata/ssh_authorized_keys` | 404 — instance launched without `--metadata`; the service's "no metadata" path |
| leaf value format (`/opc/v2/instance/shape`) | **raw**, `VM.Standard.E2.1.Micro`, no JSON quotes |

So the endpoint, the header, the tool and the value format are measured, not
assumed. The `unquote-value` guard turns out to be a no-op on this format and
is kept as cheap insurance.

### VERIFIED ON A LIVE INSTANCE (2026-08-11)

**The gate passed.** On a real launch with the key supplied via
`--metadata ssh_authorized_keys`, the service logged:

```
metadata-ssh-keys: ...ssh_authorized_keys not reachable yet; retrying for ~2 min
metadata-ssh-keys: reached ...ssh_authorized_keys on attempt 4
metadata-ssh-keys: installed 1 key(s) into /home/guix/.ssh/authorized_keys
```

and the login worked. Guix writes a baked-in key to
`/etc/ssh/authorized_keys.d/guix` and never to `~/.ssh/authorized_keys`, so the
key can only have come from instance metadata.

**Three bugs had to be fixed to get there**, each found by running it:

1. `authorized-keys` emitted `((guix #f))` when the key file was absent, and the
   builder died on `(open-file #f)`. Evaluation could not catch it — that
   builder only runs at build time.
2. The fetch gave up after ~10s. `networking` is provided when dhcpcd *starts*,
   not when it holds a lease; the metadata address was reachable on **attempt 4**,
   about 20 seconds in. Now retries for ~2 minutes.
3. `read-line` is unbound inside a shepherd gexp — it lives in `(ice-9 rdelim)`.
   Rewritten with core-only primitives.

**One honest caveat.** The confirming launch used an image that also carried a
baked-in key, on purpose: a keyless image that fails leaves no way to log in and
read `/var/log/messages`, which is precisely why the two earlier attempts taught
nothing. The service is verified. The keyless image is confirmed to *build*;
publishing it (step 2) exercises that last inch end-to-end.

**Steps 2 and 3 are unblocked.**

The command that confirmed it, for reference:

```sh
# Launch with a key supplied ONLY via metadata -- no baked-in key in the image
oci compute instance launch ... \
    --metadata '{"ssh_authorized_keys": "ssh-ed25519 AAAA... you@host"}'
ssh guix@<public-ip>
```

That is what `~/.local/bin/oracle-metadata-gate` automates end to end: keyless
build, upload, import, launch with metadata, login, and a verdict read from
`~/.ssh/authorized_keys` plus the service's own log lines.

## Step 2 — Publish one generic image (DONE, 2026-08-11)

Published, imported from its URL, launched, and logged into.

| | |
|---|---|
| Release | <https://github.com/durantschoon/guix-platform-install/releases/tag/oracle-image-20260811> |
| File | `guix-oracle-generic.qcow2`, 585,105,408 bytes (sparse; 50 GB virtual) |
| sha256 | `327ae991eebdd333baf00f315d038113b902564bdea257758aa22baf55106592` |
| Built from | `oracle/image/oracle-image.scm` with `authorized-key.pub` **absent** |

**This closed the "last inch" left open by step 1.** A launch from the published
image with the key supplied only via `--metadata` produced:

```
--- ~/.ssh/authorized_keys ---
# Installed from OCI instance metadata.
ssh-ed25519 AAAA... durant@pop-os
--- /etc/ssh/authorized_keys.d/ ---
total 8            <- empty
```

An empty `authorized_keys.d` is the direct artifact proof that no key is baked
in, which the config-level checks could only infer. The image is genuinely
generic.

### Two traps this step hit

**`import from-object-uri` rejects external URLs.** It accepts only OCI Object
Storage URIs, so the GitHub release URL is refused outright
(`InvalidParameter: Invalid sourceUri`). Two paths therefore exist, and both are
documented:

- **GitHub release** — canonical, checksummed, works for anyone in any tenancy.
  Download, upload to your own bucket, import.
- **Pre-authenticated Object Storage URL** — one-step
  `import from-object-uri`, but tied to this tenancy's bucket and egress.

**A debug image nearly got published.** The build immediately before this one
carried a baked-in key, because the gate had been switched to keep one so its
failures could be read (see step 1's caveat). Publishing *that* would have
authorized one person's key on every instance any stranger launched from it.
Rebuild with `authorized-key.pub` stashed, and verify:
`/etc/ssh/authorized_keys.d/` must be **empty** on a booted instance. Do not
rely on the store hash differing — check the artifact.

**Free-tier limit, not capacity.** Launching a third `E2.1.Micro` returns
`LimitExceeded: standard-e2-micro-core-count` — two are allowed. That is a
different failure from `Out of host capacity` and needs different advice, which
is why `04-deploy.scm`'s `launch-error-kind` distinguishes them.

## Step 3 — The console-only path

With steps 1-2 done, the friend needs no CLI and no Guix at all:

1. Create OCI account
2. Import image from the published URL
3. Launch, pasting their public key into the console's **Add SSH keys** box
4. `ssh guix@<ip>`
5. Run the `personal-config.scm` one-liner from
   [PERSONAL_CONFIG_CONTRACT.md](PERSONAL_CONFIG_CONTRACT.md)

Deliverable is documentation plus screenshots, not code.

## Step 4 — Preferences

`oracle-image.scm` hardcodes `%user-name "guix"`, `%host-name "guix-oracle"`,
`%timezone "America/New_York"`, and the locale.

With a shared image these **must** move out of the build and into first
boot/postinstall — you cannot bake a stranger's timezone into an image everyone
downloads. That makes postinstall the right home anyway.

Note that `CHECKLIST.md`'s **R1** (preference prompts) targets framework-dual's
**Go** config generator and does not help here; oracle is a separate Guile path.
Oracle's preferences are closer in shape to the personal-config contract than to
R1 — likely the same prompt-and-apply mechanism.

Minimum useful set: hostname, timezone, login shell, user name.

## Step 5 — Capacity handling (DONE, stage 01)

`04-deploy.scm` now classifies launch failures (`capacity` / `limit` / `other` /
`none`), walks the remaining availability domains on a capacity refusal — a
bounded one-pass walk, **not** a retry loop — and on exhaustion exits 1 with
advice naming `VM.Standard.A1.Flex`, a different region, and retrying later.

**Reasoned, not observed.** The 2026-08-08 deployment got capacity on the first
AD, so this path has never run against a real refusal. The fixtures in
`oracle/tests/test-oracle-capacity.scm` (24 checks, offline) are hand-written
from Oracle's documented error forms, not from transcripts. Failure directions
are safe: the script stops with the CLI's own text and never launches twice.

The A1.Flex advice is a **pointer, not a flag** — this repo's image is x86_64
and will not boot on ARM. Making that advice actionable needs an aarch64 image,
which is not staged.

## Step 6 — Web UI

**Status: presentation-only version DONE** (`web/index.html`, stage 02). The
scope question below is therefore settled in favour of the first bullet: the
page explains the flow, shows the commands, links the docs, and deploys
nothing. It has no form, input, or textarea anywhere in it, and makes no
network request at runtime. The "driving the deployment" bullet remains
**not started and not approved**.

Because steps 2 and 3 are still open, the page states in its own status section
that the published generic image does not exist and that the metadata SSH key
service has not been verified on a live instance. Those two sentences come out
of the page when — and only when — the corresponding steps are actually done.

The original scoping question, kept because it is why the answer is what it is:

- **Presentation only** (static, safe): explains the steps, generates the exact
  commands to paste, links the published image. No credentials, no backend.
- **Driving the deployment** (needs real thought): anything that launches OCI
  resources on someone's behalf needs their credentials. Do **not** build a
  service that accepts other people's OCI API keys. If the UI is to launch
  anything, it should generate a config the user runs locally, or lean entirely
  on OCI's own console + Resource Manager stack.

The honest recommendation: build the presentation-only version first. It is most
of the value at a fraction of the risk, and OCI's console already provides the
authenticated UI.

## Order and effort

| Step | Effort | Blocked by |
|---|---|---|
| 1. Metadata SSH keys | Medium | **DONE and VERIFIED** on a live instance 2026-08-11 |
| 2. Publish generic image | Small | ✅ **DONE** 2026-08-11 — released, imported, launched, verified keyless |
| 3. Console-only path docs | Small | **UNBLOCKED — the only step left** |
| 4. Preferences at first boot | Medium | Step 1 verified |
| 5. Capacity handling | Small | **DONE** — stage 01; reasoned, never seen a real refusal |
| 6. Web UI (presentation) | Medium | **DONE** — `web/index.html`; hedges on steps 2-3 until they land |

Everything is downstream of one live-instance test.
