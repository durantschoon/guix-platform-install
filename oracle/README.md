# Guix System on Oracle Cloud Infrastructure (Always Free)

**Status (2026-08-27): verified through live login and disposable remote execution.** The generic keyless image was published, imported, launched, and accessed with an SSH key supplied only by OCI metadata. The disposable validator has live pass/fail, reconnect/replay, guest-loss, and guarded-cleanup evidence. The bounded one-shot release is still in progress; see the checkpoint linked below.

## How this platform differs from the others

Every other platform in this repo boots the Guix live ISO and runs `guix system init`. **OCI cannot boot an ISO** — it only accepts QCOW2/VMDK custom images uploaded to Object Storage.

So there is no bootstrap script, no numbered install steps, and no Go code here. The whole installer is one declarative file, `image/oracle-image.scm`, built locally and uploaded.

```
guix system image  ->  Object Storage  ->  custom image  ->  instance
   (your machine)         (upload)          (import)        (launch)
```

## The scripted path (recommended)

Four Guile scripts under `scripts/` reproduce the whole verified flow.
Each is idempotent — rerunning after any failure continues instead of
duplicating work. Run them in order from anywhere:

```bash
oracle/scripts/01-setup-client.scm   # oci CLI + ~/.oci config (one-time, interactive)
oracle/scripts/02-build-image.scm    # detached pty build; prints /gnu/store/...qcow2
oracle/scripts/03-smoke-test.scm     # boots it in QEMU, proves SSH + sudo work
oracle/scripts/04-deploy.scm /gnu/store/...-image.qcow2   # upload/import/network/launch
```

`04-deploy.scm` ends by printing the `ssh guix@<public-ip>` command. The
design reasoning and the traps each script encodes (pty requirement,
BatchMode-vs-passphrase false negative, 108-byte unix socket limit,
guest-computed sentinels) are documented in
`scripts/oracle-scripts_purpose.txt`.

## Disposable validation instances

From the repository root, run `make oracle-help` for the supported workflow.
Copy `.env.example` to the gitignored `.env` once and set the current image,
subnet, instance, and evidence-directory defaults.  These are non-secret OCI
identifiers; OCI private keys and config do not belong in `.env`.  Explicit
Make assignments override the defaults.

The read-only/local targets are:

```sh
make oracle-test                 # two portable offline suites
make oracle-test-all             # all four suites; requires Guix
make oracle-test-validation      # focused validator/controller suite
make oracle-auth
make oracle-inventory
make oracle-instance
make oracle-evidence
```

Targets that create disposable `IN_TEST` resources are named by stage:

```sh
make oracle-build-generic
make oracle-stage0
make oracle-stage1 COMMAND='./run-tests.sh'
```

For the bounded release candidate, use the discoverable one-shot target with
all resource and command inputs explicit:

```sh
make oracle-run IMAGE_ID=ocid1.image... SUBNET_ID=ocid1.subnet... \
  SOURCE="$PWD" COMMAND='sha256sum known-good/provenance' YES=--yes
```

This is still a disposable cloud mutation and writes evidence beneath the
run directory. `make oracle-resume-check RUN_DIR=...` performs the offline
restart rehearsal against one exact checkpoint; it never adopts a resource.
The release gate remains human/live: run a declared computation from the
hashed snapshot, verify the result names the exact source/run/execution and
instance identities, and confirm that exact instance reaches `TERMINATED`.

On macOS/ARM, `oracle-build-generic` targets `x86_64-linux` inside the existing
Guix Docker image. It retains a named build container so a cancelled run can be
restarted with its populated Guix store layer. It refuses to run while
`oracle/image/authorized-key.pub` exists.

They retain the controller's confirmation prompt.  Set `YES=--yes` only for
an already-reviewed unattended run. There is intentionally no generic destroy
target. Cleanup is available only for an exact `RUN_DIR` through the executable
ownership gate.

`scripts/validate.scm` is a separate, one-shot path for code that must be
validated on a real Guix System.  OCI credentials remain on the controller;
the guest receives a fresh public SSH key and a source snapshot, then is
terminated after the command finishes.

Before relying on it, prove this image accepts a metadata-only key on a real
instance (the image must contain no baked `image/authorized-key.pub`):

```sh
oracle/scripts/05-verify-metadata-ssh.scm \
  --image-id ocid1.image... --subnet-id ocid1.subnet...
```

Then run a validation:

```sh
oracle/scripts/validate.scm start \
  --image-id ocid1.image... \
  --subnet-id ocid1.subnet... \
  --source "$PWD" \
  --command './run-tests.sh'
```

The source directory is explicit because the command uploads its complete
working tree, including dirty and untracked files.  `.git` and
`.oracle-validation` are excluded.  Results and incrementally received output
are kept under `.oracle-validation/runs/<run-id>/`.  Failures terminate the VM
by default; `--keep-on-failure` is an explicit debugging override and prints
the exact cleanup command.

See [the validation runner plan](../docs/ORACLE_VALIDATION_RUNNER.md) for the
trust boundary, current verification status, and resilient-telemetry stages.
See [the staged work plan](../docs/ORACLE_VALIDATION_STAGES.md) for the active
stage, dependencies, and transition gates.
See [the restart checkpoint](../docs/ORACLE_VALIDATION_CHECKPOINT.md) for the
latest live evidence and exact next action.

Repeatable read-only inspection is available separately from the controllers:

```sh
guile --no-auto-compile -s oracle/scripts/oci-inspect.scm auth
guile --no-auto-compile -s oracle/scripts/oci-inspect.scm inventory
guile --no-auto-compile -s oracle/scripts/oci-inspect.scm instance \
  --instance-id ocid1.instance...
guile --no-auto-compile -s oracle/scripts/oci-inspect.scm evidence \
  --instance-id ocid1.instance... --output-dir .oracle-validation/evidence/name
```

The inspection script cannot launch or terminate instances.  Its `evidence`
command saves instance, VNIC, and best-effort serial-console records locally.

New disposable resources use the [`IN_TEST` / `HANDED_OFF` artifact
lifecycle](../docs/ORACLE_TEST_ARTIFACT_LIFECYCLE.md).  Automated destructive
operations require matching OCI ownership tags and a matching local run record;
missing or inconsistent ownership information always protects the resource.

## Prerequisites

- Guix on x86_64 (verified with `17c2142`)
- `oci` CLI configured — `oci iam region-subscription list` should return your regions
- For the original `02-build-image.scm` -> `04-deploy.scm` path, your SSH
  **public** key at `oracle/image/authorized-key.pub`

The original deploy path still bakes that key into its personal image.  The
image definition now also supports a generic build with no baked key: its
metadata service consumes OCI's `ssh_authorized_keys` field at boot.  The
disposable validator deliberately requires that generic form so every run can
use a fresh key.  Get either mechanism wrong and the instance is unreachable
except via the serial console — password auth is disabled by design.

```bash
cp ~/.ssh/id_ed25519.pub oracle/image/authorized-key.pub
```

## 1. Build the image

```bash
guix system image -t qcow2 --image-size=50G oracle/image/oracle-image.scm
```

Prints a store path ending in `image.qcow2`. `--image-size=50G` makes the root partition already span the OCI boot volume, which is why no first-boot partition-growth service is needed. The qcow2 is compressed and sparse, so the upload stays small despite the nominal size.

## 2. Smoke-test locally before uploading

Strongly recommended — an hour of upload plus import is a slow way to discover the image does not boot. `scripts/03-smoke-test.scm` does all of this unattended, including an actual SSH login test; the manual version:

```bash
IMG=$(guix system image -t qcow2 --image-size=50G oracle/image/oracle-image.scm)
cp "$IMG" /tmp/guix-oracle.qcow2 && chmod +w /tmp/guix-oracle.qcow2   # store is read-only
qemu-system-x86_64 -m 2048 -drive file=/tmp/guix-oracle.qcow2,format=qcow2 -nographic
```

`-nographic` routes everything to the serial line, which is exactly what OCI's console does — so this also verifies the `console=ttyS0` configuration. You should see the GRUB menu, then a login prompt. Exit QEMU with `Ctrl-a x`.

⚠️ **Do not "verify" SSH with `-o BatchMode=yes` and your own key.** If your key has a passphrase, the client cannot sign in batch mode and prints `Permission denied (publickey)` even when the server accepted the key — indistinguishable from a wrong baked-in key until you read `sshd -ddd` output from the server side. The smoke-test script uses a throwaway passphrase-less key for exactly this reason.

## 3. Upload to Object Storage *(verified 2026-08-08)*

```bash
COMPARTMENT=$(oci iam compartment list --query 'data[0]."compartment-id"' --raw-output)  # or your tenancy OCID
NAMESPACE=$(oci os ns get --query data --raw-output)

oci os bucket create --name guix-images --compartment-id "$COMPARTMENT"
oci os object put --bucket-name guix-images --name guix-oracle.qcow2 \
                  --file /tmp/guix-oracle.qcow2
```

## 4. Import as a custom image *(verified 2026-08-08)*

```bash
oci compute image import from-object \
    --compartment-id "$COMPARTMENT" \
    --namespace "$NAMESPACE" \
    --bucket-name guix-images \
    --name guix-oracle.qcow2 \
    --display-name guix-oracle \
    --source-image-type QCOW2 \
    --launch-mode PARAVIRTUALIZED \
    --operating-system "Guix System" \
    --operating-system-version "rolling"
```

**`--launch-mode PARAVIRTUALIZED` is not optional.** It must match the BIOS/MBR layout the `qcow2` image type produces. `NATIVE` (UEFI) would require building `-t qcow2-gpt` with `grub-efi-bootloader` instead.

Import is asynchronous. Poll until `AVAILABLE`:

```bash
oci compute image list --compartment-id "$COMPARTMENT" \
    --display-name guix-oracle \
    --query 'data[0].{state:"lifecycle-state",id:id}' --output table
```

## 5. Launch *(verified 2026-08-08)*

Needs a VCN with a public subnet. The console's **Create VCN with Internet Connectivity** wizard is the fast path; then:

```bash
oci compute instance launch \
    --compartment-id "$COMPARTMENT" \
    --availability-domain "$(oci iam availability-domain list --query 'data[0].name' --raw-output)" \
    --shape VM.Standard.E2.1.Micro \
    --image-id <image-ocid> \
    --subnet-id <subnet-ocid> \
    --assign-public-ip true \
    --display-name guix-oracle
```

**`--metadata ssh_authorized_keys` now works.** It used to not: that field is consumed by
cloud-init, which Guix has no equivalent of, so the key had to be baked in. As of
`%metadata-ssh-key-service` in `image/oracle-image.scm`, a shepherd one-shot reads the key
from the instance metadata service at boot and installs it — so the same field the OCI
console's **Add SSH keys** box populates does the right thing, and one image can serve
anyone. A baked-in `image/authorized-key.pub` is still honoured if present, and the two
coexist. See [../docs/ORACLE_ONE_CLICK_ROADMAP.md](../docs/ORACLE_ONE_CLICK_ROADMAP.md).

*Not yet verified on a live instance* — QEMU has no metadata service, so only the
"no metadata" path is covered locally.

Open port 22 in the subnet's security list, then:

```bash
ssh guix@<public-ip>
```

## If it does not boot

Use the OCI serial console (Instance → Console connection). The image is configured to put GRUB and a login prompt on `ttyS0` precisely for this.

Most likely causes, in order:

1. **Launch mode mismatch** — `PARAVIRTUALIZED` vs. the image's BIOS/MBR layout
2. **Wrong SSH key baked in** — boots fine, refuses your login
3. ~~**Boot volume is `/dev/sda`, not `/dev/vda`**~~ — *resolved 2026-08-08*: it **is** `/dev/sda` (paravirtualized boot volumes attach via virtio-scsi), and `(targets ...)` in `image/oracle-image.scm` now says so. Only relevant if you change the launch mode or shape: verify with `lsblk` before the first `guix system reconfigure`.

## 6. First boot: load your own customizations

The image is deliberately minimal — it has no `git`, no editor beyond `nano` and
`mg`, and bash as the login shell. Step two is one command, run over SSH:

```sh
wget -qO- https://raw.githubusercontent.com/durantschoon/guix-platform-install/main/postinstall/recipes/add/personal-config.scm \
  | guile --no-auto-compile -s /dev/stdin
```

It installs git, generates an SSH key and waits while you register it with your
forge, clones your configuration repository, and runs what that repository
declares in its `guix-personal.scm`.

Prepare that file before you need it — see
[../docs/PERSONAL_CONFIG_CONTRACT.md](../docs/PERSONAL_CONFIG_CONTRACT.md) — and
[postinstall/README.md](postinstall/README.md) for the Oracle-specific notes
(memory, egress rules, and why the key generated here points the opposite way
from the one baked into the image).

## Design notes

`image/oracle-image_purpose.txt` explains every setting and, more usefully, several things deliberately left out — why `initrd-modules` is absent, why the root label must stay `Guix_image`, why swap is a shepherd service rather than `swap-devices`, and why `%wheel ALL=NOPASSWD:ALL` is a consequence of key-only login rather than laziness.
