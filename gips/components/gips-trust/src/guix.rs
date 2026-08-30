//! Guix-native narinfo signatures.
//!
//! # Why none of this is written in Rust
//!
//! A Guix `Signature:` line is *not* an RFC 8032 EdDSA signature, which is
//! what the rest of this crate (the GIPS feed/mirror trust path) produces with
//! `ed25519_dalek`. What `guix publish` emits, and what `guix substitute`
//! checks, is libgcrypt's **RFC 6979 deterministic ECDSA over the Ed25519
//! curve**, wrapped in an advanced-rendered s-expression:
//!
//! ```text
//! (signature
//!  (data
//!   (flags rfc6979)
//!   (hash sha256 #<64 hex digits>#)
//!   )
//!  (sig-val
//!   (ecdsa
//!    (r #<64 hex digits>#)
//!    (s #<64 hex digits>#)
//!    )
//!   )
//!  (public-key
//!   (ecc
//!    (curve Ed25519)
//!    (q #<64 hex digits>#)
//!    )
//!   )
//!  )
//! ```
//!
//! `ed25519_dalek` cannot produce that, and a dalek key derives a different
//! public point from the same seed, so the two key formats are not even
//! convertible. Rather than add a crypto dependency or an FFI binding, GIPS
//! does what Guix does: it asks libgcrypt, through `guile` and
//! `(gcrypt pk-crypto)`. Every byte of every sexp on the wire is rendered by
//! libgcrypt itself — see [`SIGN_HELPER`] — because a hand-written sexp that
//! merely *looks* right is exactly the failure mode this design exists to rule
//! out.
//!
//! The dalek feed key, [`crate::sign_narinfo`] and [`crate::verify_narinfo`]
//! are untouched by any of this. A node can have both keys, one, or neither.
//!
//! # What is signed
//!
//! `narinfo-sha256` in `guix/narinfo.scm` hashes the narinfo's contents up to
//! the *index of the `Signature:` token* — so the trailing newline of the
//! preceding line is inside the hashed region and the `Signature:` line itself
//! is outside it. It also returns `#f`, meaning "this narinfo is unsigned",
//! unless `StorePath:`, `NarHash:` and `References:` all appear in that
//! region. Both rules live in the Guile helper, which refuses to sign a body
//! that would produce a signature Guix silently ignores.

use crate::fsintegrity;
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use serde::{Deserialize, Serialize};
use std::fmt;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

/// The committed key-generation helper, compiled into the binary.
///
/// It is compiled in rather than looked up on disk so that a deployed `gipsd`
/// cannot be pointed at — or silently lose — the script that makes its keys.
/// The file is still a normal, separately runnable Guile script; the oracle
/// test drives it both ways.
pub const KEYGEN_HELPER: &str = include_str!("../guile/guix-keygen.scm");

/// The committed signing helper. See [`KEYGEN_HELPER`] for why it is embedded.
pub const SIGN_HELPER: &str = include_str!("../guile/guix-sign.scm");

/// How long a helper may run before it is killed.
///
/// One signature costs about 40 ms on a warm machine, nearly all of it Guile
/// start-up. Ten seconds is therefore not a performance budget, it is a
/// liveness bound: past it the helper is wedged, and a wedged helper must
/// become a 500 rather than a request that never answers.
pub const HELPER_TIMEOUT: Duration = Duration::from_secs(10);

/// The largest helper stdout that will be accepted.
///
/// A well-formed signature sexp is around 430 bytes. The bound exists so a
/// compromised or confused helper cannot make the daemon buffer an unbounded
/// response; output past it is drained (so the child can exit) and the call
/// fails.
pub const MAX_HELPER_STDOUT_BYTES: usize = 16 * 1024;

/// The largest narinfo body that will be handed to the signer.
pub const MAX_SIGNED_BODY_BYTES: usize = 64 * 1024;

/// How far a helper's stderr is quoted back in an error, matching the Stage 19
/// config-script bound.
const STDERR_EXCERPT_BYTES: usize = 2000;

/// How often the parent checks on a running helper.
const POLL_INTERVAL: Duration = Duration::from_millis(5);

/// The host name used when none is configured and none can be discovered.
const FALLBACK_HOST: &str = "localhost";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// The `[guix_signing]` block. Absent means the feature is off and narinfos are
/// served exactly as they were before this existed.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct GuixSigningConfig {
    /// The advanced-sexp secret key, as written by `gips key generate-guix`.
    ///
    /// The public half is its sibling `.pub` — the same `signing-key.sec` /
    /// `signing-key.pub` pairing Guix uses — so there is no second path to
    /// keep in sync, and no way to configure a `.sec` and a `.pub` that do not
    /// belong together.
    pub secret_key: PathBuf,
    /// What to put in `Signature: 1;<host>;…`. Defaults to this machine's host
    /// name, which is what `guix publish` uses.
    #[serde(default)]
    pub host: Option<String>,
    /// The Guile interpreter to run the helpers with. `None` resolves `guile`
    /// on `PATH` via `/usr/bin/env`, as the Stage 19 config-script path does.
    #[serde(default)]
    pub guile: Option<PathBuf>,
}

/// The public half's path for a given secret key path.
pub fn public_key_path(secret_key: &Path) -> PathBuf {
    secret_key.with_extension("pub")
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Why a signature could not be produced. No variant carries key material.
#[derive(Debug)]
pub enum GuixSignError {
    /// The body is larger than [`MAX_SIGNED_BODY_BYTES`].
    BodyTooLarge { bytes: usize, limit: usize },
    /// The interpreter could not be started at all.
    Spawn { program: String, source: io::Error },
    /// Talking to the child failed.
    Io { source: io::Error },
    /// The helper did not finish within the deadline and was killed.
    TimedOut { timeout: Duration },
    /// The helper exited non-zero. Its stderr is quoted, bounded.
    Failed { status: Option<i32>, stderr: String },
    /// The helper wrote more than [`MAX_HELPER_STDOUT_BYTES`].
    OutputTooLarge { limit: usize },
    /// The helper's stdout is not UTF-8. Guix decodes the payload with
    /// `utf8->string`, so this could never be read back.
    NotUtf8,
    /// The helper's stdout is not the signature sexp it was asked for.
    Malformed { reason: String },
}

impl fmt::Display for GuixSignError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BodyTooLarge { bytes, limit } => write!(
                f,
                "refusing to sign a {}-byte narinfo body; the limit is {}",
                bytes, limit
            ),
            Self::Spawn { program, source } => {
                write!(f, "could not run {} to sign a narinfo: {}", program, source)
            }
            Self::Io { source } => write!(f, "the signing helper could not be driven: {}", source),
            Self::TimedOut { timeout } => write!(
                f,
                "the signing helper did not finish within {:?} and was killed",
                timeout
            ),
            Self::Failed { status, stderr } => write!(
                f,
                "the signing helper exited with {}: {}",
                match status {
                    Some(code) => format!("status {}", code),
                    None => "a signal".to_string(),
                },
                stderr.trim()
            ),
            Self::OutputTooLarge { limit } => write!(
                f,
                "the signing helper wrote more than {} bytes; a signature sexp is a few hundred",
                limit
            ),
            Self::NotUtf8 => f.write_str("the signing helper's output is not valid UTF-8"),
            Self::Malformed { reason } => {
                write!(
                    f,
                    "the signing helper's output is not a signature: {}",
                    reason
                )
            }
        }
    }
}

impl std::error::Error for GuixSignError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Spawn { source, .. } | Self::Io { source } => Some(source),
            _ => None,
        }
    }
}

/// Why a key pair could not be created or read.
#[derive(Debug)]
pub enum GuixKeyError {
    /// A key is already there. Generation never overwrites: the old key is the
    /// only thing that can verify signatures already on the wire.
    AlreadyExists {
        path: PathBuf,
    },
    Io {
        path: PathBuf,
        source: io::Error,
    },
    Integrity {
        source: fsintegrity::IntegrityError,
    },
    /// The generation helper failed; the message is its bounded stderr.
    Helper {
        source: GuixSignError,
    },
    /// This platform cannot create owner-only files, so it cannot hold a key.
    UnsupportedPlatform,
}

impl fmt::Display for GuixKeyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::AlreadyExists { path } => write!(
                f,
                "{} already exists; refusing to overwrite a signing key. Move it aside first if \
                 you really mean to rotate — signatures already published can only be verified \
                 by the key that made them",
                path.display()
            ),
            Self::Io { path, source } => write!(f, "{}: {}", path.display(), source),
            Self::Integrity { source } => write!(f, "{}", source),
            Self::Helper { source } => write!(f, "key generation failed: {}", source),
            Self::UnsupportedPlatform => f.write_str(
                "this platform cannot store a secret key owner-only; refusing to write one",
            ),
        }
    }
}

impl std::error::Error for GuixKeyError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            Self::Integrity { source } => Some(source),
            Self::Helper { source } => Some(source),
            _ => None,
        }
    }
}

impl From<fsintegrity::IntegrityError> for GuixKeyError {
    fn from(source: fsintegrity::IntegrityError) -> Self {
        Self::Integrity { source }
    }
}

// ---------------------------------------------------------------------------
// Running a helper
// ---------------------------------------------------------------------------

/// How the Guile interpreter is named.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Interpreter {
    /// Resolve `guile` on `PATH`, the way the Stage 19 config-script path does.
    Env,
    /// Run exactly this program.
    Explicit(PathBuf),
}

impl Interpreter {
    fn from_config(guile: Option<&Path>) -> Self {
        match guile {
            Some(path) => Self::Explicit(path.to_path_buf()),
            None => Self::Env,
        }
    }

    fn command(&self) -> Command {
        match self {
            Self::Env => {
                let mut command = Command::new("/usr/bin/env");
                command.arg("guile");
                command
            }
            Self::Explicit(path) => Command::new(path),
        }
    }

    fn describe(&self) -> String {
        match self {
            Self::Env => "guile (via /usr/bin/env)".to_string(),
            Self::Explicit(path) => path.display().to_string(),
        }
    }
}

/// Which program the interpreter should run.
#[derive(Clone, Debug)]
pub enum Helper {
    /// A script compiled into this binary, passed with `-c`.
    Embedded(&'static str),
    /// A script on disk, passed with `-s`. Tests point this at stubs; both
    /// forms see the identical `(command-line)`, so a stub and the real helper
    /// are driven by the same code.
    Script(PathBuf),
}

/// Reads at most `limit` bytes, then keeps draining and discarding so the
/// child is never blocked on a full pipe. Returns the bytes and whether more
/// were there.
fn read_bounded<R: Read>(mut source: R, limit: usize) -> io::Result<(Vec<u8>, bool)> {
    let mut kept = Vec::new();
    let mut truncated = false;
    let mut chunk = [0u8; 4096];
    loop {
        let read = match source.read(&mut chunk) {
            Ok(0) => break,
            Ok(read) => read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        let room = limit.saturating_sub(kept.len());
        let take = read.min(room);
        kept.extend_from_slice(&chunk[..take]);
        if take < read {
            // Surplus. Keep reading anyway — a child blocked writing into a
            // full pipe would never exit, and then the *timeout* would be what
            // this call reported instead of the honest "too much output".
            truncated = true;
        }
    }
    Ok((kept, truncated))
}

// ---------------------------------------------------------------------------
// The signer
// ---------------------------------------------------------------------------

/// Signs narinfo bodies by shelling out to the Guile helper.
///
/// Construction never touches the network or fails: a missing or unreadable
/// key becomes a per-request 500, never a silently unsigned 200. Call
/// [`GuixSigner::startup_warnings`] once at start-up to say out loud what is
/// wrong before the first request finds out.
pub struct GuixSigner {
    interpreter: Interpreter,
    helper: Helper,
    secret_key: PathBuf,
    public_key: PathBuf,
    host: String,
    timeout: Duration,
    max_output_bytes: usize,
    /// Counts helper processes actually spawned. This is what makes "the cache
    /// really did prevent a fork" an assertion rather than a hope.
    invocations: AtomicUsize,
}

impl fmt::Debug for GuixSigner {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GuixSigner")
            .field("interpreter", &self.interpreter)
            .field("secret_key", &self.secret_key)
            .field("host", &self.host)
            .finish_non_exhaustive()
    }
}

/// A `Signature:` host must survive `1;<host>;<base64>` being split on `;`.
fn usable_host(host: &str) -> bool {
    !host.is_empty() && host.len() <= 253 && host.chars().all(|c| c.is_ascii_graphic() && c != ';')
}

impl GuixSigner {
    /// Builds a signer from configuration, discovering the host name if the
    /// operator did not pin one.
    pub fn new(config: &GuixSigningConfig) -> Self {
        let interpreter = Interpreter::from_config(config.guile.as_deref());
        let host = match config.host.as_deref() {
            Some(host) if usable_host(host) => host.to_string(),
            // An unusable configured host is not silently accepted *or*
            // silently ignored: it falls back here and is named by
            // `startup_warnings`.
            Some(_) | None => {
                detect_host(&interpreter).unwrap_or_else(|| FALLBACK_HOST.to_string())
            }
        };
        Self {
            interpreter,
            helper: Helper::Embedded(SIGN_HELPER),
            secret_key: config.secret_key.clone(),
            public_key: public_key_path(&config.secret_key),
            host,
            timeout: HELPER_TIMEOUT,
            max_output_bytes: MAX_HELPER_STDOUT_BYTES,
            invocations: AtomicUsize::new(0),
        }
    }

    /// Runs a different script in place of the embedded helper.
    pub fn with_helper(mut self, helper: Helper) -> Self {
        self.helper = helper;
        self
    }

    /// Overrides the liveness bound.
    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// Overrides the stdout bound.
    pub fn with_max_output_bytes(mut self, max_output_bytes: usize) -> Self {
        self.max_output_bytes = max_output_bytes;
        self
    }

    /// The host name that will appear in `Signature: 1;<host>;…`.
    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn secret_key_path(&self) -> &Path {
        &self.secret_key
    }

    /// Returns the last modification time of the secret key file, if it exists.
    pub fn secret_key_mtime(&self) -> Option<std::time::SystemTime> {
        std::fs::metadata(&self.secret_key).ok()?.modified().ok()
    }

    pub fn public_key_path(&self) -> &Path {
        &self.public_key
    }

    /// How many helper processes this signer has started.
    pub fn invocations(&self) -> usize {
        self.invocations.load(Ordering::SeqCst)
    }

    /// Everything worth saying about this signer's configuration before the
    /// first request. Empty means nothing to report.
    pub fn startup_warnings(&self) -> Vec<String> {
        let mut out = Vec::new();
        for (path, expectation, label) in [
            (
                &self.secret_key,
                fsintegrity::Expectation::OwnerOnly,
                "guix signing key",
            ),
            (
                &self.public_key,
                fsintegrity::Expectation::NotWorldWritable,
                "guix public key",
            ),
        ] {
            match fsintegrity::audit(path) {
                Ok(None) => out.push(format!(
                    "{} {} does not exist; every narinfo request will fail with 500 until \
                     `gips key generate-guix` has run",
                    label,
                    path.display()
                )),
                Ok(Some(found)) => {
                    for warning in found.warnings(expectation) {
                        out.push(format!("{} {}", label, warning));
                    }
                }
                Err(error) => out.push(format!("{} {}", label, error)),
            }
        }
        out
    }

    /// The advanced-rendered `(signature …)` sexp over `body`.
    ///
    /// `body` must be the exact bytes served before the `Signature:` token.
    pub fn sign_body(&self, body: &str) -> Result<String, GuixSignError> {
        if body.len() > MAX_SIGNED_BODY_BYTES {
            return Err(GuixSignError::BodyTooLarge {
                bytes: body.len(),
                limit: MAX_SIGNED_BODY_BYTES,
            });
        }
        let sexp = self.run_helper(
            &[
                self.secret_key.as_os_str().to_os_string(),
                self.public_key.as_os_str().to_os_string(),
            ],
            body.as_bytes(),
        )?;

        // Shape check only. Whether the signature is *correct* is not
        // something the caller can determine here — the Guile helper verifies
        // its own output against the public key before printing it, and the
        // oracle test checks the whole thing the way Guix does.
        let trimmed = sexp.trim_start();
        for token in ["(signature", "(sig-val", "(ecdsa", "(public-key", "(data"] {
            if !trimmed.contains(token) {
                return Err(GuixSignError::Malformed {
                    reason: format!("no {} in the helper's output", token),
                });
            }
        }
        if !trimmed.starts_with("(signature") {
            return Err(GuixSignError::Malformed {
                reason: "output does not begin with (signature".to_string(),
            });
        }
        Ok(sexp)
    }

    /// The `1;<host>;<base64>` payload of a `Signature:` line over `body`.
    ///
    /// Guix base64s the *advanced* rendering's UTF-8 bytes — `guix publish`
    /// does `base64-encode(string->utf8(canonical-sexp->string …))` and
    /// `guix/narinfo.scm` reverses it with `utf8->string(base64-decode …)`.
    pub fn signature_payload(&self, body: &str) -> Result<String, GuixSignError> {
        let sexp = self.sign_body(body)?;
        Ok(format!(
            "1;{};{}",
            self.host,
            BASE64.encode(sexp.as_bytes())
        ))
    }

    /// `body` with its `Signature:` line appended — the bytes to serve.
    pub fn signed_narinfo(&self, body: &str) -> Result<String, GuixSignError> {
        Ok(format!(
            "{}{}\n",
            body,
            signature_line(&self.signature_payload(body)?)
        ))
    }

    fn run_helper(
        &self,
        arguments: &[std::ffi::OsString],
        stdin: &[u8],
    ) -> Result<String, GuixSignError> {
        let mut command = self.interpreter.command();
        // `-q` keeps the invoking user's init file out of a process that is
        // about to touch a private key; `--no-auto-compile` keeps it from
        // writing to a cache directory it does not need.
        command.arg("-q").arg("--no-auto-compile");
        match &self.helper {
            Helper::Embedded(source) => command.arg("-c").arg(source),
            Helper::Script(path) => command.arg("-s").arg(path),
        };
        // The `--` separator is what stops a key path that begins with a dash
        // from being read as an option, by us or by Guile.
        command.arg("--");
        for argument in arguments {
            command.arg(argument);
        }
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        self.invocations.fetch_add(1, Ordering::SeqCst);
        let mut child = command.spawn().map_err(|source| GuixSignError::Spawn {
            program: self.interpreter.describe(),
            source,
        })?;

        // stdin, stdout and stderr are each drained on their own thread. A
        // helper that reads nothing, or writes a lot, therefore cannot wedge
        // the parent — the deadline below is the only thing that decides how
        // long this takes.
        let mut sink = child.stdin.take().expect("stdin was piped");
        let payload = stdin.to_vec();
        let writer = std::thread::spawn(move || {
            let result = sink.write_all(&payload).and_then(|()| sink.flush());
            drop(sink);
            result
        });
        let stdout = child.stdout.take().expect("stdout was piped");
        let limit = self.max_output_bytes;
        let reader = std::thread::spawn(move || read_bounded(stdout, limit));
        let stderr = child.stderr.take().expect("stderr was piped");
        let errors = std::thread::spawn(move || read_bounded(stderr, STDERR_EXCERPT_BYTES));

        let deadline = Instant::now() + self.timeout;
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break Some(status),
                Ok(None) => {
                    if Instant::now() >= deadline {
                        let _ = child.kill();
                        let _ = child.wait();
                        break None;
                    }
                    std::thread::sleep(POLL_INTERVAL);
                }
                Err(source) => {
                    let _ = child.kill();
                    return Err(GuixSignError::Io { source });
                }
            }
        };

        // The threads end when the child's pipes close, which killing it does.
        let written = writer.join();
        let out = reader.join();
        let err = errors.join();

        let Some(status) = status else {
            return Err(GuixSignError::TimedOut {
                timeout: self.timeout,
            });
        };

        let (stderr_bytes, _) = err
            .unwrap_or_else(|_| Ok((Vec::new(), false)))
            .unwrap_or((Vec::new(), false));
        let stderr = String::from_utf8_lossy(&stderr_bytes).to_string();

        if !status.success() {
            return Err(GuixSignError::Failed {
                status: status.code(),
                stderr,
            });
        }

        // A write error on a *successful* helper means it exited before
        // reading its input, i.e. it signed something other than what it was
        // given. That is not a success.
        if let Ok(Err(source)) = written {
            return Err(GuixSignError::Io { source });
        }

        let (bytes, truncated) = match out {
            Ok(Ok(pair)) => pair,
            Ok(Err(source)) => return Err(GuixSignError::Io { source }),
            Err(_) => {
                return Err(GuixSignError::Malformed {
                    reason: "the output reader panicked".to_string(),
                })
            }
        };
        if truncated {
            return Err(GuixSignError::OutputTooLarge {
                limit: self.max_output_bytes,
            });
        }
        String::from_utf8(bytes).map_err(|_| GuixSignError::NotUtf8)
    }
}

/// The full `Signature:` line for a payload.
pub fn signature_line(payload: &str) -> String {
    format!("Signature: {}", payload)
}

/// This machine's host name, asked of the interpreter we already require.
///
/// `guix publish` uses `(gethostname)` for the same field, so asking Guile is
/// both the fewest moving parts and the closest match to what a Guix operator
/// expects to see.
fn detect_host(interpreter: &Interpreter) -> Option<String> {
    let output = interpreter
        .command()
        .arg("-q")
        .arg("--no-auto-compile")
        .arg("-c")
        .arg("(display (gethostname))")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let host = String::from_utf8(output.stdout).ok()?.trim().to_string();
    usable_host(&host).then_some(host)
}

// ---------------------------------------------------------------------------
// Key generation and export
// ---------------------------------------------------------------------------

/// Where a freshly generated pair landed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GeneratedKeyPair {
    pub secret_key: PathBuf,
    pub public_key: PathBuf,
}

/// Creates `path` with mode 0600, failing if it is already there.
///
/// `create_new` is `O_EXCL`, so this is also what makes "refuse to overwrite"
/// a race-free claim rather than a check followed by a hope.
#[cfg(unix)]
fn create_new_private_file(path: &Path) -> Result<(), GuixKeyError> {
    use std::fs::OpenOptions;
    use std::os::unix::fs::OpenOptionsExt;

    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
    {
        Ok(_) => Ok(()),
        Err(source) if source.kind() == io::ErrorKind::AlreadyExists => {
            Err(GuixKeyError::AlreadyExists {
                path: path.to_path_buf(),
            })
        }
        Err(source) => Err(GuixKeyError::Io {
            path: path.to_path_buf(),
            source,
        }),
    }
}

#[cfg(not(unix))]
fn create_new_private_file(_path: &Path) -> Result<(), GuixKeyError> {
    Err(GuixKeyError::UnsupportedPlatform)
}

/// Generates a Guix-format signing key pair at `secret_key` and its sibling
/// `.pub`.
///
/// This is a ceremony, not a fallback: it refuses to overwrite either file,
/// because the only thing that can verify a signature already on the wire is
/// the key that made it. Both files are staked out 0600 inside a 0700
/// directory *before* Guile writes into them, so the private half is never
/// briefly world-readable.
pub fn generate_key_pair(
    secret_key: &Path,
    guile: Option<&Path>,
) -> Result<GeneratedKeyPair, GuixKeyError> {
    let public_key = public_key_path(secret_key);
    if let Some(parent) = secret_key.parent() {
        fsintegrity::ensure_private_dir(parent)?;
    }

    create_new_private_file(secret_key)?;
    if let Err(error) = create_new_private_file(&public_key) {
        let _ = std::fs::remove_file(secret_key);
        return Err(error);
    }

    let signer = GuixSigner {
        interpreter: Interpreter::from_config(guile),
        helper: Helper::Embedded(KEYGEN_HELPER),
        secret_key: secret_key.to_path_buf(),
        public_key: public_key.clone(),
        host: FALLBACK_HOST.to_string(),
        timeout: HELPER_TIMEOUT,
        max_output_bytes: MAX_HELPER_STDOUT_BYTES,
        invocations: AtomicUsize::new(0),
    };

    match signer.run_helper(
        &[
            secret_key.as_os_str().to_os_string(),
            public_key.as_os_str().to_os_string(),
        ],
        b"",
    ) {
        Ok(_) => Ok(GeneratedKeyPair {
            secret_key: secret_key.to_path_buf(),
            public_key,
        }),
        Err(source) => {
            // A half-written pair is worse than none: it looks like a key.
            let _ = std::fs::remove_file(secret_key);
            let _ = std::fs::remove_file(&public_key);
            Err(GuixKeyError::Helper { source })
        }
    }
}

/// The public key exactly as stored — what `guix archive --authorize` reads.
pub fn export_public_key(secret_key: &Path) -> Result<String, GuixKeyError> {
    let path = public_key_path(secret_key);
    std::fs::read_to_string(&path).map_err(|source| GuixKeyError::Io { path, source })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_public_half_is_the_secret_halfs_sibling() {
        assert_eq!(
            public_key_path(Path::new("/etc/gips/signing-key.sec")),
            PathBuf::from("/etc/gips/signing-key.pub")
        );
        assert_eq!(
            public_key_path(Path::new("/etc/gips/signing-key")),
            PathBuf::from("/etc/gips/signing-key.pub")
        );
    }

    #[test]
    fn a_host_may_not_smuggle_a_field_separator() {
        assert!(usable_host("berlin.guix.gnu.org"));
        assert!(!usable_host("berlin;evil"));
        assert!(!usable_host("has space"));
        assert!(!usable_host(""));
    }

    #[test]
    fn bounded_reads_report_truncation() {
        let (bytes, truncated) = read_bounded(&b"hello"[..], 16).unwrap();
        assert_eq!(bytes, b"hello");
        assert!(!truncated);

        let (bytes, truncated) = read_bounded(&b"hello world"[..], 5).unwrap();
        assert_eq!(bytes, b"hello");
        assert!(
            truncated,
            "surplus bytes must be reported, not silently cut"
        );
    }
}
