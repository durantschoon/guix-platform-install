# Oracle: First Boot

`image/oracle-image.scm` builds a system that boots, takes an SSH key, and has a
swap file. That is all it has. It carries no editor beyond `nano` and `mg`, no
`git`, no shell but bash — deliberately, because the image is generic and your
preferences are not.

This is step two: turning that into your machine.

## First: your host name, timezone and shell

The published image ships **one** host name (`guix-oracle`) and **one** timezone
(`America/New_York`) for everybody, because an image built before you downloaded
it cannot know yours. `preferences.scm` is where they become yours:

```sh
git clone https://github.com/durantschoon/guix-platform-install
cd guix-platform-install
guile --no-auto-compile -s oracle/postinstall/preferences.scm
```

It asks for a host name, a timezone and a login shell (bash, zsh or fish),
shows you exactly what it will change, takes a timestamped backup, and then
**offers** to run `guix system reconfigure`. It never runs it for you — on a
1 GiB `E2.1.Micro` that is slow and leans on the swap file, and it is also the
step that can break the boot, so you pick the moment.

Some details worth knowing before you run it:

- **It needs the repository on disk**, unlike the one-liner below. The editing
  is done by parsing the configuration into S-expressions
  (`lib/guile-config-helper.scm`), not with `sed`, so that helper has to exist
  as a file. Point `GUIX_PLATFORM_INSTALL_ROOT` at a clone if you keep it
  somewhere unusual.
- **`/etc/config.scm` may not exist yet.** An image built by `guix system image`
  ships the system, not the source. If the file is missing, the script recovers
  it from `/run/current-system/configuration.scm` — the generation's own
  provenance record — and makes the copy writable, because that path is in the
  read-only store.
- **Comments in the configuration are lost.** Writing back pretty-prints the
  parsed form, which is the price of not using `sed`. Hence the backup. A
  preference that is already set writes nothing at all, so re-running the script
  to see what it asks is free.
- **A non-bash shell is also added to the system packages.** A `file-append` to
  a shell outside the closure is a login that fails on a machine you can only
  reach by SSH.
- **The user name is deliberately not settable.** Renaming the account moves the
  home directory and orphans `~/.ssh/authorized_keys`, which is the file holding
  the key you log in with. Run `preferences.scm --help` for the reasoning and
  the recoverable alternative.

Then continue with the personal configuration below.

## The one command

SSH in, then:

```sh
wget -qO- https://raw.githubusercontent.com/durantschoon/guix-platform-install/main/postinstall/recipes/add/personal-config.scm \
  | guile --no-auto-compile -s /dev/stdin
```

Nothing needs to be installed first. A fresh Guix System has `wget`, `guile` and
`nss-certs`; the script provisions `git` and `openssh` itself. The pipe is safe
because every prompt reads `/dev/tty`, not stdin.

It will ask for your configuration repository's URL, install git, set up an SSH
key and pause while you register it, clone the repository, and then run whatever
that repository declares in its `guix-personal.scm`.

**Prepare that file first** — it is what makes this one command instead of
twenty. See [../../docs/PERSONAL_CONFIG_CONTRACT.md](../../docs/PERSONAL_CONFIG_CONTRACT.md).
Without one you are offered whatever the script can detect (a `Makefile` target,
a `bootstrap.sh`), which is a fallback, not the design.

## Oracle-specific notes

**Memory.** `VM.Standard.E2.1.Micro` has 1 GiB of RAM. The swap file service in
`oracle-image.scm` exists for exactly this kind of work. `guix install git
openssh` is comfortable; a `guix pull` followed by `guix home reconfigure` is
the part that will use the swap, and it will be slow. Let it run.

**If the clone hangs rather than fails**, check the subnet's security list allows
outbound 443 (HTTPS) or 22 (SSH to the forge). Oracle's default egress rules are
permissive, but a hardened VCN may not be.

**Serial console.** If you break the system with a reconfigure, the image is
configured to put GRUB and a login prompt on `ttyS0` — see the main
[../README.md](../README.md). This script's output is ASCII only so it stays
readable there.

**The key you generate here is a second key.** The one baked into the image
(`image/authorized-key.pub`) authorises *you* to reach the instance. The one this
script generates authorises the *instance* to reach your forge. Do not confuse
them; they point in opposite directions.

## Checking before you deploy

The contract is meant to work on a machine that is awkward to debug. Check it on
one that is not:

```sh
# On your workstation, in this repository
guile --no-auto-compile -s postinstall/recipes/add/personal-config.scm \
      --plan ~/dot_files
```

That prints the full plan — packages, channels, every step and its exact shell
command — and exits non-zero if the contract is malformed.
