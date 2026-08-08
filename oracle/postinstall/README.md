# Oracle: First Boot

`image/oracle-image.scm` builds a system that boots, takes an SSH key, and has a
swap file. That is all it has. It carries no editor beyond `nano` and `mg`, no
`git`, no shell but bash — deliberately, because the image is generic and your
preferences are not.

This is step two: turning that into your machine.

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
