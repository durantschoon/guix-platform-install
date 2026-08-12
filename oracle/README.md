# Guix System on Oracle Cloud Infrastructure (Always Free)

✅ **Status: verified end-to-end on 2026-08-08.** The image built, passed the QEMU smoke test, uploaded, imported, and launched as a running instance with sshd answering on its public IP. The whole flow is scripted in `scripts/` (see below); the manual commands in this file are kept as the reference for what the scripts do.

**For a newcomer's walkthrough** rather than this reference, see
[the web page](https://durantschoon.github.io/guix-platform-install/)
([`../web/index.html`](../web/index.html)) — the same flow written for someone
who has never used Guix, with an explicit list of which parts are not finished.

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

## Prerequisites

- Guix on x86_64 (verified with `17c2142`)
- `oci` CLI configured — `oci iam region-subscription list` should return your regions
- Your SSH **public** key at `oracle/image/authorized-key.pub`

**The SSH key is baked into the image.** Guix has no cloud-init, so there is no way to inject a key at launch. Get it wrong and the instance is unreachable except via the serial console — password auth is disabled by design.

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
