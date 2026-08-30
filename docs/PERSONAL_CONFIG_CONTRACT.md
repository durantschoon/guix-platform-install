# The Personal Configuration Contract

A platform installer in this repository produces a system that boots and does
nothing else: the minimum a machine needs to exist. Everything that makes it
*yours* — shell, editor, keybindings, packages — lives in a repository you
already keep. This document specifies the file you put in that repository so
that turning a fresh machine into your machine is one command.

The one command, on a machine with nothing on it:

```sh
wget -qO- https://raw.githubusercontent.com/durantschoon/guix-platform-install/main/postinstall/recipes/add/personal-config.scm \
  | guile --no-auto-compile -s /dev/stdin
```

That works because a fresh Guix System already has `wget`, `guile` and
`nss-certs`, and because every prompt in the script reads `/dev/tty` rather than
stdin — stdin is the script itself, arriving down the pipe.

## What the script assumes, and what it does not

A fresh Guix System's `%base-packages` contains `guile`, `wget`, `nano`, `sudo`
and about thirty other things. It does **not** contain `git`, `curl`,
`gnu-make`, or the OpenSSH client. Verify on any Guix machine:

```sh
guix repl -q <<'EOF'
(use-modules (gnu system) (guix packages))
(display (sort (map package-name %base-packages) string<?))
EOF
```

So the script provisions `git` (and `openssh`, when your remote is an SSH URL)
into your **user profile** before using them. The user profile, not the system
configuration: `guix install` takes seconds and needs no root, where a `guix
system reconfigure` takes minutes and, on a 1 GiB Oracle Always Free instance,
leans on the swap file. Making a machine able to *fetch* your configuration
should not require rebuilding the system. Anything that ought to persist into
the system closure belongs in the repository being cloned.

One consequence worth knowing: `guix install` cannot change the `PATH` of the
process that called it. The script prepends `~/.guix-profile/bin` to its own
`PATH` after installing, or it would install `git` and then fail to find it.

## The file

Put `guix-personal.scm` at the root of your configuration repository.
(`.guix-personal.scm` is also accepted if you would rather it were hidden.)

```scheme
(personal-config
  (version 1)
  (name "dot_files")
  (description "Durant's personal configuration")

  ;; Installed into the user profile before any step runs.
  (requires "git" "gnu-make" "zsh")

  ;; Optional: copied to ~/.config/guix/channels.scm, with confirmation.
  (channels "channels.scm")

  (steps
    (step (name "links")
          (run "make set_up_links")
          (description "Symlink dotfiles into $HOME")
          (default? #t))
    (step (name "home")
          (run "make apply")
          (description "guix home reconfigure")
          (default? #t))
    (step (name "keyd")
          (run "make setup-keyd")
          (description "Key remapping; physical machines only")))

  (notes "Log out and back in for the login shell change to take effect."))
```

### Top-level keys

| Key | Required | Meaning |
|---|---|---|
| `version` | yes | Must be `1`. A future format change bumps this rather than reinterpreting existing files. |
| `name` | no | Shown in the plan. Defaults to `(unnamed)`. |
| `description` | no | One line, shown under the name. |
| `requires` | no | Package specs installed into the user profile before any step runs. Version qualifiers (`python@3.11`) are allowed. |
| `channels` | no | Path, relative to the repository root, of a `channels.scm` to install as `~/.config/guix/channels.scm`. Offered, never applied silently. |
| `steps` | yes | Ordered list of `(step ...)` forms. At least one. |
| `notes` | no | Printed at the end. What the user must still do by hand. |

### Step keys

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | Unique within the file. Used in prompts and the summary. |
| `run` | yes | Shell command, run from the repository root. |
| `description` | no | What it does, in one line. |
| `default?` | no | `#t` means "part of the one command". Omitted means the step is offered but defaults to no. |
| `working-directory` | no | Subdirectory to run in, relative to the repository root. |

### Unknown keys are an error, deliberately

A lenient parser's failure mode is that your typo'd `(require "git")` is quietly
dropped, the package is never installed, and the step that needed it fails on a
machine you are reaching over a serial console. So the parser rejects any key it
does not know, and names the ones it does:

```
[ERROR] Invalid contract: guix-personal.scm
  unknown key 'require' (expected one of: version, name, description,
  requires, channels, steps, notes)
```

The same applies to duplicate step names, a missing `(run ...)`, a `version`
other than 1, and a file whose top-level form is not `(personal-config ...)`.

## Checking it before you need it

The point of the contract is that it works on a machine you cannot easily debug.
Check it on the machine you *can*:

```sh
# Is the file well-formed, and what would it do?
guile --no-auto-compile -s personal-config.scm --validate guix-personal.scm

# Same, given a repository directory
guile --no-auto-compile -s personal-config.scm --plan ~/dot_files
```

Both print the plan — packages, channels, every step with the exact shell
command, marked `[default]` or `[  opt  ]` — and exit non-zero if the file is
invalid.

If your repository has no contract yet, generate one from what is already there:

```sh
guile --no-auto-compile -s personal-config.scm --init ~/dot_files
```

`--init` reads your `Makefile`'s `.PHONY` declarations and lists them as a
comment beside a stub step, notes whether you have a `channels.scm`, and refuses
to overwrite an existing contract. It guesses; the `EDIT ME` markers are there
because a wrong guess runs a wrong command on a new machine.

## What running it looks like

```
==> Personal configuration bootstrap
  This installs git, fetches your own configuration repository, and
  runs whatever that repository says should run on a new machine.

Configuration repository URL [git@github.com:you/dot_files.git]:
Clone into [/home/guix/dot_files]:

==> Installing git
  Installing: git openssh
  $ guix install git openssh

==> Git identity
Your name for git commits:
Your email for git commits:

==> SSH key
  No key found; generating an ed25519 key with no passphrase.
  $ ssh-keygen -t ed25519 -N '' -C guix@guix-oracle -f /home/guix/.ssh/id_ed25519

  Add this public key to your account on github.com:
    https://github.com/settings/keys

ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... guix@guix-oracle

Press Enter once the key is registered...
```

Then the clone, then the plan, then the steps — each with a yes/no prompt and
its command echoed before it runs.

### The one step that cannot be automated

A newly installed machine holds no key any forge will accept, and no amount of
scripting can paste a public key into a web page for you. So the script stops
and waits there, rather than failing at `git clone` with `Permission denied
(publickey)` and leaving you to work out which of five things went wrong.

Before that pause it adds the host to `known_hosts`, checking the offered
fingerprint against GitHub's published ones rather than trusting blindly on
first use. A mismatch is reported, not fatal: GitHub rotated its RSA host key in
March 2023, and a stale constant in this repository must never be the reason a
machine cannot be bootstrapped. You are shown the fingerprints and asked.

After the pause it verifies with `ssh -T`. Note that a *successful*
authentication to GitHub exits with status 1 and the words "successfully
authenticated", so the exit status alone cannot be the test — the script matches
on the text.

An HTTPS URL skips all of this. It also cannot push, which is why the SSH path
exists at all.

## If you have no contract

The script still gets you somewhere: it clones the repository, looks for a
`Makefile`, `bootstrap.sh`, `install.sh`, `setup.sh` or `home-configuration.scm`,
lists your Makefile's phony targets, and offers to run one. Then it tells you
about `--init`.

Detection is a courtesy for the first time. The contract is the standard,
because detection cannot know which of twenty-four phony targets is the one that
belongs on a new machine — and on your `dot_files` that is exactly the situation:
`apply`, `set_up_links` and `setup-keyd` are all plausible, and `setup-keyd`
refuses to run on Guix System.

## Re-running

Re-running is the normal case: a step fails, you fix it, you run it again. The
repository URL and clone directory are cached in
`~/.config/guix-personal/settings.scm`, so the second run is Enter, Enter. An
existing checkout is not re-cloned — you are offered a `git pull --ff-only`
instead — and an existing `~/.ssh/id_ed25519` is reused rather than regenerated.

## Peer-to-Peer Package Synchronization (GIPS)

If you maintain multiple Guix machines (for example, a Framework 13 laptop, a
home server, and an Oracle Always Free cloud instance), you can also declare
peer-to-peer package substitute synchronization via GIPS in your contract:

```scheme
(personal-config
  (version 1)
  (name "dot_files")
  (description "Personal config with P2P package sync")
  (requires "git" "gnu-make" "zsh" "ipfs")

  (steps
    (step (name "gips")
          (run "guile -s postinstall/recipes/add/gips.scm --headless")
          (description "Provision GIPS P2P package substitute daemon")
          (default? #f))
    (step (name "home")
          (run "make apply")
          (description "Apply home configuration")
          (default? #t))))
```

## Where this sits in the repository's design

`CLAUDE.md` draws a line between the generic installer and one-machine facts:
machine-specific settings leaking into the installer break someone else's
laptop. This contract is how that line is held while still making step two one
command. No personal repository URL, no username, no Makefile target is
hardcoded anywhere in this repository — the URL is prompted for and cached, and
everything else is declared by *your* repository, which is the correct place for
it. `CHECKLIST.md` records personal dotfiles as explicitly out of scope for the
installer; this is the handoff at that boundary, not a violation of it.

## See also

- `postinstall/recipes/add/personal-config.scm` — the implementation
- `postinstall/recipes/add/personal-config_purpose.txt` — why each part is there
- `postinstall/recipes/add/gips.scm` — GIPS post-install setup recipe
- `postinstall/recipes/add/gips_purpose.txt` — GIPS recipe rationale
- `oracle/postinstall/README.md` — first boot on an Oracle instance
- `CHECKLIST.md` R1 — the complementary work: emitting shell and desktop
  preferences into the generated system config at install time
