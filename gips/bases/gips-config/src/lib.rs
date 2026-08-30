use anyhow::Result;
use dirs::{config_dir, home_dir};
use serde::{Deserialize, Serialize};
use std::fmt;
use std::fs;
use std::net::{AddrParseError, SocketAddr};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct GipsdConfig {
    pub listen: String,
    pub db_path: PathBuf,
    pub ipfs_api: String,
    pub gns_command: String,
    /// Optional path to a Guile Scheme configuration file that can override
    /// or extend this configuration, inspired by Guix.
    pub guile_config: Option<PathBuf>,
    /// Trust config for verifying narinfo signatures.
    #[serde(default)]
    pub trust: gips_trust::TrustConfig,
    /// CID of a snapshot manifest to serve. If present, the daemon runs in offline snapshot mode.
    pub snapshot_cid: Option<String>,
    /// Opt-in to binding a non-loopback address.
    ///
    /// `gipsd` only ever needs to talk to the local `guix-daemon`; IPFS carries
    /// all cross-machine transport. Exposing the socket publicly therefore buys
    /// nothing and hands every mutating endpoint to the network, so it must be
    /// asked for by name.
    #[serde(default)]
    pub insecure_bind: bool,
    /// Override for where the local auth token is stored. `None` means
    /// [`default_auth_token_path`].
    #[serde(default)]
    pub auth_token_path: Option<PathBuf>,
    /// The Guix-format key this node signs served narinfos with.
    ///
    /// Absent means the feature is off: narinfos are served byte-for-byte as
    /// they were before signing existed. It is a separate key from
    /// `trust.signing` — that one signs the GIPS feed with Ed25519, this one
    /// signs narinfos the way `guix publish` does, and the two formats are not
    /// interconvertible. See [`gips_trust::guix`].
    #[serde(default)]
    pub guix_signing: Option<gips_trust::guix::GuixSigningConfig>,
    /// Gossip transport mode: "ipfs" (default), "cadet", "mesh", "memory", or "composite"
    #[serde(default = "default_gossip_transport")]
    pub gossip_transport: String,
    /// CADET port name or hash string
    #[serde(default = "default_cadet_port")]
    pub cadet_port: String,
    /// Command to invoke for CADET CLI operations
    #[serde(default = "default_cadet_command")]
    pub cadet_command: String,
}

fn default_gossip_transport() -> String {
    "ipfs".to_string()
}

fn default_cadet_port() -> String {
    "gips-gossip".to_string()
}

fn default_cadet_command() -> String {
    "gnunet-cadet".to_string()
}

/// Expands a leading `~` in a path string to the user's home directory.
/// Supports Unix `~/` and Windows `~\`; leaves other paths (e.g. `~user`) unchanged.
pub fn expand_path(s: &str) -> PathBuf {
    let s = s.trim();
    let Some(home) = home_dir() else {
        return PathBuf::from(s);
    };
    if s == "~" {
        return home;
    }
    let sep = std::path::MAIN_SEPARATOR;
    // "~/" (Unix) or "~\" (Windows)
    let rest = if s.starts_with("~/") {
        s.strip_prefix("~/").unwrap_or(s).trim_start_matches('/')
    } else if sep == '\\' && s.starts_with("~\\") {
        s.strip_prefix("~\\").unwrap_or(s).trim_start_matches(sep)
    } else if s.starts_with('~') {
        let after = s.strip_prefix('~').unwrap_or(s);
        if after.is_empty() {
            return home;
        }
        if after.starts_with('/') || (sep == '\\' && after.starts_with('\\')) {
            return home.join(after.trim_start_matches(sep).trim_start_matches('/'));
        }
        return PathBuf::from(s);
    } else {
        return PathBuf::from(s);
    };
    home.join(rest)
}

// ---------------------------------------------------------------------------
// Where the daemon's state lives
// ---------------------------------------------------------------------------

/// The name of the environment variable that names a config directory
/// explicitly. This is the escape hatch for systemd units, containers and
/// `su`, where `HOME`/`XDG_CONFIG_HOME` may be unset — the answer to "no
/// config directory" is to *say* where it is, never to guess.
pub const CONFIG_DIR_ENV: &str = "GIPS_CONFIG_DIR";

/// Why gipsd cannot decide where its configuration, database and token live.
///
/// This is deliberately fatal. The old behaviour was to fall back to the
/// current working directory, which meant a daemon started from an
/// attacker-writable directory would read `./gips/gipsd.toml` — a file that
/// names `gns_command` and `guile_config`, both of which are executed as
/// subprocesses. Guessing here is remote code execution as the daemon user.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigLocationError {
    /// Neither `GIPS_CONFIG_DIR` nor the platform config directory resolved.
    Unresolvable,
    /// `GIPS_CONFIG_DIR` was set to something that is not an absolute path.
    NotAbsolute { given: PathBuf },
}

impl fmt::Display for ConfigLocationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ConfigLocationError::Unresolvable => write!(
                f,
                "cannot determine a configuration directory: neither {} nor XDG_CONFIG_HOME/HOME \
                 is usable. gipsd refuses to fall back to the current working directory, because \
                 a config file there could name any gns_command or guile_config and have it run \
                 as this user. Set {} to an absolute path.",
                CONFIG_DIR_ENV, CONFIG_DIR_ENV
            ),
            ConfigLocationError::NotAbsolute { given } => write!(
                f,
                "{} must be an absolute path, got {:?}: a relative config directory is resolved \
                 against the current working directory, which is exactly the fallback gipsd \
                 refuses to have",
                CONFIG_DIR_ENV,
                given.display()
            ),
        }
    }
}

impl std::error::Error for ConfigLocationError {}

/// Decides the GIPS config home from an explicit override and the platform's
/// config directory, with no reference to the process's working directory.
///
/// Pure so the policy is testable without touching the environment: `gipsd`'s
/// "no config dir means no daemon" behaviour is asserted by calling this with
/// `(None, None)`.
pub fn resolve_config_home(
    explicit: Option<PathBuf>,
    platform: Option<PathBuf>,
) -> Result<PathBuf, ConfigLocationError> {
    if let Some(given) = explicit {
        if !given.is_absolute() {
            return Err(ConfigLocationError::NotAbsolute { given });
        }
        return Ok(given);
    }
    match platform {
        Some(dir) => Ok(dir.join("gips")),
        None => Err(ConfigLocationError::Unresolvable),
    }
}

/// The directory holding `gipsd.toml`, `gipsd.sqlite` and `auth-token`.
pub fn config_home() -> Result<PathBuf, ConfigLocationError> {
    let explicit = std::env::var_os(CONFIG_DIR_ENV)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from);
    resolve_config_home(explicit, config_dir())
}

/// The path `load_default` reads.
pub fn default_config_path() -> Result<PathBuf, ConfigLocationError> {
    Ok(config_home()?.join("gipsd.toml"))
}

/// The path reported when there is no config home at all.
///
/// Absolute and under a directory only root can create, so — unlike the `.`
/// this replaces — it can never name an attacker-writable file. Reaching it is
/// always an error the caller surfaces; nothing is ever silently read from or
/// written to it.
const UNRESOLVED_CONFIG_HOME: &str = "/nonexistent/gips";

impl Default for GipsdConfig {
    /// Field defaults for a daemon whose config home is known. When it is
    /// *not* known the paths point at [`UNRESOLVED_CONFIG_HOME`], which cannot
    /// be created: startup fails loudly instead of opening a database next to
    /// whatever directory the daemon happened to be launched from.
    fn default() -> Self {
        Self::rooted_at(&config_home().unwrap_or_else(|_| PathBuf::from(UNRESOLVED_CONFIG_HOME)))
    }
}

impl GipsdConfig {
    /// Defaults with every path anchored at `home`.
    pub fn rooted_at(home: &Path) -> Self {
        Self {
            listen: "127.0.0.1:8080".to_string(),
            db_path: home.join("gipsd.sqlite"),
            ipfs_api: "http://127.0.0.1:5001".to_string(),
            gns_command: "gnunet-gns".to_string(),
            guile_config: None,
            trust: gips_trust::TrustConfig::default(),
            snapshot_cid: None,
            insecure_bind: false,
            auth_token_path: None,
            guix_signing: None,
            gossip_transport: default_gossip_transport(),
            cadet_port: default_cadet_port(),
            cadet_command: default_cadet_command(),
        }
    }

    /// Loads `<config home>/gipsd.toml`, or the defaults rooted there if the
    /// file does not exist.
    ///
    /// Fails rather than guessing when there is no config home; see
    /// [`ConfigLocationError`].
    pub fn load_default() -> Result<Self> {
        let home = config_home()?;
        Self::load_from_home(&home)
    }

    /// The half of [`Self::load_default`] that has already decided where to
    /// look. Split out so tests can point it at a scratch directory without
    /// mutating process-wide environment variables.
    pub fn load_from_home(home: &Path) -> Result<Self> {
        let path = home.join("gipsd.toml");

        if !path.exists() {
            return Ok(Self::rooted_at(home));
        }

        // The config file names programs that will be executed. Anyone who can
        // write it, or the directory holding it, chooses what runs as this
        // user, so say so before acting on its contents.
        for warning in audit_warnings(&path, gips_trust::fsintegrity::Expectation::OwnerOnly) {
            eprintln!("gipsd: WARNING: config file {}", warning);
        }

        let contents = fs::read_to_string(&path)?;
        let mut config: Self = toml::from_str(&contents)?;
        config.db_path = expand_path(&config.db_path.to_string_lossy());
        if let Some(ref p) = config.guile_config {
            config.guile_config = Some(expand_path(&p.to_string_lossy()));
        }
        if let Some(ref p) = config.auth_token_path {
            config.auth_token_path = Some(expand_path(&p.to_string_lossy()));
        }
        Ok(config)
    }

    /// The auth token file this daemon uses: the configured override, or the
    /// platform default.
    ///
    /// Fallible because the daemon *creates* this file: minting a token into a
    /// guessed directory would hand the daemon's authority to whoever can
    /// write there.
    pub fn resolved_auth_token_path(&self) -> Result<PathBuf, ConfigLocationError> {
        match &self.auth_token_path {
            Some(path) => Ok(path.clone()),
            None => Ok(config_home()?.join("auth-token")),
        }
    }
}

/// Where the local auth token lives by default: alongside `gipsd.toml` in the
/// user's config directory.
///
/// Infallible for the `gips` CLI, which only ever *reads* the token and
/// reports the path it tried. With no config home this names
/// [`UNRESOLVED_CONFIG_HOME`], so the CLI fails with a path that cannot exist
/// instead of reading a token out of the working directory. The daemon uses
/// the fallible [`GipsdConfig::resolved_auth_token_path`] instead.
pub fn default_auth_token_path() -> PathBuf {
    config_home()
        .unwrap_or_else(|_| PathBuf::from(UNRESOLVED_CONFIG_HOME))
        .join("auth-token")
}

/// Audits a path that already exists, returning human-readable warnings.
///
/// A path that does not exist, or that cannot be measured, yields no
/// warnings — this reports what is known, and callers never treat silence as
/// proof of safety.
pub fn audit_warnings(
    path: &Path,
    expectation: gips_trust::fsintegrity::Expectation,
) -> Vec<String> {
    match gips_trust::fsintegrity::audit(path) {
        Ok(Some(found)) => found.warnings(expectation),
        Ok(None) => Vec::new(),
        Err(e) => vec![format!("{} could not be checked: {}", path.display(), e)],
    }
}

// ---------------------------------------------------------------------------
// Network exposure
// ---------------------------------------------------------------------------

/// How much of the network a validated bind address is reachable from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Exposure {
    /// Only this machine can reach the socket.
    Loopback,
    /// Reachable beyond this machine, and explicitly asked for.
    PublicOptedIn,
}

/// A bind address that has already been checked against the exposure policy.
///
/// Parse-don't-validate: `gipsd` binds a `BindPlan`, never a raw string, so
/// there is no path from a config file to a listening socket that skips the
/// check.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BindPlan {
    pub addr: SocketAddr,
    pub exposure: Exposure,
}

/// Why a `listen` value must not be bound.
#[derive(Debug)]
pub enum BindError {
    /// `listen` is not a `host:port` socket address at all.
    Malformed {
        listen: String,
        source: AddrParseError,
    },
    /// `listen` is reachable off-machine and `insecure_bind` was not set.
    PublicWithoutOptIn { addr: SocketAddr },
}

impl fmt::Display for BindError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BindError::Malformed { listen, source } => {
                write!(
                    f,
                    "listen address {:?} is not a socket address: {}",
                    listen, source
                )
            }
            BindError::PublicWithoutOptIn { addr } => write!(
                f,
                "refusing to listen on {}: it is reachable from outside this machine and every \
                 mutating endpoint would be exposed. gipsd only needs to talk to the local \
                 guix-daemon (IPFS carries all cross-machine transport), so prefer \
                 listen = \"127.0.0.1:8080\". If you really mean it, set insecure_bind = true \
                 in gipsd.toml",
                addr
            ),
        }
    }
}

impl std::error::Error for BindError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            BindError::Malformed { source, .. } => Some(source),
            BindError::PublicWithoutOptIn { .. } => None,
        }
    }
}

/// Parses `listen` and decides whether it may be bound.
///
/// Anything that is not a loopback address — including the unspecified
/// addresses `0.0.0.0` and `[::]` — counts as public and requires
/// `insecure_bind`.
pub fn plan_bind(listen: &str, insecure_bind: bool) -> Result<BindPlan, BindError> {
    let addr: SocketAddr = listen
        .trim()
        .parse()
        .map_err(|source| BindError::Malformed {
            listen: listen.to_string(),
            source,
        })?;

    if addr.ip().is_loopback() {
        return Ok(BindPlan {
            addr,
            exposure: Exposure::Loopback,
        });
    }

    if insecure_bind {
        Ok(BindPlan {
            addr,
            exposure: Exposure::PublicOptedIn,
        })
    } else {
        Err(BindError::PublicWithoutOptIn { addr })
    }
}

// ---------------------------------------------------------------------------
// Local auth token
// ---------------------------------------------------------------------------

/// Number of CSPRNG bytes behind a token.
const AUTH_TOKEN_BYTES: usize = 32;
/// Length of the hex rendering of a token.
const AUTH_TOKEN_HEX_LEN: usize = AUTH_TOKEN_BYTES * 2;

/// The local authentication token: 32 bytes from the OS CSPRNG, rendered as 64
/// lowercase hex characters.
///
/// Parse-don't-validate: constructing one requires a well-formed token, so the
/// HTTP layer never has to decide whether a string "looks token-shaped".
#[derive(Clone, PartialEq, Eq)]
pub struct AuthToken(String);

impl fmt::Debug for AuthToken {
    /// Deliberately does not render the secret: a token in a log line is a
    /// leaked token.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AuthToken(<redacted>)")
    }
}

/// Every way loading or minting a token can fail. No variant carries the token
/// itself.
#[derive(Debug)]
pub enum AuthTokenError {
    /// The bytes are not 64 lowercase hex characters.
    Malformed { reason: &'static str },
    /// No token file exists yet.
    Missing { path: PathBuf },
    /// The token file is readable by someone other than its owner.
    InsecurePermissions { path: PathBuf, mode: u32 },
    Io {
        path: PathBuf,
        source: std::io::Error,
    },
    /// This platform has no way to store the token owner-only.
    UnsupportedPlatform,
}

impl fmt::Display for AuthTokenError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AuthTokenError::Malformed { reason } => {
                write!(f, "malformed auth token: {}", reason)
            }
            AuthTokenError::Missing { path } => write!(
                f,
                "no auth token at {}: start gipsd once to create it",
                path.display()
            ),
            AuthTokenError::InsecurePermissions { path, mode } => write!(
                f,
                "auth token {} has mode {:04o}; it must be readable only by its owner (0600)",
                path.display(),
                mode
            ),
            AuthTokenError::Io { path, source } => {
                write!(f, "auth token {}: {}", path.display(), source)
            }
            AuthTokenError::UnsupportedPlatform => write!(
                f,
                "this platform cannot store the auth token owner-only; gipsd refuses to start"
            ),
        }
    }
}

impl std::error::Error for AuthTokenError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            AuthTokenError::Io { source, .. } => Some(source),
            _ => None,
        }
    }
}

impl AuthToken {
    /// Accepts exactly 64 lowercase hex characters and nothing else.
    pub fn parse(s: &str) -> Result<Self, AuthTokenError> {
        if s.len() != AUTH_TOKEN_HEX_LEN {
            return Err(AuthTokenError::Malformed {
                reason: "expected 64 hex characters",
            });
        }
        if !s
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(AuthTokenError::Malformed {
                reason: "expected lowercase hex characters only",
            });
        }
        Ok(Self(s.to_string()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Mints a token from the OS CSPRNG.
    #[cfg(unix)]
    pub fn generate() -> Result<Self, AuthTokenError> {
        use std::io::Read;

        let path = PathBuf::from("/dev/urandom");
        let mut file = fs::File::open(&path).map_err(|source| AuthTokenError::Io {
            path: path.clone(),
            source,
        })?;
        let mut bytes = [0u8; AUTH_TOKEN_BYTES];
        file.read_exact(&mut bytes)
            .map_err(|source| AuthTokenError::Io { path, source })?;

        let mut hex = String::with_capacity(AUTH_TOKEN_HEX_LEN);
        for byte in bytes {
            fmt::Write::write_fmt(&mut hex, format_args!("{:02x}", byte)).expect("String write");
        }
        Self::parse(&hex)
    }

    #[cfg(not(unix))]
    pub fn generate() -> Result<Self, AuthTokenError> {
        Err(AuthTokenError::UnsupportedPlatform)
    }

    /// Reads an existing token, refusing one that other users can read.
    pub fn load(path: &Path) -> Result<Self, AuthTokenError> {
        let contents = match fs::read_to_string(path) {
            Ok(contents) => contents,
            Err(source) if source.kind() == std::io::ErrorKind::NotFound => {
                return Err(AuthTokenError::Missing {
                    path: path.to_path_buf(),
                })
            }
            Err(source) => {
                return Err(AuthTokenError::Io {
                    path: path.to_path_buf(),
                    source,
                })
            }
        };

        check_owner_only(path)?;
        Self::parse(contents.trim())
    }

    /// Writes the token to `path` with mode 0600, creating the parent directory
    /// with mode 0700. Refuses to overwrite an existing file.
    pub fn store(&self, path: &Path) -> Result<(), AuthTokenError> {
        #[cfg(unix)]
        {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;

            if let Some(parent) = path.parent() {
                gips_trust::fsintegrity::ensure_private_dir(parent).map_err(|e| match e {
                    gips_trust::fsintegrity::IntegrityError::Io { path, source } => {
                        AuthTokenError::Io { path, source }
                    }
                    _ => AuthTokenError::UnsupportedPlatform,
                })?;
            }

            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(path)
                .map_err(|source| AuthTokenError::Io {
                    path: path.to_path_buf(),
                    source,
                })?;
            file.write_all(self.0.as_bytes())
                .and_then(|()| file.write_all(b"\n"))
                .map_err(|source| AuthTokenError::Io {
                    path: path.to_path_buf(),
                    source,
                })
        }
        #[cfg(not(unix))]
        {
            let _ = path;
            Err(AuthTokenError::UnsupportedPlatform)
        }
    }

    /// Loads the token, minting and storing one the first time.
    pub fn load_or_create(path: &Path) -> Result<Self, AuthTokenError> {
        match Self::load(path) {
            Ok(token) => Ok(token),
            Err(AuthTokenError::Missing { .. }) => {
                let token = Self::generate()?;
                token.store(path)?;
                Ok(token)
            }
            Err(other) => Err(other),
        }
    }

    /// Rotates the token at `path` by generating a fresh CSPRNG token, writing
    /// it to a temporary file with mode 0600 in the same directory, and atomically
    /// replacing `path`.
    pub fn rotate(path: &Path) -> Result<Self, AuthTokenError> {
        #[cfg(unix)]
        {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;

            if let Some(parent) = path.parent() {
                gips_trust::fsintegrity::ensure_private_dir(parent).map_err(|e| match e {
                    gips_trust::fsintegrity::IntegrityError::Io { path, source } => {
                        AuthTokenError::Io { path, source }
                    }
                    _ => AuthTokenError::UnsupportedPlatform,
                })?;
            }

            let token = Self::generate()?;
            let temp_name = format!(
                ".token.tmp.{}.{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos()
            );
            let temp_path = path
                .parent()
                .unwrap_or_else(|| Path::new("."))
                .join(temp_name);

            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temp_path)
                .map_err(|source| AuthTokenError::Io {
                    path: temp_path.clone(),
                    source,
                })?;

            if let Err(source) = file
                .write_all(token.0.as_bytes())
                .and_then(|()| file.write_all(b"\n"))
                .and_then(|()| file.sync_all())
            {
                let _ = fs::remove_file(&temp_path);
                return Err(AuthTokenError::Io {
                    path: temp_path,
                    source,
                });
            }
            drop(file);

            if let Err(source) = fs::rename(&temp_path, path) {
                let _ = fs::remove_file(&temp_path);
                return Err(AuthTokenError::Io {
                    path: path.to_path_buf(),
                    source,
                });
            }

            Ok(token)
        }
        #[cfg(not(unix))]
        {
            let _ = path;
            Err(AuthTokenError::UnsupportedPlatform)
        }
    }
}

/// Fails if anyone but the owner can read the token file.
///
/// Delegates to the shared check in `gips-trust` so the token, the database
/// and the signing key are all judged by one rule.
fn check_owner_only(path: &Path) -> Result<(), AuthTokenError> {
    use gips_trust::fsintegrity::IntegrityError;

    match gips_trust::fsintegrity::require_owner_only(path) {
        Ok(()) => Ok(()),
        Err(IntegrityError::InsecurePermissions { path, mode }) => {
            Err(AuthTokenError::InsecurePermissions { path, mode })
        }
        Err(IntegrityError::Io { path, source }) => Err(AuthTokenError::Io { path, source }),
        Err(IntegrityError::UnsupportedPlatform) => Err(AuthTokenError::UnsupportedPlatform),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The `[guix_signing]` block reaches the daemon, and its absence is the
    /// feature being off rather than a parse error.
    #[test]
    fn guix_signing_is_optional_and_round_trips() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("gipsd.toml"),
            "listen = \"127.0.0.1:8080\"\ndb_path = \"/tmp/x.sqlite\"\n\
             ipfs_api = \"http://127.0.0.1:5001\"\ngns_command = \"gnunet-gns\"\n\
             [guix_signing]\nsecret_key = \"/etc/gips/signing-key.sec\"\nhost = \"berlin.example\"\n",
        )
        .unwrap();
        let config = GipsdConfig::load_from_home(dir.path()).unwrap();
        let signing = config
            .guix_signing
            .expect("a declared [guix_signing] block must survive the load");
        assert_eq!(
            signing.secret_key,
            PathBuf::from("/etc/gips/signing-key.sec")
        );
        assert_eq!(signing.host.as_deref(), Some("berlin.example"));
        assert_eq!(
            gips_trust::guix::public_key_path(&signing.secret_key),
            PathBuf::from("/etc/gips/signing-key.pub"),
            "the public half is the sibling, so there is no second path to get wrong"
        );

        // No block at all is not an error and not a half-configured signer.
        std::fs::write(
            dir.path().join("gipsd.toml"),
            "listen = \"127.0.0.1:8080\"\ndb_path = \"/tmp/x.sqlite\"\n\
             ipfs_api = \"http://127.0.0.1:5001\"\ngns_command = \"gnunet-gns\"\n",
        )
        .unwrap();
        assert!(GipsdConfig::load_from_home(dir.path())
            .unwrap()
            .guix_signing
            .is_none());
    }

    #[test]
    fn loopback_binds_without_opt_in() {
        let plan = plan_bind("127.0.0.1:8080", false).unwrap();
        assert_eq!(plan.exposure, Exposure::Loopback);
        assert_eq!(plan.addr.port(), 8080);
        assert_eq!(
            plan_bind("[::1]:8080", false).unwrap().exposure,
            Exposure::Loopback
        );
    }

    /// Enumerated test 2 (policy half): the address `scheme/README.md` used to
    /// advertise is refused unless it is asked for by name.
    #[test]
    fn public_bind_requires_explicit_opt_in() {
        for listen in ["0.0.0.0:9090", "[::]:9090", "192.168.1.10:9090"] {
            match plan_bind(listen, false) {
                Err(BindError::PublicWithoutOptIn { addr }) => {
                    assert_eq!(addr.port(), 9090);
                }
                other => panic!("{} must be refused, got {:?}", listen, other),
            }
            assert_eq!(
                plan_bind(listen, true).unwrap().exposure,
                Exposure::PublicOptedIn,
                "{} must be allowed once opted in",
                listen
            );
        }
    }

    #[test]
    fn malformed_listen_is_an_error_not_a_default() {
        assert!(matches!(
            plan_bind("not-an-address", false),
            Err(BindError::Malformed { .. })
        ));
        // Opting in does not rescue a malformed address.
        assert!(matches!(
            plan_bind("not-an-address", true),
            Err(BindError::Malformed { .. })
        ));
    }

    #[test]
    fn token_parse_rejects_everything_but_64_lowercase_hex() {
        let good = "0".repeat(64);
        assert_eq!(AuthToken::parse(&good).unwrap().as_str(), good);

        assert!(AuthToken::parse("").is_err());
        assert!(AuthToken::parse(&"0".repeat(63)).is_err());
        assert!(AuthToken::parse(&"0".repeat(65)).is_err());
        assert!(AuthToken::parse(&"A".repeat(64)).is_err());
        assert!(AuthToken::parse(&"g".repeat(64)).is_err());
    }

    #[test]
    fn debug_never_renders_the_secret() {
        let token = AuthToken::generate().unwrap();
        let rendered = format!("{:?}", token);
        assert!(!rendered.contains(token.as_str()), "{}", rendered);
    }

    #[test]
    fn generated_tokens_are_well_formed_and_distinct() {
        let a = AuthToken::generate().unwrap();
        let b = AuthToken::generate().unwrap();
        assert_eq!(a.as_str().len(), AUTH_TOKEN_HEX_LEN);
        assert!(AuthToken::parse(a.as_str()).is_ok());
        assert_ne!(a.as_str(), b.as_str());
    }

    #[cfg(unix)]
    #[test]
    fn stored_token_is_owner_only_and_round_trips() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("gips").join("auth-token");

        let created = AuthToken::load_or_create(&path).unwrap();
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "token file mode");

        // A second call reuses the token rather than rotating it.
        let loaded = AuthToken::load_or_create(&path).unwrap();
        assert_eq!(created.as_str(), loaded.as_str());
        assert_eq!(AuthToken::load(&path).unwrap().as_str(), created.as_str());
    }

    #[cfg(unix)]
    #[test]
    fn world_readable_token_is_refused() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("auth-token");
        AuthToken::generate().unwrap().store(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();

        assert!(matches!(
            AuthToken::load(&path),
            Err(AuthTokenError::InsecurePermissions { mode: 0o644, .. })
        ));
    }

    #[test]
    fn missing_token_is_missing_not_malformed() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nope");
        assert!(matches!(
            AuthToken::load(&path),
            Err(AuthTokenError::Missing { .. })
        ));
    }

    #[test]
    fn configured_token_path_overrides_the_default() {
        let mut config = GipsdConfig::default();
        assert_eq!(
            config.resolved_auth_token_path().unwrap(),
            default_auth_token_path()
        );
        config.auth_token_path = Some(PathBuf::from("/somewhere/else"));
        assert_eq!(
            config.resolved_auth_token_path().unwrap(),
            PathBuf::from("/somewhere/else")
        );
    }

    // -----------------------------------------------------------------------
    // Stage 20: no path is ever resolved against the working directory.
    // -----------------------------------------------------------------------

    /// Enumerated test 1 (config half, policy): with nothing to resolve, there
    /// is no config home — not `.`, not `./gips`.
    #[test]
    fn an_unresolvable_config_home_is_an_error_not_the_working_directory() {
        assert_eq!(
            resolve_config_home(None, None),
            Err(ConfigLocationError::Unresolvable)
        );

        let message = ConfigLocationError::Unresolvable.to_string();
        assert!(message.contains(CONFIG_DIR_ENV), "{}", message);
        assert!(
            message.contains("current working directory"),
            "the error must name what it refuses to do: {}",
            message
        );
    }

    /// A relative `GIPS_CONFIG_DIR` is the CWD fallback wearing a hat, so it is
    /// refused too.
    #[test]
    fn a_relative_explicit_config_dir_is_refused() {
        assert_eq!(
            resolve_config_home(
                Some(PathBuf::from("gips")),
                Some(PathBuf::from("/home/u/.config"))
            ),
            Err(ConfigLocationError::NotAbsolute {
                given: PathBuf::from("gips")
            })
        );
        assert_eq!(
            resolve_config_home(Some(PathBuf::from(".")), None),
            Err(ConfigLocationError::NotAbsolute {
                given: PathBuf::from(".")
            })
        );
    }

    #[test]
    fn an_explicit_config_dir_wins_over_the_platform_one() {
        assert_eq!(
            resolve_config_home(
                Some(PathBuf::from("/etc/gips")),
                Some(PathBuf::from("/home/u/.config"))
            )
            .unwrap(),
            PathBuf::from("/etc/gips")
        );
        assert_eq!(
            resolve_config_home(None, Some(PathBuf::from("/home/u/.config"))).unwrap(),
            PathBuf::from("/home/u/.config/gips")
        );
    }

    /// Every default path is absolute, so none of them can be reinterpreted by
    /// changing the daemon's working directory.
    #[test]
    fn default_paths_are_never_relative() {
        let config = GipsdConfig::default();
        assert!(config.db_path.is_absolute(), "{:?}", config.db_path);
        assert!(
            default_auth_token_path().is_absolute(),
            "{:?}",
            default_auth_token_path()
        );
        assert!(!config.db_path.starts_with("."));
    }

    /// Enumerated test 1 (config half, behaviour): pointed at a scratch home
    /// with no `gipsd.toml`, the loader returns defaults rooted *there* — it
    /// never reads a config file from anywhere else.
    #[test]
    fn load_from_home_uses_that_home_and_nothing_else() {
        let dir = tempfile::tempdir().unwrap();

        let missing = GipsdConfig::load_from_home(dir.path()).unwrap();
        assert_eq!(missing.db_path, dir.path().join("gipsd.sqlite"));
        assert_eq!(missing.listen, "127.0.0.1:8080");

        fs::write(
            dir.path().join("gipsd.toml"),
            "listen = \"127.0.0.1:9\"\ndb_path = \"/var/lib/gips/db.sqlite\"\n\
             ipfs_api = \"http://127.0.0.1:5001\"\ngns_command = \"gnunet-gns\"\n",
        )
        .unwrap();

        let loaded = GipsdConfig::load_from_home(dir.path()).unwrap();
        assert_eq!(loaded.listen, "127.0.0.1:9");
        assert_eq!(loaded.db_path, PathBuf::from("/var/lib/gips/db.sqlite"));
    }

    #[test]
    fn trust_survives_a_toml_round_trip() {
        let config: GipsdConfig = toml::from_str(
            r#"
            listen = "127.0.0.1:8080"
            db_path = "/tmp/gipsd.sqlite"
            ipfs_api = "http://127.0.0.1:5001"
            gns_command = "gnunet-gns"

            [trust]
            allow_unsigned = false

            [[trust.trusted_publishers]]
            gns_name = "alice.gnu"
            public_key = "/keys/alice.pem"
            "#,
        )
        .unwrap();
        assert_eq!(config.trust.trusted_publishers.len(), 1);
        assert_eq!(config.trust.trusted_publishers[0].gns_name, "alice.gnu");
    }

    // -----------------------------------------------------------------------
    // Stage 32: the shipped example configs are contract, not prose.
    // -----------------------------------------------------------------------

    /// `examples/gipsd-builder.toml`, compiled in from the repository root so
    /// the test fails at build time if the file is moved or deleted.
    const BUILDER_EXAMPLE: &str = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../examples/gipsd-builder.toml"
    ));

    /// `examples/gipsd-consumer.toml`.
    const CONSUMER_EXAMPLE: &str = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../examples/gipsd-consumer.toml"
    ));

    /// Enumerated test 5: both examples parse into a `GipsdConfig`, and each
    /// one still shows what the docs point at it for. Documentation that
    /// cannot be parsed is worse than no documentation: it is a config file
    /// someone will paste.
    #[test]
    fn the_shipped_examples_parse_and_show_what_they_claim_to_show() {
        let builder: GipsdConfig = toml::from_str(BUILDER_EXAMPLE)
            .expect("examples/gipsd-builder.toml must parse as a gipsd config");
        let signing = builder
            .trust
            .signing
            .as_ref()
            .expect("the builder example must demonstrate [trust.signing]");
        assert!(signing.narinfo_private_key != signing.narinfo_public_key);
        assert!(
            signing.publisher_gns_name.is_some(),
            "the builder example must name the GNS name consumers subscribe to"
        );
        let guix_signing = builder
            .guix_signing
            .as_ref()
            .expect("the builder example must demonstrate [guix_signing]");
        // The two keys are the whole point of the example: they must not be
        // shown as the same file.
        assert!(guix_signing.secret_key != signing.narinfo_private_key);
        assert!(!builder.trust.allow_unsigned);

        let consumer: GipsdConfig = toml::from_str(CONSUMER_EXAMPLE)
            .expect("examples/gipsd-consumer.toml must parse as a gipsd config");
        assert_eq!(
            consumer.trust.trusted_publishers.len(),
            1,
            "the consumer example demonstrates exactly one trusted publisher"
        );
        assert!(
            !consumer.trust.allow_unsigned,
            "the consumer example must keep fail-closed trust"
        );
        assert!(consumer.trust.signing.is_none());
        assert!(consumer.guix_signing.is_none());

        // The consumer trusts the name the builder publishes under; a reader
        // following both files must not have to guess that they line up.
        assert_eq!(
            consumer.trust.trusted_publishers[0].gns_name,
            *signing.publisher_gns_name.as_ref().unwrap()
        );
    }

    #[test]
    fn config_without_the_new_keys_still_parses() {
        let config: GipsdConfig = toml::from_str(
            r#"
            listen = "127.0.0.1:8080"
            db_path = "/tmp/gipsd.sqlite"
            ipfs_api = "http://127.0.0.1:5001"
            gns_command = "gnunet-gns"
            "#,
        )
        .unwrap();
        assert!(!config.insecure_bind);
        assert_eq!(config.auth_token_path, None);
    }

    #[test]
    fn token_rotation_replaces_token_atomically_with_valid_mode() {
        let dir = tempfile::tempdir().unwrap();
        let token_path = dir.path().join("auth.token");

        let first = AuthToken::load_or_create(&token_path).unwrap();
        assert_eq!(first.as_str().len(), 64);

        let second = AuthToken::rotate(&token_path).unwrap();
        assert_eq!(second.as_str().len(), 64);
        assert_ne!(first.as_str(), second.as_str());

        let loaded = AuthToken::load(&token_path).unwrap();
        assert_eq!(loaded.as_str(), second.as_str());
    }
}
