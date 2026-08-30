# Personal Multi-Machine Sync Quickstart

Before diving into a massive, public peer-to-peer network, GIPS is
immediately useful for a much simpler problem: **keeping your own machines
perfectly synchronized.**

If you have a powerful desktop that compiles your Guix packages, you can use
GIPS to serve those binaries to your laptop without recompiling them from
scratch.

This page is the whole walkthrough, top to bottom: prerequisites, the two
keys, builder setup, consumer setup, the daily workflow, and what to look at
when the laptop builds from source anyway.

## Why GIPS instead of standard Guix tools?

Guix already has tools for this, but GIPS solves their biggest pain points
via IPFS zero-config networking:

- **vs. `guix publish` (the HTTP server):** `guix publish` requires your
  laptop to have a direct network path to your desktop. You have to be on the
  same local network, or configure a VPN (like Tailscale), open router ports,
  and set up dynamic DNS. **GIPS requires zero network configuration.** IPFS
  handles NAT traversal and hole-punching automatically. If both machines
  have internet, they will find each other.
- **vs. `guix copy` (SSH transfer):** `guix copy` is a manual push mechanism
  that requires SSH access. It doesn't transparently intercept normal `guix
  install` or `guix pull` commands. **GIPS works natively as a standard
  substitute server.**

As a bonus, if you introduce a third machine (like a home server), as soon as
the laptop downloads a package from the desktop it automatically seeds it to
the server. Downloads get faster the more devices you sync.

## Prerequisites

On the **builder** (the machine that compiles):

- **Guix** — `guix build -m` and `guix gc --requisites` compute what a
  manifest actually pulls in, so the push side genuinely needs Guix.
- **IPFS (Kubo)** — `ipfs daemon`, the swarm the bytes travel over.
- **Guile**, plus **guile-gcrypt** — `gipsd` signs each served narinfo by
  shelling out to Guile and asking libgcrypt, exactly as Guix does. Without
  `guile-gcrypt` on the interpreter's load path, `[guix_signing]` fails at
  request time.
- **GNUnet (`gnunet-gns`)** — only if you want a stable published name.
  Optional for a first run; the workflow below uses one.
- **GIPS itself** — `gipsd` and `gips` from this repository.

On the **consumer** (the laptop that installs):

- **Guix**, **IPFS (Kubo)**, and **GIPS**. No Guile and no GNUnet are needed
  to *consume*, and the consumer generates no keys of its own.

## The two keys

GIPS has two signing keys and they are not interchangeable. Almost every
"why is my laptop still compiling?" question is one of them being missing.

- The **feed key** is GIPS-internal: Ed25519, PKCS#8/SPKI PEM, made by `gips
  key generate-feed`, configured under `[trust]`. It is how the consumer's
  **`gipsd`** decides whether to believe the builder's feed. `guix` never
  sees it.
- The **Guix key** is Guix-native: a libgcrypt key in Guix's own s-expression
  format, made by `gips key generate-guix`, configured under
  `[guix_signing]` and authorized into `/etc/guix/acl`. It is how the
  consumer's **`guix-daemon`** decides whether a substitute may enter the
  store.

The formats are not convertible, and neither key can do the other's job. Each
step below says which key it is about.

Two example configuration files ship with the repository and are parsed by a
test in `bases/gips-config`, so they cannot drift from what `gipsd` accepts:

- [`examples/gipsd-builder.toml`](../examples/gipsd-builder.toml)
- [`examples/gipsd-consumer.toml`](../examples/gipsd-consumer.toml)

Read them alongside this page; every field is commented with the ceremony
that produces it.

## Builder setup (the desktop)

### 1. Generate the feed key (once)

```bash
gips key generate-feed
```

This writes `feed-signing-key.pem` (PKCS#8 private) and
`feed-signing-key.pub.pem` (SPKI public) into your config directory, both
0600 inside a 0700 directory, and refuses to overwrite an existing pair — the
only thing that can verify a signature you already published is the key that
made it. Print the public half again whenever you need it:

```bash
gips key export-feed
```

### 2. Generate the Guix key (once)

```bash
gips key generate-guix
```

Same ceremony, different key: this writes `signing-key.sec` and its sibling
`signing-key.pub`. The public half is a `guix publish`-format key, so an
unmodified `guix` understands it.

```bash
gips key export-guix
```

### 3. Configure `gipsd`

Copy [`examples/gipsd-builder.toml`](../examples/gipsd-builder.toml) to
`<config dir>/gipsd.toml` (`~/.config/gips/gipsd.toml` on Linux), then edit
the paths and `publisher_gns_name`. It carries both keys: `[trust.signing]`
for the feed key and `[guix_signing]` for the Guix key, with a comment on
each field naming the command that produced it.

`[trust.signing]` is not optional on a builder: publishing signs every feed
entry, so without that block — or without its `publisher_gns_name` — the
daemon answers `500` and `just sync-push` fails rather than publishing
something unsigned.

With no `[guix_signing]` block at all, narinfos are served unsigned exactly
as they were before signing existed. Absence means off; there is no
half-configured state.

If you keep your configuration in Guile instead, the `[guix_signing]` half
has a Scheme equivalent:

```scheme
(gipsd-configuration
 #:guix-signing
 (guix-signing #:secret-key "~/.config/gips/signing-key.sec"))
```

The Scheme emitter in `scheme/gips/config.scm` covers
`trusted-publishers`, `allow-unsigned?` and `guix-signing`; it has no
`[trust.signing]` block yet, so a builder's *feed* key still has to be named
in TOML (recorded in `docs/TODO.md`).

### 4. Restart the daemon

```bash
just daemon
```

`gipsd` reads its configuration at start-up, so a key or a `[trust]` change
takes effect only after a restart. Watch the lines it logs while starting: it
says which key it will sign narinfos with, and a Guix key that is missing or
readable by other users is reported there rather than at the first request.

## Consumer setup (the laptop)

### 1. Copy both public keys over

Copy the output of `gips key export-feed` and of `gips key export-guix` from
the builder over any channel you can eyeball — or discover the Guix key directly
via GNS using `gips key fetch-gns --name desktop-sync.gnu` once advertised.

Save the feed key somewhere `gipsd` can read it, for example
`~/.config/gips/desktop-sync.feed.pub.pem`, and the Guix key as
`gips-signing.pub`.

### 2. Trust the builder's feed key

Copy [`examples/gipsd-consumer.toml`](../examples/gipsd-consumer.toml) to
`<config dir>/gipsd.toml` and edit the `[[trust.trusted_publishers]]` entry
so `gns_name` is the builder's `publisher_gns_name` and `public_key` is where
you saved the feed key. Keep `allow_unsigned = false`: with an empty
publisher list and unsigned entries refused, this node accepts nothing from
the network, which is exactly the fail-closed default you want. Restart
`gipsd` afterwards.

The same thing in Guile:

```scheme
(gipsd-configuration
 #:trusted-publishers
 (list (trusted-publisher
        #:gns-name "desktop-sync.gnu"
        #:public-key "~/.config/gips/desktop-sync.feed.pub.pem")))
```

### 3. Subscribe to the builder

Trusting a publisher does not fetch anything from it; resolution runs over
subscriptions. This is the step it is easiest to forget:

```bash
just subscribe desktop-sync.gnu
```

(That is `gips subscribe <gns-name>`, which calls the daemon's `/subscribe`
endpoint, so `gipsd` must be running and the local auth token readable.)

### 4. Authorize the builder's Guix key

```bash
gips key acl authorize --key-file gips-signing.pub
```

Or using native Guix tooling:

```bash
sudo guix archive --authorize < gips-signing.pub
```

That adds the key into `/etc/guix/acl` (or dry-run with `--dry-run` to inspect the proposed change first). You can verify it with `gips key acl check --key-file gips-signing.pub` or list all authorized keys with `gips key acl list`. From then on the laptop's `guix-daemon` accepts substitutes signed by that key, and nothing else relaxes: every narinfo's signature is checked against the ACL, the signed digest is recomputed over the narinfo's own text, and every nar is still verified against its `NarHash` before it enters the store.

To undo it, revoke the key via `gips key acl revoke --key-file gips-signing.pub` or remove the key's entry from `/etc/guix/acl`.

## The workflow

Three `just` targets make syncing your personal profile frictionless. Do the
setup above once; these are the commands you run every day.

### On the builder

Export your active Guix environment to a declarative manifest:

```bash
just sync-export
```

This drops a `sync-manifest.scm` file in your working directory.

Publish that manifest to the swarm under your GNS name:

```bash
just sync-push desktop-sync.gnu
```

Under the hood this runs `gips snapshot create sync-manifest.scm --gns-name
desktop-sync.gnu`, which computes the manifest's closure with `guix build -m`
and `guix gc --requisites`, publishes every path in it through `gipsd`, and
has the daemon sign, pin and publish the snapshot manifest.

### On the consumer

Copy `sync-manifest.scm` over (git, Syncthing, email — it is not secret), and
run:

```bash
just sync-pull sync-manifest.scm
```

This points your local `guix` at your local `gipsd` proxy, pulling the
binaries from the IPFS swarm rather than compiling them. You are now synced.

## Troubleshooting

### The laptop builds from source anyway

This is the common one, and it has three distinct causes. Trust is
fail-closed at every layer, so all three look the same from the outside — a
rejected feed entry ends up as a `404` for that store path, deliberately
indistinguishable on the wire from "this publisher never had it". **The place
to look is the consumer `gipsd`'s own log**, where the reason is printed.

1. **No subscription.** `gipsd` resolves store paths through subscriptions;
   without `just subscribe <gns-name>` there is nothing to resolve against.
   Symptom: no signature-related log lines at all, because nothing was
   fetched to check.
2. **No `[[trust.trusted_publishers]]` entry** (or the wrong `gns_name`, or a
   `public_key` path `gipsd` cannot read). The log names the store path it
   refused; `GET /metrics` (behind the local auth token) counts it under
   `signature_rejected`. Remember the
   `gns_name` here must equal the builder's `publisher_gns_name` — a
   signature whose publisher field does not match the name it arrived under
   is refused even if the key is correct.
3. **The Guix key is not in `/etc/guix/acl`.** Here `gipsd` is happy and
   `guix` is not: the substitute is offered, `guix-daemon` refuses the
   signature, and it falls back to building. Check with `guix archive
   --authorize` (step 4 above) and note that this is a *different* key from
   the one in `[[trust.trusted_publishers]]`.

A useful bisection: if `GET /metrics` on the consumer shows narinfo activity
at all, cause 1 is ruled out; if it shows `signature_rejected` climbing,
you are in cause 2; if `gipsd` serves happily and `guix` still compiles, you
are in cause 3.

None of this is fixed by turning verification off. `allow_unsigned = true`
and `--no-check-signature` exist, and nothing in this walkthrough should ever
need them.

### `401` / "gipsd rejected the auth token"

Every mutating command (`subscribe`, `publish`, `snapshot create`)
authenticates with a token file that `gipsd` writes at start-up. Start
`gipsd` once to create it, or point `--auth-token-file` at the right file;
the environment variable `GIPS_AUTH_TOKEN_FILE` works too, but an explicit
flag beats it. If the token file and the running daemon disagree — usually a
stale file from a previous config home — restart `gipsd`.

### `just sync-push` refuses the run

`gips snapshot create` parses the stdout of `guix build -m` and `guix gc
--requisites` strictly: one line that is not a store path fails the whole
run, naming the line. That is deliberate — a snapshot is a claim about a
*complete* closure, and quietly dropping a line it could not read is how an
incomplete closure gets signed. The usual cause is a Guix that writes
something else onto stdout (a profile hint, a `guix pull` notice). Fix the
manifest or the Guix invocation rather than loosening the parser; rerunning
the exact command after a partial failure is safe, because republishing an
unchanged store path uploads the identical nar under the identical CID.
