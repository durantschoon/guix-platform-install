# Screenshots for the walkthrough

Roadmap step 3. Two OCI console screens, because they are the two places a
newcomer gets stuck and prose does not substitute for a picture of them.

Drop the files here with these exact names; `web/index.html` will reference them
and the Pages workflow deploys the whole `web/` directory.

## 1. `import-image.png`

**Compute → Custom Images → Import image**, with the dialog filled in.

The two fields that matter, and that people get wrong:

- **Image type: QCOW2**
- **Launch mode: Paravirtualized** — choosing *Native* (UEFI) produces an
  instance that never boots, with no useful error

Fill in the object you uploaded so the dialog looks realistic, but see the
redaction list below before capturing.

## 2. `add-ssh-keys.png`

**Compute → Instances → Create instance**, scrolled to the **Add SSH keys**
section, with "Paste public keys" selected and a key visible in the box.

That box writes to the same `ssh_authorized_keys` instance-metadata field the
image's `%metadata-ssh-key-service` reads at first boot. It is the entire reason
a published image can be generic, so it is worth a picture.

## Redact before saving — this page is public

The page is served at
<https://durantschoon.github.io/guix-platform-install/>, so anything legible in
these images is published permanently. Blur or crop:

| Redact | Why |
|---|---|
| Tenancy and compartment OCIDs | identify your account |
| Namespace string | ties the bucket to your tenancy |
| Account / user name, email, avatar | personal |
| Region, if you would rather not say | narrows you down |
| Any public IP | your live instance |
| Pre-authenticated request URLs | **anyone holding one can download the object** |

An **SSH public key is safe to show** — it is public by construction. Your
*private* key obviously is not, and never appears in these screens.

## Capture tips

- Crop to the dialog, not the whole browser — no tabs, no bookmarks bar, no
  other tenancies in a switcher
- PNG, and keep each under ~300 KB if you can; they are committed to the repo
  and downloaded by every visitor
- Light theme reads better against the page's own styling, but either works —
  the page is styled for both

Once both files are here, say so and the markup goes into `web/index.html`.
