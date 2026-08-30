//! The GIPS **feed** key: RFC 8032 Ed25519 in PKCS#8 / SPKI PEM.
//!
//! # Which key is this?
//!
//! A GIPS node has room for two entirely different signing keys, and mixing
//! them up is the single most common way to end up with a laptop that silently
//! builds from source:
//!
//! - the **feed key** — this module. Ed25519 (`ed25519_dalek`), configured
//!   under `[trust]`, used by [`crate::sign_narinfo`] and checked by
//!   [`crate::verify_narinfo`]. It is how one `gipsd` decides whether to
//!   believe another `gipsd`'s feed. `guix` never sees it.
//! - the **Guix narinfo key** — [`crate::guix`]. libgcrypt RFC 6979 ECDSA in an
//!   advanced-rendered s-expression, configured under `[guix_signing]`,
//!   authorized into `/etc/guix/acl` with `guix archive --authorize`. It is how
//!   the local `guix-daemon` decides whether to accept a substitute.
//!
//! The two formats are not interconvertible (see the [`crate::guix`] module
//! docs), so this module exists to *produce* keys in exactly the formats the
//! verifier on the other side already reads — nothing here changes how
//! anything is signed or verified.
//!
//! # What is written
//!
//! [`generate_key_pair`] writes the private half as a PKCS#8 PEM
//! (`-----BEGIN PRIVATE KEY-----`), which is what
//! `SigningKey::from_pkcs8_pem` in [`crate::sign_narinfo`] parses, and the
//! public half as an SPKI PEM (`-----BEGIN PUBLIC KEY-----`), which is what
//! `VerifyingKey::from_public_key_pem` in [`crate::verify_narinfo`] parses.
//! The round-trip test in this module is the guarantee: it signs and verifies
//! with a freshly generated pair rather than string-matching PEM headers,
//! because a file with the right header and the wrong DER inside is precisely
//! the failure this is meant to rule out.

use crate::fsintegrity;
use ed25519_dalek::pkcs8::spki::der::pem::LineEnding;
use ed25519_dalek::pkcs8::{EncodePrivateKey, EncodePublicKey};
use ed25519_dalek::{SigningKey, SECRET_KEY_LENGTH};
use rand::rngs::OsRng;
use rand::RngCore;
use std::fmt;
use std::io;
use std::path::{Path, PathBuf};

/// The default file name of the private half, relative to the config home.
///
/// Deliberately unlike the Guix pair's `signing-key.sec` / `signing-key.pub`:
/// the `feed-` prefix names the role and the `.pem` suffix names the format,
/// so neither half of either pair can be pasted into the other's config slot
/// without the mistake being visible in the path itself.
pub const DEFAULT_SECRET_KEY_FILE_NAME: &str = "feed-signing-key.pem";

/// The default file name of the public half.
pub const DEFAULT_PUBLIC_KEY_FILE_NAME: &str = "feed-signing-key.pub.pem";

/// The public half's path for a given secret key path.
///
/// `feed-signing-key.pem` → `feed-signing-key.pub.pem`. A trailing `.pem` is
/// consumed rather than kept, so the public half never ends up named
/// `…pem.pub.pem`; any other name simply gains the suffix. As with the Guix
/// pair, deriving the sibling means there is no way to configure a private and
/// a public key that do not belong together.
pub fn public_key_path(secret_key: &Path) -> PathBuf {
    let name = secret_key
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let stem = name.strip_suffix(".pem").unwrap_or(&name);
    secret_key.with_file_name(format!("{}.pub.pem", stem))
}

/// Where a freshly generated pair landed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GeneratedKeyPair {
    pub secret_key: PathBuf,
    pub public_key: PathBuf,
}

/// Why a feed key pair could not be created or read. No variant carries key
/// material.
#[derive(Debug)]
pub enum FeedKeyError {
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
    /// The key could not be rendered as PEM. `what` names the half; the reason
    /// comes from the encoder and describes DER structure, never key bytes.
    Encode {
        what: &'static str,
        reason: String,
    },
    /// This platform cannot create owner-only files, so it cannot hold a key.
    UnsupportedPlatform,
}

impl fmt::Display for FeedKeyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::AlreadyExists { path } => write!(
                f,
                "{} already exists; refusing to overwrite a feed key. Move it aside first if you \
                 really mean to rotate — feeds already signed can only be verified by the key \
                 that made them",
                path.display()
            ),
            Self::Io { path, source } => write!(f, "{}: {}", path.display(), source),
            Self::Integrity { source } => write!(f, "{}", source),
            Self::Encode { what, reason } => {
                write!(f, "the {} half could not be PEM-encoded: {}", what, reason)
            }
            Self::UnsupportedPlatform => f.write_str(
                "this platform cannot store a secret key owner-only; refusing to write one",
            ),
        }
    }
}

impl std::error::Error for FeedKeyError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            Self::Integrity { source } => Some(source),
            _ => None,
        }
    }
}

impl From<fsintegrity::IntegrityError> for FeedKeyError {
    fn from(source: fsintegrity::IntegrityError) -> Self {
        Self::Integrity { source }
    }
}

/// Creates `path` with mode 0600, failing if it is already there.
///
/// `create_new` is `O_EXCL`, so "refuse to overwrite" is a race-free claim
/// rather than a check followed by a hope. Deliberately a twin of the Guix
/// module's private helper: the two key ceremonies must not be able to drift
/// apart in their permission handling by one of them being "fixed" alone.
#[cfg(unix)]
fn create_new_private_file(path: &Path) -> Result<(), FeedKeyError> {
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
            Err(FeedKeyError::AlreadyExists {
                path: path.to_path_buf(),
            })
        }
        Err(source) => Err(FeedKeyError::Io {
            path: path.to_path_buf(),
            source,
        }),
    }
}

#[cfg(not(unix))]
fn create_new_private_file(_path: &Path) -> Result<(), FeedKeyError> {
    Err(FeedKeyError::UnsupportedPlatform)
}

/// Generates the Ed25519 feed key pair at `secret_key` and its sibling public
/// PEM.
///
/// This is a ceremony, not a fallback: it refuses to overwrite either file,
/// because the only thing that can verify a signature already on the wire is
/// the key that made it. Both files are staked out 0600 inside a 0700
/// directory *before* any key bytes are written, so the private half is never
/// briefly world-readable.
pub fn generate_key_pair(secret_key: &Path) -> Result<GeneratedKeyPair, FeedKeyError> {
    let public_key = public_key_path(secret_key);
    if let Some(parent) = secret_key.parent() {
        fsintegrity::ensure_private_dir(parent)?;
    }

    create_new_private_file(secret_key)?;
    if let Err(error) = create_new_private_file(&public_key) {
        // We created the secret half a moment ago and it is still empty, so
        // removing it leaves the directory exactly as we found it.
        let _ = std::fs::remove_file(secret_key);
        return Err(error);
    }

    match write_pair(secret_key, &public_key) {
        Ok(()) => Ok(GeneratedKeyPair {
            secret_key: secret_key.to_path_buf(),
            public_key,
        }),
        Err(error) => {
            // A half-written pair is worse than none: it looks like a key.
            let _ = std::fs::remove_file(secret_key);
            let _ = std::fs::remove_file(&public_key);
            Err(error)
        }
    }
}

/// Fills the two already-staked-out files. Split out so that every failure
/// path after the files exist unwinds through one place.
fn write_pair(secret_key: &Path, public_key: &Path) -> Result<(), FeedKeyError> {
    // `SigningKey::generate` is behind dalek's optional `rand_core` feature,
    // which this workspace does not enable; seeding `from_bytes` out of the
    // operating system's CSPRNG is the same thing without a feature flag. The
    // seed lives only until the key is built.
    let mut seed = [0u8; SECRET_KEY_LENGTH];
    OsRng.fill_bytes(&mut seed);
    let signing_key = SigningKey::from_bytes(&seed);
    seed.fill(0);

    // Both encoders return owned buffers; the private one is `Zeroizing`, so
    // the PEM text is wiped when it drops rather than lingering in the heap.
    let private_pem =
        signing_key
            .to_pkcs8_pem(LineEnding::LF)
            .map_err(|error| FeedKeyError::Encode {
                what: "private",
                reason: error.to_string(),
            })?;
    let public_pem = signing_key
        .verifying_key()
        .to_public_key_pem(LineEnding::LF)
        .map_err(|error| FeedKeyError::Encode {
            what: "public",
            reason: error.to_string(),
        })?;

    write_staked_file(secret_key, private_pem.as_bytes())?;
    write_staked_file(public_key, public_pem.as_bytes())
}

/// Writes into a file this process just created 0600. `File::create` would
/// truncate and keep the existing mode, which is what we want, but it would
/// also happily create the file — so it is only ever called on a path
/// [`create_new_private_file`] has already claimed.
fn write_staked_file(path: &Path, bytes: &[u8]) -> Result<(), FeedKeyError> {
    std::fs::write(path, bytes).map_err(|source| FeedKeyError::Io {
        path: path.to_path_buf(),
        source,
    })
}

/// The public key exactly as stored — the bytes a consumer machine points
/// `[[trust.trusted_publishers]].public_key` at.
///
/// The error names the path it looked at, because "nothing happened" with no
/// path in it is the least useful thing this command could say.
pub fn export_public_key(secret_key: &Path) -> Result<String, FeedKeyError> {
    let path = public_key_path(secret_key);
    std::fs::read_to_string(&path).map_err(|source| FeedKeyError::Io { path, source })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{sign_narinfo, verify_narinfo, KeyCache, SigningConfig, TrustConfig};

    const BODY: &str = "StorePath: /gnu/store/foo\nNarHash: sha256:abc\nReferences: \n";

    #[test]
    fn the_public_half_is_the_secret_halfs_pem_sibling() {
        assert_eq!(
            public_key_path(Path::new("/etc/gips/feed-signing-key.pem")),
            PathBuf::from("/etc/gips/feed-signing-key.pub.pem")
        );
        // A name without the conventional suffix still gets one sibling, not
        // `key.pem.pub.pem`.
        assert_eq!(
            public_key_path(Path::new("/etc/gips/key")),
            PathBuf::from("/etc/gips/key.pub.pem")
        );
        // And the defaults agree with the derivation.
        assert_eq!(
            public_key_path(Path::new(DEFAULT_SECRET_KEY_FILE_NAME)),
            PathBuf::from(DEFAULT_PUBLIC_KEY_FILE_NAME)
        );
        // Nothing here can collide with the Guix pair's names.
        assert_ne!(DEFAULT_SECRET_KEY_FILE_NAME, "signing-key.sec");
        assert_ne!(DEFAULT_PUBLIC_KEY_FILE_NAME, "signing-key.pub");
    }

    /// Enumerated test 1: the ceremony's permission and no-overwrite rules.
    #[cfg(unix)]
    #[test]
    fn generate_feed_writes_an_owner_only_pair_and_never_overwrites() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("gips");
        let secret = home.join(DEFAULT_SECRET_KEY_FILE_NAME);

        let pair = generate_key_pair(&secret).unwrap();
        assert_eq!(pair.secret_key, secret);
        assert_eq!(pair.public_key, home.join(DEFAULT_PUBLIC_KEY_FILE_NAME));

        let mode = |path: &Path| std::fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&home), 0o700, "the parent directory is 0700");
        assert_eq!(mode(&pair.secret_key), 0o600);
        assert_eq!(mode(&pair.public_key), 0o600);

        let secret_bytes = std::fs::read(&pair.secret_key).unwrap();
        let public_bytes = std::fs::read(&pair.public_key).unwrap();
        assert!(!secret_bytes.is_empty() && !public_bytes.is_empty());

        // A second call refuses and changes nothing.
        match generate_key_pair(&secret) {
            Err(FeedKeyError::AlreadyExists { path }) => assert_eq!(path, secret),
            other => panic!("expected a refusal, got {:?}", other),
        }
        assert_eq!(std::fs::read(&pair.secret_key).unwrap(), secret_bytes);
        assert_eq!(std::fs::read(&pair.public_key).unwrap(), public_bytes);

        // The *public* half alone is enough to refuse, and the refusal must
        // not leave a freshly created empty secret behind.
        let orphan_secret = home.join("other-feed-key.pem");
        let orphan_public = public_key_path(&orphan_secret);
        std::fs::write(&orphan_public, b"someone else's key\n").unwrap();
        match generate_key_pair(&orphan_secret) {
            Err(FeedKeyError::AlreadyExists { path }) => assert_eq!(path, orphan_public),
            other => panic!("expected a refusal, got {:?}", other),
        }
        assert!(
            !orphan_secret.exists(),
            "the refused run must not leave a secret half behind"
        );
        assert_eq!(
            std::fs::read(&orphan_public).unwrap(),
            b"someone else's key\n"
        );
    }

    /// Enumerated test 2: the emitted PEMs are the ones the verifier reads.
    ///
    /// Signing and verifying is the assertion; matching `-----BEGIN` headers
    /// would pass just as happily on a file with the wrong DER inside.
    #[test]
    fn a_generated_pair_signs_and_verifies_a_real_narinfo() {
        let dir = tempfile::tempdir().unwrap();
        let secret = dir.path().join(DEFAULT_SECRET_KEY_FILE_NAME);
        let pair = generate_key_pair(&secret).unwrap();

        let private_pem = std::fs::read_to_string(&pair.secret_key).unwrap();
        let public_pem = std::fs::read_to_string(&pair.public_key).unwrap();

        let signature = sign_narinfo(BODY, &private_pem, "desktop.gnu").unwrap();
        verify_narinfo(BODY, &signature, &public_pem)
            .expect("a freshly generated pair must verify its own signature");

        // A tampered body does not.
        let tampered = BODY.replace("/gnu/store/foo", "/gnu/store/bar");
        assert!(verify_narinfo(&tampered, &signature, &public_pem).is_err());

        // Nor does a different pair's public half.
        let other = generate_key_pair(&dir.path().join("other.pem")).unwrap();
        let other_public = std::fs::read_to_string(&other.public_key).unwrap();
        assert!(verify_narinfo(BODY, &signature, &other_public).is_err());
    }

    /// Enumerated test 3: a `TrustConfig` pointed at the generated secret half
    /// signs through the cache the daemon actually uses.
    #[test]
    fn the_key_cache_loads_what_the_generator_wrote() {
        let dir = tempfile::tempdir().unwrap();
        let secret = dir.path().join(DEFAULT_SECRET_KEY_FILE_NAME);
        let pair = generate_key_pair(&secret).unwrap();

        let trust = TrustConfig {
            signing: Some(SigningConfig {
                narinfo_private_key: pair.secret_key.clone(),
                narinfo_public_key: pair.public_key.clone(),
                publisher_gns_name: Some("desktop.gnu".to_string()),
            }),
            ..TrustConfig::default()
        };
        let signing = trust.signing.as_ref().unwrap();

        let cache = KeyCache::new();
        let private = cache.private_key(&signing.narinfo_private_key).unwrap();
        let public = cache.public_key(&signing.narinfo_public_key).unwrap();

        let name = signing.publisher_gns_name.as_deref().unwrap();
        let signature = sign_narinfo(BODY, private.as_str(), name).unwrap();
        verify_narinfo(BODY, &signature, &public).unwrap();
        assert!(signature.starts_with("1;desktop.gnu;"));
    }

    /// Enumerated test 4 (library half): export prints the exact stored bytes,
    /// and names the path it looked at when there is nothing there.
    #[test]
    fn export_returns_the_stored_public_pem_or_names_the_missing_path() {
        let dir = tempfile::tempdir().unwrap();
        let secret = dir.path().join(DEFAULT_SECRET_KEY_FILE_NAME);
        let pair = generate_key_pair(&secret).unwrap();

        assert_eq!(
            export_public_key(&secret).unwrap(),
            std::fs::read_to_string(&pair.public_key).unwrap()
        );

        let missing = dir.path().join("nowhere").join("feed-signing-key.pem");
        let error = export_public_key(&missing).unwrap_err();
        assert!(
            error
                .to_string()
                .contains(&public_key_path(&missing).display().to_string()),
            "{}",
            error
        );
    }
}
