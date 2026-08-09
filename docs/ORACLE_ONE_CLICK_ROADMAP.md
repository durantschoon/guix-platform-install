# Roadmap: "My Friend Clicks a Button and Has Guix on Oracle"

**Status: approved future work.** Recorded 2026-08-08. Step 1 is implemented;
step 5 (stage 01) and step 6 in its presentation-only form (`web/index.html`,
stage 02) are implemented; steps 2-4 are not started.

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

### The one thing still unverified

**This has never run on a live OCI instance.** QEMU has no metadata service, so
the local smoke test exercises only the "no metadata available" path. Before
anything downstream is built:

```sh
# Launch with a key supplied ONLY via metadata -- no baked-in key in the image
oci compute instance launch ... \
    --metadata '{"ssh_authorized_keys": "ssh-ed25519 AAAA... you@host"}'
ssh guix@<public-ip>
```

If that login succeeds, the whole roadmap below is unlocked. If it fails, check
the serial console for the `metadata-ssh-keys:` log lines — they name the
failure. **Do not build steps 2-6 before this test passes**; every one of them
assumes it.

## Step 2 — Publish one generic image

Build once with no `authorized-key.pub` present, publish the qcow2 (GitHub
release or a public Object Storage bucket) with a checksum, and document
importing it straight from that URL. Removes the multi-hour build and the
upload from the user's machine.

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
| 1. Metadata SSH keys | Medium | **DONE** — needs live-instance verification |
| 2. Publish generic image | Small | Step 1 verified |
| 3. Console-only path docs | Small | Step 2 |
| 4. Preferences at first boot | Medium | Step 1 verified |
| 5. Capacity handling | Small | **DONE** — stage 01; reasoned, never seen a real refusal |
| 6. Web UI (presentation) | Medium | **DONE** — `web/index.html`; hedges on steps 2-3 until they land |

Everything is downstream of one live-instance test.
