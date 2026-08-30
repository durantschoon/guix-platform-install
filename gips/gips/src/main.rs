use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use gips_config::AuthToken;
use reqwest::Client;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::time::Duration;

#[derive(Parser, Debug)]
#[command(name = "gips")]
#[command(about = "CLI for interacting with a local gipsd daemon")]
struct Cli {
    #[arg(long, global = true, default_value = "http://127.0.0.1:8080")]
    daemon: String,

    /// File holding the daemon's local auth token. Overrides
    /// `GIPS_AUTH_TOKEN_FILE`; both override the default config-directory path.
    #[arg(long, global = true)]
    auth_token_file: Option<PathBuf>,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand, Debug)]
enum Commands {
    Publish {
        store_path: String,
        #[arg(long)]
        gns_name: Option<String>,
        #[arg(long)]
        deriver: Option<String>,
        #[arg(long)]
        system: Option<String>,
    },
    /// Publish a store path directory hierarchy directly to IPFS as a native UnixFS DAG
    #[command(name = "publish-tree")]
    PublishTree {
        store_path: String,
        #[arg(long)]
        gns_name: Option<String>,
        #[arg(long)]
        deriver: Option<String>,
        #[arg(long)]
        system: Option<String>,
    },
    /// Backfill real integrity for substitute rows published before content
    /// verification existed, so they can be served again instead of 404ing.
    ///
    /// Feeds are not rewritten: this repairs what the local daemon serves.
    Reindex {
        /// Delete rows whose store object is no longer on disk. Off by
        /// default; without it a vanished path is reported and kept.
        #[arg(long)]
        prune_missing: bool,
        /// Limit the pass to this store path. Repeatable; absent means every
        /// row in the database.
        #[arg(long = "store-path")]
        store_paths: Vec<String>,
    },
    Subscribe {
        gns_name: String,
    },
    LinkChannel {
        channel_name: String,
        #[arg(long)]
        gns_name: String,
        /// Allow repointing a channel that is already linked to a different
        /// publisher. Without this the daemon refuses with 409.
        #[arg(long)]
        allow_repoint: bool,
    },
    Pin {
        ipfs_cid: String,
    },
    Unpin {
        ipfs_cid: String,
    },
    Status,
    Search {
        query: String,
    },
    /// Query substitutes by store path hash prefix (k-anonymity privacy query)
    #[command(name = "search-prefix")]
    SearchPrefix {
        prefix: String,
    },
    /// Generate a base64 Ed25519 signature over a canonical narinfo string
    SignNarinfo {
        /// The canonical string representing the narinfo properties to sign
        #[arg(long)]
        body: String,
        /// Path to the PEM encoded Ed25519 private key
        #[arg(long)]
        private_key: String,
        /// The publisher's GNS name (used as the key name in the signature string)
        #[arg(long)]
        publisher_name: String,
    },
    /// Manage offline capability snapshots
    Snapshot {
        #[command(subcommand)]
        snapshot_command: SnapshotCommands,
    },
    /// Manage this node's signing keys: the Guix-format narinfo key and the
    /// Ed25519 GIPS feed key
    Key {
        #[command(subcommand)]
        key_command: KeyCommands,
    },
    /// Manage local authentication tokens
    Auth {
        #[command(subcommand)]
        auth_command: AuthCommands,
    },
    /// Manage and inspect telemetry metrics and rolling history
    Metrics {
        #[command(subcommand)]
        metrics_command: MetricsCommands,
    },
    /// Manage attenuable capability delegation tokens
    Vouch {
        #[command(subcommand)]
        vouch_command: VouchCommands,
    },
    /// Evaluate web-of-trust reputation and delegation chains
    Trust {
        #[command(subcommand)]
        trust_command: TrustCommands,
    },
    /// Manage objective cryptographic fraud proofs and peer revocations
    #[command(name = "fraud-proof")]
    FraudProof {
        #[command(subcommand)]
        fraud_command: FraudProofCommands,
    },
    /// Inspect gossip propagation status and statistics
    Gossip {
        #[command(subcommand)]
        gossip_command: GossipCommands,
    },
    /// Terminal swarm monitor for node health, gossip peering, and live metrics
    Monitor {
        /// Print a single-pass snapshot and exit
        #[arg(long)]
        once: bool,
        /// Continuously watch live telemetry (clears screen every interval)
        #[arg(long)]
        watch: bool,
        /// Refresh interval in seconds for watch mode
        #[arg(long, default_value = "2")]
        interval_secs: u64,
        /// Output monitor telemetry as structured JSON
        #[arg(long)]
        json: bool,
    },
}

#[derive(Subcommand, Debug, PartialEq, Eq)]
enum GossipCommands {
    /// Display current gossip subscription status and statistics
    Status,
}

#[derive(Subcommand, Debug, PartialEq, Eq)]
enum FraudProofCommands {
    /// Generate an objective cryptographic fraud proof
    Generate {
        #[command(subcommand)]
        generate_command: FraudProofGenerateCommands,
    },
    /// Independently verify a cryptographic fraud proof
    Verify {
        /// Fraud proof JSON string or path to JSON file
        #[arg(long, allow_hyphen_values = true)]
        proof: String,
    },
    /// Submit a verified cryptographic fraud proof to the local daemon
    Submit {
        /// Fraud proof JSON string or path to JSON file
        #[arg(long, allow_hyphen_values = true)]
        proof: String,
    },
    /// List active revocations from the local daemon
    List,
}

#[derive(Subcommand, Debug, PartialEq, Eq)]
enum FraudProofGenerateCommands {
    /// Generate a HashMismatch fraud proof (narinfo signature vs mismatched artifact bytes)
    HashMismatch {
        /// Narinfo file path or raw narinfo string
        #[arg(long, allow_hyphen_values = true)]
        narinfo: String,
        /// Signature string or path to signature file
        #[arg(long, allow_hyphen_values = true)]
        signature: String,
        /// Path to artifact file or raw artifact bytes base64
        #[arg(long, allow_hyphen_values = true)]
        artifact: String,
        /// Publisher public key PEM string or path to PEM file
        #[arg(long, allow_hyphen_values = true)]
        publisher: String,
    },
    /// Generate an Equivocation fraud proof (two conflicting feed entries signed for same store path & timestamp)
    Equivocation {
        /// Path to first feed entry file or raw feed entry string
        #[arg(long = "feed-a", allow_hyphen_values = true)]
        feed_a: String,
        /// Path to second feed entry file or raw feed entry string
        #[arg(long = "feed-b", allow_hyphen_values = true)]
        feed_b: String,
        /// Publisher public key PEM string or path to PEM file
        #[arg(long, allow_hyphen_values = true)]
        publisher: String,
    },
}

#[derive(Subcommand, Debug, PartialEq, Eq)]
enum VouchCommands {
    /// Mint an attenuable capability delegation token
    Mint {
        /// Path to the PEM-encoded Ed25519 issuer private feed key
        #[arg(long)]
        issuer_key: PathBuf,
        /// Subject public key PEM string or path to PEM file
        #[arg(long, allow_hyphen_values = true)]
        subject: String,
        /// Token lifetime in seconds from now
        #[arg(long)]
        expires_in: u64,
        /// Optional parent token JSON or path to parent token JSON file
        #[arg(long, allow_hyphen_values = true)]
        parent_token: Option<String>,
        /// Maximum downstream delegation depth (0 = leaf, cannot delegate further)
        #[arg(long, default_value = "0")]
        depth: u32,
        /// Vouch weight / stake score (e.g. 1..100)
        #[arg(long, default_value = "100")]
        stake: u32,
        /// Allowed store path prefix. Can be repeated. Defaults to ["/gnu/store/"]
        #[arg(long = "prefix")]
        prefix: Vec<String>,
    },
    /// Verify a delegation chain against a trusted root public key
    Verify {
        /// Root public key PEM string or path to root public key PEM file
        #[arg(long, allow_hyphen_values = true)]
        root_key: String,
        /// Delegation chain as JSON string (array or single token) or path to JSON file
        #[arg(long, allow_hyphen_values = true)]
        chain: String,
        /// Optional target subject public key PEM string or path to PEM file
        #[arg(long, allow_hyphen_values = true)]
        target: Option<String>,
    },
    /// Inspect a delegation token and display a human-readable summary
    Inspect {
        /// Token JSON string or path to token JSON file
        #[arg(long, allow_hyphen_values = true)]
        token: String,
    },
    /// Ingest a verified delegation chain into the daemon database
    Ingest {
        /// Delegation chain as JSON string (array or single token) or path to JSON file
        #[arg(long, allow_hyphen_values = true)]
        chain: String,
    },
}

#[derive(Subcommand, Debug, PartialEq, Eq)]
enum TrustCommands {
    /// Evaluate effective trust score for a publisher
    Evaluate {
        /// Publisher public key PEM string or path to PEM file
        #[arg(long, allow_hyphen_values = true)]
        publisher: String,
        /// Optional store path to evaluate prefix capability authorization against
        #[arg(long)]
        path: Option<String>,
        /// Optional delegation chain as JSON string or path to JSON file
        #[arg(long, allow_hyphen_values = true)]
        chain: Option<String>,
    },
}

#[derive(Subcommand, Debug, PartialEq, Eq)]
enum MetricsCommands {
    /// Show current metrics snapshot
    Current {
        /// Output in Prometheus text exposition format
        #[arg(long)]
        prometheus: bool,
    },
    /// Show persisted rolling metrics history snapshots
    History {
        /// Maximum number of historical records to return
        #[arg(long, default_value = "50")]
        limit: i64,
    },
}

#[derive(Subcommand, Debug, PartialEq, Eq)]
enum AuthCommands {
    /// Rotate the local auth token, generating a fresh CSPRNG token and writing it atomically (mode 0600)
    Rotate {
        /// Path to the token file. If omitted, rotates the configured or default auth token path.
        #[arg(long)]
        token_file: Option<PathBuf>,
    },
}

#[derive(Subcommand, Debug)]
enum KeyCommands {
    /// Create the Guix-format signing key pair (a deliberate ceremony)
    ///
    /// Writes `<path>` and its sibling `<path with .pub>`, both 0600 inside a
    /// 0700 directory, and refuses if either already exists: the only thing
    /// that can verify a signature already published is the key that made it.
    GenerateGuix {
        /// Where the secret half goes. Defaults to
        /// `<config dir>/signing-key.sec`.
        #[arg(long)]
        path: Option<PathBuf>,
        /// The Guile interpreter to generate with. Defaults to `guile` on PATH.
        #[arg(long)]
        guile: Option<PathBuf>,
    },
    /// Print the public key, ready to pipe into `guix archive --authorize`
    ExportGuix {
        /// The secret half whose `.pub` sibling to print. Defaults to
        /// `<config dir>/signing-key.sec`.
        #[arg(long)]
        path: Option<PathBuf>,
    },
    /// Create the GIPS feed key pair — Ed25519, PKCS#8/SPKI PEM (a ceremony)
    ///
    /// This is the `[trust]` key one `gipsd` uses to decide whether to believe
    /// another `gipsd`'s feed. It is *not* the key `guix-daemon` checks; that
    /// one is `generate-guix`. Writes `<path>` and its sibling
    /// `<path>.pub.pem`, both 0600 inside a 0700 directory, and refuses if
    /// either already exists.
    GenerateFeed {
        /// Where the secret half goes. Defaults to
        /// `<config dir>/feed-signing-key.pem`.
        #[arg(long)]
        path: Option<PathBuf>,
    },
    /// Print the feed public key, for copying to consumer machines
    ExportFeed {
        /// The secret half whose `.pub.pem` sibling to print. Defaults to
        /// `<config dir>/feed-signing-key.pem`.
        #[arg(long)]
        path: Option<PathBuf>,
    },
    /// Advertise a public key to GNS under a name
    AdvertiseGns {
        /// The GNS name to publish the key record under (e.g. alice.gnu)
        #[arg(long)]
        name: String,
        /// Path to the key file whose public half to advertise
        #[arg(long)]
        path: Option<PathBuf>,
        /// The type of key: 'guix' (default) or 'feed'
        #[arg(long, default_value = "guix")]
        key_type: String,
    },
    /// Fetch an advertised public key from GNS, ready to pipe to `guix archive --authorize`
    FetchGns {
        /// The GNS name to resolve the key from (e.g. alice.gnu)
        #[arg(long)]
        name: String,
        /// The type of key: 'guix' (default) or 'feed'
        #[arg(long, default_value = "guix")]
        key_type: String,
    },
    /// Inspect, check, authorize, revoke, or diff keys in the Guix daemon ACL (/etc/guix/acl)
    Acl {
        #[command(subcommand)]
        acl_command: AclCommands,
    },
}

#[derive(Subcommand, Debug, PartialEq, Eq)]
enum AclCommands {
    /// List all authorized public keys in /etc/guix/acl
    List {
        /// Path to the Guix ACL file. Defaults to /etc/guix/acl (or GUIX_ACL_FILE).
        #[arg(long)]
        acl_file: Option<PathBuf>,
        /// Output in JSON format
        #[arg(long)]
        json: bool,
    },
    /// Check whether a public key is authorized in /etc/guix/acl
    Check {
        /// Path to the Guix ACL file. Defaults to /etc/guix/acl (or GUIX_ACL_FILE).
        #[arg(long)]
        acl_file: Option<PathBuf>,
        /// Path to a Guix public key (.pub) or secret (.sec) file
        #[arg(long)]
        key_file: Option<PathBuf>,
        /// GNS name to fetch public key from
        #[arg(long)]
        name: Option<String>,
        /// Raw public key sexp string or key identifier / hex
        #[arg(long)]
        key: Option<String>,
    },
    /// Authorize a Guix public key into /etc/guix/acl
    Authorize {
        /// Path to the Guix ACL file. Defaults to /etc/guix/acl (or GUIX_ACL_FILE).
        #[arg(long)]
        acl_file: Option<PathBuf>,
        /// Path to a Guix public key (.pub) or secret (.sec) file
        #[arg(long)]
        key_file: Option<PathBuf>,
        /// GNS name to fetch public key from
        #[arg(long)]
        name: Option<String>,
        /// Raw public key sexp string
        #[arg(long)]
        key: Option<String>,
        /// Dry run: display the updated ACL without writing to disk
        #[arg(long)]
        dry_run: bool,
    },
    /// Revoke an authorized key from /etc/guix/acl
    Revoke {
        /// Path to the Guix ACL file. Defaults to /etc/guix/acl (or GUIX_ACL_FILE).
        #[arg(long)]
        acl_file: Option<PathBuf>,
        /// Path to a Guix public key (.pub) or secret (.sec) file
        #[arg(long)]
        key_file: Option<PathBuf>,
        /// GNS name to fetch public key from
        #[arg(long)]
        name: Option<String>,
        /// Raw public key sexp string or key identifier / hex
        #[arg(long)]
        key: Option<String>,
        /// Dry run: display the updated ACL without writing to disk
        #[arg(long)]
        dry_run: bool,
    },
    /// Diff authorized keys in /etc/guix/acl against trusted or local key sets
    Diff {
        /// Path to the Guix ACL file. Defaults to /etc/guix/acl (or GUIX_ACL_FILE).
        #[arg(long)]
        acl_file: Option<PathBuf>,
        /// Paths to key files to compare against. Can be repeated. Defaults to local signing key if present.
        #[arg(long = "key-file")]
        key_files: Vec<PathBuf>,
        /// Output in JSON format
        #[arg(long)]
        json: bool,
    },
}

/// Where `gips key` looks when no `--path` is given.
///
/// The daemon's own `[guix_signing]` block is the authority once it is set;
/// this is only the default the ceremony proposes, printed back to the user so
/// there is never a doubt about which file was written.
fn default_guix_key_path() -> Result<PathBuf> {
    Ok(gips_config::config_home()
        .context("cannot decide where the signing key belongs")?
        .join("signing-key.sec"))
}

/// Where `gips key generate-feed`/`export-feed` look when no `--path` is given.
///
/// A different name from the Guix pair on purpose — see
/// [`gips_trust::feed::DEFAULT_SECRET_KEY_FILE_NAME`].
fn default_feed_key_path() -> Result<PathBuf> {
    Ok(gips_config::config_home()
        .context("cannot decide where the feed key belongs")?
        .join(gips_trust::feed::DEFAULT_SECRET_KEY_FILE_NAME))
}

fn resolve_acl_path(acl_file: Option<PathBuf>) -> PathBuf {
    if let Some(path) = acl_file {
        path
    } else if let Ok(env_path) = std::env::var("GUIX_ACL_FILE") {
        PathBuf::from(env_path)
    } else {
        PathBuf::from(gips_trust::DEFAULT_ACL_PATH)
    }
}

async fn resolve_guix_public_key(
    client: &Client,
    daemon_url: &str,
    key_file: Option<&Path>,
    name: Option<&str>,
    raw_key: Option<&str>,
) -> Result<String> {
    if let Some(k) = raw_key {
        return Ok(k.trim().to_string());
    }
    if let Some(path) = key_file {
        if path.extension().map_or(false, |ext| ext == "sec") {
            let pub_path = gips_trust::guix::public_key_path(path);
            if pub_path.exists() {
                return Ok(std::fs::read_to_string(&pub_path).with_context(|| {
                    format!("failed to read public key from {}", pub_path.display())
                })?);
            }
        }
        return Ok(std::fs::read_to_string(path)
            .with_context(|| format!("failed to read key from {}", path.display()))?);
    }
    if let Some(gns_name) = name {
        let url = format!("{}/key/resolve", daemon_url);
        let resp = client
            .get(url)
            .query(&[("name", gns_name), ("type", "guix")])
            .send()
            .await
            .context("failed to connect to daemon")?;
        if !resp.status().is_success() {
            let err = resp.text().await.unwrap_or_default();
            anyhow::bail!("failed to resolve key for {}: {}", gns_name, err);
        }
        let text = resp.text().await.context("failed to read response")?;
        return Ok(text.trim().to_string());
    }
    // Fallback: try local default Guix key
    let default_sec = default_guix_key_path()?;
    let default_pub = gips_trust::guix::public_key_path(&default_sec);
    if default_pub.exists() {
        return Ok(std::fs::read_to_string(&default_pub).with_context(|| {
            format!("failed to read public key from {}", default_pub.display())
        })?);
    }
    anyhow::bail!("no public key specified (provide --key-file, --name, or --key)")
}

/// `gips key generate-feed`. Returns what to print, so the ceremony can be
/// driven by a test without capturing stdout.
fn generate_feed_key(path: Option<PathBuf>) -> Result<String> {
    let secret = match path {
        Some(path) => path,
        None => default_feed_key_path()?,
    };
    let pair = gips_trust::feed::generate_key_pair(&secret)?;
    Ok(format!(
        "secret key: {}\npublic key: {}\n\n\
         Point gipsd at it with, in gipsd.toml:\n\n\
         [trust.signing]\nnarinfo_private_key = \"{}\"\nnarinfo_public_key = \"{}\"\n\
         publisher_gns_name = \"<your-name>.gnu\"\n\n\
         and let another gipsd trust this feed by copying the public half over \
         and naming it in its own gipsd.toml:\n\n\
         gips key export-feed --path {}\n\n\
         [[trust.trusted_publishers]]\ngns_name = \"<your-name>.gnu\"\n\
         public_key = \"<where you saved it>\"\n\n\
         This is the GIPS feed key. The key `guix-daemon` checks is the \
         separate one from `gips key generate-guix`.",
        pair.secret_key.display(),
        pair.public_key.display(),
        pair.secret_key.display(),
        pair.public_key.display(),
        pair.secret_key.display(),
    ))
}

/// `gips key export-feed`. Returns the public PEM exactly as stored.
fn export_feed_key(path: Option<PathBuf>) -> Result<String> {
    let secret = match path {
        Some(path) => path,
        None => default_feed_key_path()?,
    };
    Ok(gips_trust::feed::export_public_key(&secret)?)
}

#[derive(Subcommand, Debug, PartialEq, Eq)]
enum SnapshotCommands {
    /// Create a new snapshot from a Scheme manifest file
    ///
    /// Computes the manifest's closure with Guix, publishes every path in it
    /// through the daemon, and asks the daemon for a signed snapshot manifest.
    /// Requires `guix` on this machine.
    Create {
        /// Path to the Scheme manifest file
        manifest: String,
        /// Also publish the resulting snapshot CID to this GNS name. The
        /// daemon does the publishing; the CLI only forwards the name.
        #[arg(long)]
        gns_name: Option<String>,
    },
    /// List all known local snapshots
    List,
    /// Import a snapshot from an IPFS CID
    Import {
        /// IPFS CID of the snapshot manifest to import
        cid: String,
    },
    /// Export a snapshot and its constituent artifacts to a tar archive
    Export {
        /// IPFS CID of the snapshot manifest to export
        cid: String,
        /// Output file path for the tar archive (defaults to <cid>.tar)
        #[arg(long, short)]
        output: Option<PathBuf>,
    },
}

#[derive(Serialize)]
struct ImportSnapshotBody<'a> {
    cid: &'a str,
}

#[derive(Deserialize)]
struct ImportSnapshotReply {
    snapshot_cid: String,
    imported_entries: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SnapshotRecord {
    snapshot_cid: String,
    #[serde(default)]
    gns_name: Option<String>,
    store_paths: Vec<String>,
    created_at: i64,
}

#[derive(Serialize)]
struct PublishBody<'a> {
    store_path: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    gns_name: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    deriver: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    system: Option<&'a str>,
}

/// `gns_name` is omitted entirely when the user named none, so the request a
/// pre-stage-31 daemon sees is byte-identical to the one it has always seen.
#[derive(Serialize)]
struct CreateSnapshotBody<'a> {
    store_paths: Vec<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    gns_name: Option<&'a str>,
}

/// The daemon's answer to `POST /snapshot/create`.
#[derive(Deserialize)]
struct CreateSnapshotReply {
    snapshot_cid: String,
}

/// `store_paths` is omitted entirely when the user named none, because the
/// daemon reads an absent list as "every row" and an empty list as "no rows".
#[derive(Serialize)]
struct ReindexBody<'a> {
    prune_missing: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    store_paths: Option<Vec<&'a str>>,
}

#[derive(Serialize)]
struct SubscribeBody<'a> {
    gns_name: &'a str,
}

#[derive(Serialize)]
struct LinkChannelBody<'a> {
    channel_name: &'a str,
    gns_name: &'a str,
    allow_repoint: bool,
}

#[derive(Serialize)]
struct PinBody<'a> {
    ipfs_cid: &'a str,
}

#[derive(Serialize)]
struct UnpinBody<'a> {
    ipfs_cid: &'a str,
}

#[derive(Serialize)]
struct TrustEvaluateBody {
    publisher_key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    store_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    chain: Option<Vec<gips_trust::VouchToken>>,
}

#[derive(Deserialize)]
struct TrustEvaluateReply {
    score: u32,
    trusted: bool,
    reason: String,
}

#[derive(Serialize)]
struct VouchIngestBody {
    chain: Vec<gips_trust::VouchToken>,
}

#[derive(Deserialize)]
struct VouchIngestReply {
    #[allow(dead_code)]
    ok: bool,
    root_key: String,
    subject_key: String,
    message: String,
}

/// Where to read the daemon's auth token from, most explicit source first.
///
/// The ordering is deliberate and mirrors the fix to `(gips-base-url ...)`: a
/// value the user typed on this command line beats an environment variable a
/// stale shell left behind.
fn auth_token_path(explicit: Option<&Path>) -> PathBuf {
    if let Some(path) = explicit {
        return path.to_path_buf();
    }
    if let Some(value) = std::env::var_os("GIPS_AUTH_TOKEN_FILE") {
        if !value.is_empty() {
            return PathBuf::from(value);
        }
    }
    gips_config::default_auth_token_path()
}

/// Reads the token gipsd wrote. Failure is fatal: a mutating request is never
/// sent unauthenticated in the hope that the daemon is lenient.
fn load_auth_token(explicit: Option<&Path>) -> Result<AuthToken> {
    let path = auth_token_path(explicit);
    AuthToken::load(&path).with_context(|| {
        format!(
            "cannot authenticate to gipsd using {}; start gipsd once to create the token, or pass --auth-token-file",
            path.display()
        )
    })
}

/// Sends a mutating request with the local auth token attached.
///
/// Every mutating command goes through this one function, so "did we remember
/// to authenticate?" has a single answer.
async fn post_authorized<B: Serialize>(
    client: &Client,
    daemon: &str,
    path: &str,
    body: &B,
    token: &AuthToken,
) -> Result<String> {
    let url = format!("{}{}", daemon, path);
    let response = client
        .post(url)
        .bearer_auth(token.as_str())
        .json(body)
        .send()
        .await?;

    if response.status() == reqwest::StatusCode::UNAUTHORIZED {
        anyhow::bail!(
            "gipsd rejected the auth token for {}. The token file and the running daemon disagree; \
             restart gipsd or point --auth-token-file at the right file.",
            path
        );
    }

    Ok(response.text().await?)
}

/// Like [`post_authorized`], but any non-2xx answer is a hard error and the
/// body is parsed instead of printed.
///
/// The single-request commands can afford to print whatever the daemon said and
/// let the operator read it. A multi-step flow cannot: `snapshot create` has
/// work queued behind every request, so a failed step has to stop the run
/// rather than feed an error page into the next step.
async fn post_authorized_json<B: Serialize, T: DeserializeOwned>(
    client: &Client,
    daemon: &str,
    path: &str,
    body: &B,
    token: &AuthToken,
) -> Result<T> {
    let url = format!("{}{}", daemon, path);
    let response = client
        .post(&url)
        .bearer_auth(token.as_str())
        .json(body)
        .send()
        .await
        .with_context(|| format!("cannot reach gipsd at {}", url))?;

    let status = response.status();
    let text = response.text().await.unwrap_or_default();

    if status == reqwest::StatusCode::UNAUTHORIZED {
        anyhow::bail!(
            "gipsd rejected the auth token for {}. The token file and the running daemon disagree; \
             restart gipsd or point --auth-token-file at the right file.",
            path
        );
    }
    if !status.is_success() {
        anyhow::bail!(
            "gipsd answered {} for {}: {}",
            status,
            path,
            first_line(&text)
        );
    }

    serde_json::from_str(&text).with_context(|| {
        format!(
            "gipsd's answer to {} was not the JSON this command expects: {}",
            path,
            first_line(&text)
        )
    })
}

/// The first line of a daemon or subprocess message, clipped, for error text.
///
/// Error messages quote bytes this process did not produce; a multi-kilobyte
/// HTML error page or a store path with control characters in it must not be
/// able to redraw the terminal or bury the message that matters.
fn first_line(text: &str) -> String {
    let line = text.lines().next().unwrap_or("").trim();
    let clipped: String = line.chars().take(200).map(escape_control).collect();
    if line.chars().count() > 200 {
        format!("{}…", clipped)
    } else {
        clipped
    }
}

fn escape_control(c: char) -> char {
    if c.is_control() {
        '?'
    } else {
        c
    }
}

// ---------------------------------------------------------------------------
// `gips snapshot create`: manifest → closure → published snapshot.
// ---------------------------------------------------------------------------

/// What one subprocess run produced.
struct CommandOutput {
    /// True when the process exited 0.
    success: bool,
    /// The exit status rendered for a human. Only read on failure.
    status: String,
    stdout: String,
    stderr: String,
}

/// The future a [`CommandRunner`] hands back.
type CommandFuture = Pin<Box<dyn Future<Output = Result<CommandOutput>> + Send>>;

/// The seam every `guix` invocation goes through.
///
/// Production passes [`spawn_command`] and nothing else: there is no config
/// knob, no environment variable and no `#[cfg(test)]` branch in the shipped
/// path. Tests pass a closure returning canned stdout, because the machine this
/// was written on has no Guix — the parsing, validation, timeout and
/// abort semantics are exercised through the seam, while the flags themselves
/// are validated on a machine that has Guix.
type CommandRunner<'a> = &'a (dyn Fn(&str, &[String]) -> CommandFuture + Send + Sync);

/// How long one `guix` invocation may run before the CLI gives up on it.
///
/// Generous on purpose: `guix build -m` is allowed to build from source, which
/// is measured in hours on a slow machine. The timeout exists to bound a *hung*
/// subprocess, not to police a slow one.
const GUIX_COMMAND_TIMEOUT: Duration = Duration::from_secs(4 * 60 * 60);

/// Runs a real subprocess, capturing its output.
///
/// `kill_on_drop` is what makes the caller's timeout real: when the timeout
/// fires this future is dropped, and dropping it kills the child rather than
/// leaving a hung `guix` behind holding the store lock.
fn spawn_command(program: &str, args: &[String]) -> CommandFuture {
    let program = program.to_string();
    let args = args.to_vec();
    Box::pin(async move {
        let output = tokio::process::Command::new(&program)
            .args(&args)
            .stdin(std::process::Stdio::null())
            .kill_on_drop(true)
            .output()
            .await
            .with_context(|| format!("failed to run `{}`", render_command(&program, &args)))?;
        Ok(CommandOutput {
            success: output.status.success(),
            status: output.status.to_string(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
    })
}

/// A subprocess invocation as it should appear in an error message.
///
/// `guix gc --requisites` is handed the whole output set, which can be dozens
/// of store paths; an error message that pastes all of them hides the sentence
/// the operator needs to read.
fn render_command(program: &str, args: &[String]) -> String {
    let shown = 4.min(args.len());
    let mut rendered = program.to_string();
    for arg in &args[..shown] {
        rendered.push(' ');
        rendered.push_str(arg);
    }
    if args.len() > shown {
        rendered.push_str(&format!(" … ({} arguments in total)", args.len()));
    }
    rendered
}

/// Runs one `guix` invocation under `timeout`, returning its stdout.
///
/// Both failure modes name the command that failed, because the whole point of
/// the message is to tell the operator which of the two guix steps to rerun by
/// hand when they want to see the real output.
async fn run_guix(run: CommandRunner<'_>, args: &[String], timeout: Duration) -> Result<String> {
    let rendered = render_command("guix", args);
    let output = tokio::time::timeout(timeout, run("guix", args))
        .await
        .map_err(|_| {
            anyhow::anyhow!(
                "`{}` did not finish within {} seconds and was killed",
                rendered,
                timeout.as_secs()
            )
        })??;

    if !output.success {
        anyhow::bail!(
            "`{}` failed ({}): {}",
            rendered,
            output.status,
            first_line(&output.stderr)
        );
    }
    Ok(output.stdout)
}

/// The daemon's `is_valid_store_path`, replicated here.
///
/// `gips` deliberately does not depend on `gips-http`, and the CLI has to make
/// this judgement before anything reaches the wire: subprocess stdout is
/// untrusted input (stage 19), and a line that the daemon would reject with a
/// 400 should never have become a request in the first place. Keeping the rule
/// identical is what makes "the CLI accepted it" and "the daemon will accept
/// it" the same statement.
fn is_valid_store_path(path: &str) -> bool {
    const STORE_DIR: &str = "/gnu/store/";

    if !path.starts_with(STORE_DIR) {
        return false;
    }
    if path
        .split('/')
        .any(|segment| segment == ".." || segment == ".")
    {
        return false;
    }

    // Hash length and charset: 32 base32 characters, a dash, then the name.
    let file_part = &path[STORE_DIR.len()..];
    if file_part.len() < 34 {
        return false;
    }
    let (hash_part, remainder) = file_part.split_at(32);
    if !remainder.starts_with('-') {
        return false;
    }
    // Guix base32 alphabet (no e, o, u, t).
    let valid_chars = "0123456789abcdfghijklmnpqrsvwxyz";
    if !hash_part.chars().all(|c| valid_chars.contains(c)) {
        return false;
    }

    // Rejects newlines too, which is what stops one line of stdout from
    // smuggling a second path.
    if path.chars().any(|c| c.is_control()) {
        return false;
    }

    true
}

/// Parses subprocess stdout into store paths.
///
/// One bad line fails the whole run. Skipping it would be worse than useless:
/// a snapshot is a claim about a *complete* closure, and quietly dropping the
/// line we could not read is how an incomplete closure gets signed.
fn parse_store_paths(source: &str, stdout: &str) -> Result<Vec<String>> {
    let mut paths = Vec::new();
    for line in stdout.lines() {
        if line.trim().is_empty() {
            continue;
        }
        if !is_valid_store_path(line) {
            anyhow::bail!(
                "{} printed a line that is not a store path: \"{}\". Refusing the whole run: \
                 a snapshot over a closure we could only partly read is worse than no snapshot.",
                source,
                first_line(line)
            );
        }
        paths.push(line.to_string());
    }
    Ok(paths)
}

/// Computes the full closure of a Guix manifest, in two subprocess steps.
///
/// ```text
/// guix build -m <manifest>          → the manifest's output store paths
/// guix gc --requisites <output…>    → those outputs plus every path they
///                                     reference, transitively: the closure
/// ```
///
/// **Unverified against a real Guix**: the machine this was written on has none.
/// The flags are the first item on the Linux acceptance checklist.
async fn compute_manifest_closure(
    manifest: &str,
    run: CommandRunner<'_>,
    timeout: Duration,
) -> Result<Vec<String>> {
    let build_args = vec!["build".to_string(), "-m".to_string(), manifest.to_string()];
    let build_stdout = run_guix(run, &build_args, timeout)
        .await
        .context("step 1/4 (compute the manifest's outputs) failed; nothing was published")?;
    let outputs = parse_store_paths("`guix build -m`", &build_stdout)
        .context("step 1/4 (compute the manifest's outputs) failed; nothing was published")?;

    if outputs.is_empty() {
        anyhow::bail!(
            "step 1/4: `guix build -m {}` produced no store paths, so there is nothing to \
             snapshot; nothing was published",
            manifest
        );
    }

    let mut gc_args = vec!["gc".to_string(), "--requisites".to_string()];
    gc_args.extend(outputs.iter().cloned());
    let gc_stdout = run_guix(run, &gc_args, timeout)
        .await
        .context("step 2/4 (expand the outputs to their closure) failed; nothing was published")?;
    let mut closure = parse_store_paths("`guix gc --requisites`", &gc_stdout)
        .context("step 2/4 (expand the outputs to their closure) failed; nothing was published")?;

    // `guix gc --requisites` includes the paths it was asked about, but the
    // snapshot must contain them whether or not it does.
    closure.extend(outputs);
    closure.sort();
    closure.dedup();
    Ok(closure)
}

/// What a successful `gips snapshot create` produced.
#[derive(Debug)]
struct SnapshotCreated {
    snapshot_cid: String,
    /// How many closure paths were published on the way there.
    published: usize,
    /// The GNS name the daemon published the snapshot CID to, if any.
    gns_name: Option<String>,
}

/// The whole of `gips snapshot create`, from manifest to published snapshot.
///
/// Fails fast at every step and never half-succeeds silently: the error names
/// the step, and says what is already on the daemon, so the operator's next
/// move is obvious. Paths published before an abort stay published — that is
/// deliberate, and no rollback is attempted; republishing an unchanged store
/// path uploads the identical nar under the identical CID, so rerunning this
/// exact command is the remedy for every failure below.
#[allow(clippy::too_many_arguments)]
async fn run_snapshot_create(
    client: &Client,
    daemon: &str,
    token_file: Option<&Path>,
    manifest: &str,
    gns_name: Option<&str>,
    run: CommandRunner<'_>,
    timeout: Duration,
) -> Result<SnapshotCreated> {
    // Step 0: the token, before a subprocess is spawned or a socket is opened.
    // Discovering at step 4 that this machine cannot authenticate, after an
    // hour of `guix build`, is a bad way to learn it.
    let token = load_auth_token(token_file)?;

    let closure = compute_manifest_closure(manifest, run, timeout).await?;
    let total = closure.len();

    // Step 3: every path in the closure, published one at a time. The daemon
    // reads the bytes, hashes them and records them; there is no batch route,
    // and doing them in parallel would only race the same SQLite writer.
    for (index, store_path) in closure.iter().enumerate() {
        let body = PublishBody {
            store_path,
            // Deliberately not `gns_name`: a GNS name here would rewrite the
            // publisher's feed once per closure path. The name belongs to the
            // snapshot, and the daemon attaches it in step 4.
            gns_name: None,
            deriver: None,
            system: None,
        };
        let _: serde_json::Value = post_authorized_json(client, daemon, "/publish", &body, &token)
            .await
            .with_context(|| {
                format!(
                    "step 3/4 failed while publishing {} ({} of {}). The {} path(s) already \
                         published stay published — nothing is rolled back — and republishing an \
                         unchanged store path is safe, so rerunning this exact command is the \
                         remedy.",
                    store_path,
                    index + 1,
                    total,
                    index
                )
            })?;
    }

    // Step 4: the daemon builds, signs and pins the manifest. The CLI never
    // assembles a manifest itself — a snapshot entry the daemon did not derive
    // from its own database is a substitute-forgery primitive.
    let body = CreateSnapshotBody {
        store_paths: closure.iter().map(String::as_str).collect(),
        gns_name,
    };
    let reply: CreateSnapshotReply =
        post_authorized_json(client, daemon, "/snapshot/create", &body, &token)
            .await
            .with_context(|| match gns_name {
                Some(name) => format!(
                    "step 4/4 (create the snapshot manifest and publish it to {}) failed. All {} \
                     closure path(s) stay published; if the daemon reached GNS publication the \
                     snapshot itself was created and pinned, and only the name was not updated. \
                     Rerunning this exact command is safe.",
                    name, total
                ),
                None => format!(
                    "step 4/4 (create the snapshot manifest) failed. All {} closure path(s) stay \
                     published, so rerunning this exact command is safe.",
                    total
                ),
            })?;

    Ok(SnapshotCreated {
        snapshot_cid: reply.snapshot_cid,
        published: total,
        gns_name: gns_name.map(str::to_string),
    })
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let client = Client::new();
    let token_file = cli.auth_token_file.as_deref();

    match cli.command {
        Commands::Publish {
            store_path,
            gns_name,
            deriver,
            system,
        } => {
            let body = PublishBody {
                store_path: &store_path,
                gns_name: gns_name.as_deref(),
                deriver: deriver.as_deref(),
                system: system.as_deref(),
            };
            let token = load_auth_token(token_file)?;
            let text = post_authorized(&client, &cli.daemon, "/publish", &body, &token).await?;
            println!("{text}");
        }
        Commands::PublishTree {
            store_path,
            gns_name,
            deriver,
            system,
        } => {
            let body = PublishBody {
                store_path: &store_path,
                gns_name: gns_name.as_deref(),
                deriver: deriver.as_deref(),
                system: system.as_deref(),
            };
            let token = load_auth_token(token_file)?;
            let text =
                post_authorized(&client, &cli.daemon, "/publish-tree", &body, &token).await?;
            println!("{text}");
        }
        Commands::Reindex {
            prune_missing,
            store_paths,
        } => {
            let body = ReindexBody {
                prune_missing,
                store_paths: if store_paths.is_empty() {
                    None
                } else {
                    Some(store_paths.iter().map(String::as_str).collect())
                },
            };
            let token = load_auth_token(token_file)?;
            let text = post_authorized(&client, &cli.daemon, "/reindex", &body, &token).await?;
            println!("{text}");
        }
        Commands::Subscribe { gns_name } => {
            let body = SubscribeBody {
                gns_name: &gns_name,
            };
            let token = load_auth_token(token_file)?;
            let text = post_authorized(&client, &cli.daemon, "/subscribe", &body, &token).await?;
            println!("{text}");
        }
        Commands::LinkChannel {
            channel_name,
            gns_name,
            allow_repoint,
        } => {
            let body = LinkChannelBody {
                channel_name: &channel_name,
                gns_name: &gns_name,
                allow_repoint,
            };
            let token = load_auth_token(token_file)?;
            let text =
                post_authorized(&client, &cli.daemon, "/link-channel", &body, &token).await?;
            println!("{text}");
        }
        Commands::Pin { ipfs_cid } => {
            let body = PinBody {
                ipfs_cid: &ipfs_cid,
            };
            let token = load_auth_token(token_file)?;
            let text = post_authorized(&client, &cli.daemon, "/pin", &body, &token).await?;
            println!("{text}");
        }
        Commands::Unpin { ipfs_cid } => {
            let body = UnpinBody {
                ipfs_cid: &ipfs_cid,
            };
            let token = load_auth_token(token_file)?;
            let text = post_authorized(&client, &cli.daemon, "/unpin", &body, &token).await?;
            println!("{text}");
        }
        Commands::Status => {
            let url = format!("{}/status", cli.daemon);
            let resp = client.get(url).send().await?;
            let text = resp.text().await?;
            println!("{text}");
        }
        Commands::Search { query } => {
            let url = format!("{}/search", cli.daemon);
            let resp = client.get(url).query(&[("q", &query)]).send().await?;
            let text = resp.text().await?;
            println!("{text}");
        }
        Commands::SearchPrefix { prefix } => {
            let url = format!(
                "{}/substitute/prefix/{}",
                cli.daemon.trim_end_matches('/'),
                prefix
            );
            let resp = client.get(url).send().await?;
            let text = resp.text().await?;
            println!("{text}");
        }
        Commands::SignNarinfo {
            body,
            private_key,
            publisher_name,
        } => {
            let private_key_pem = std::fs::read_to_string(&private_key).map_err(|e| {
                anyhow::anyhow!("Failed to read private key at {}: {}", private_key, e)
            })?;
            let sig = gips_trust::sign_narinfo(&body, &private_key_pem, &publisher_name)?;
            println!("{}", sig);
        }
        Commands::Snapshot { snapshot_command } => match snapshot_command {
            SnapshotCommands::Create { manifest, gns_name } => {
                // Progress goes to stderr so that stdout stays exactly the two
                // machine-readable lines a script wants to capture.
                eprintln!("computing the closure of {manifest} with guix…");
                let created = run_snapshot_create(
                    &client,
                    &cli.daemon,
                    token_file,
                    &manifest,
                    gns_name.as_deref(),
                    &spawn_command,
                    GUIX_COMMAND_TIMEOUT,
                )
                .await?;
                eprintln!(
                    "published {} store path(s) from {manifest}",
                    created.published
                );
                println!("snapshot_cid: {}", created.snapshot_cid);
                if let Some(name) = &created.gns_name {
                    println!("gns_name: {name}");
                }
            }
            SnapshotCommands::List => {
                let url = format!("{}/snapshot/list", cli.daemon);
                let response = client
                    .get(&url)
                    .send()
                    .await
                    .with_context(|| format!("cannot reach gipsd at {}", url))?;

                let status = response.status();
                let text = response.text().await.unwrap_or_default();
                if !status.is_success() {
                    anyhow::bail!("gipsd returned error ({}): {}", status, first_line(&text));
                }

                let records: Vec<SnapshotRecord> =
                    serde_json::from_str(&text).with_context(|| {
                        format!("failed to parse snapshots JSON: {}", first_line(&text))
                    })?;

                if records.is_empty() {
                    println!("No snapshots found.");
                } else {
                    for rec in records {
                        println!("CID: {}", rec.snapshot_cid);
                        if let Some(gns) = &rec.gns_name {
                            println!("  GNS Name: {}", gns);
                        }
                        println!("  Created At: {}", rec.created_at);
                        println!("  Store Paths ({}):", rec.store_paths.len());
                        for path in &rec.store_paths {
                            println!("    - {}", path);
                        }
                        println!();
                    }
                }
            }
            SnapshotCommands::Import { cid } => {
                let token = load_auth_token(token_file)?;
                eprintln!("importing snapshot {cid} from IPFS…");
                let body = ImportSnapshotBody { cid: &cid };
                let reply: ImportSnapshotReply =
                    post_authorized_json(&client, &cli.daemon, "/snapshot/import", &body, &token)
                        .await?;
                println!("snapshot_cid: {}", reply.snapshot_cid);
                println!("imported_entries: {}", reply.imported_entries);
            }
            SnapshotCommands::Export { cid, output } => {
                let target_path = output.unwrap_or_else(|| PathBuf::from(format!("{}.tar", cid)));
                eprintln!("exporting snapshot {cid} to {}…", target_path.display());
                let url = format!("{}/snapshot/export/{}", cli.daemon, cid);
                let response = client
                    .get(&url)
                    .send()
                    .await
                    .with_context(|| format!("cannot reach gipsd at {}", url))?;

                let status = response.status();
                if !status.is_success() {
                    let text = response.text().await.unwrap_or_default();
                    anyhow::bail!("gipsd returned error ({}): {}", status, first_line(&text));
                }

                let bytes = response
                    .bytes()
                    .await
                    .with_context(|| "failed to read tar stream from daemon")?;
                tokio::fs::write(&target_path, &bytes)
                    .await
                    .with_context(|| {
                        format!("failed to write archive to {}", target_path.display())
                    })?;
                println!("Exported snapshot archive to {}", target_path.display());
            }
        },
        Commands::Key { key_command } => match key_command {
            KeyCommands::GenerateGuix { path, guile } => {
                let secret = match path {
                    Some(path) => path,
                    None => default_guix_key_path()?,
                };
                let pair = gips_trust::guix::generate_key_pair(&secret, guile.as_deref())?;
                println!("secret key: {}", pair.secret_key.display());
                println!("public key: {}", pair.public_key.display());
                println!();
                println!(
                    "Point gipsd at it with, in gipsd.toml:\n\n\
                     [guix_signing]\nsecret_key = \"{}\"\n\n\
                     and let a client trust it with:\n\n\
                     gips key export-guix --path {} | sudo guix archive --authorize",
                    pair.secret_key.display(),
                    pair.secret_key.display()
                );
            }
            KeyCommands::ExportGuix { path } => {
                let secret = match path {
                    Some(path) => path,
                    None => default_guix_key_path()?,
                };
                // Printed exactly as stored, with no trailing newline of our
                // own: `guix archive --authorize` reads this on stdin and the
                // bytes are the key's identity.
                print!("{}", gips_trust::guix::export_public_key(&secret)?);
            }
            KeyCommands::GenerateFeed { path } => {
                println!("{}", generate_feed_key(path)?);
            }
            KeyCommands::ExportFeed { path } => {
                // Exactly as stored, with no trailing newline of our own: the
                // bytes are the key's identity and this is meant to be piped
                // into a file on the consumer machine.
                print!("{}", export_feed_key(path)?);
            }
            KeyCommands::AdvertiseGns {
                name,
                path,
                key_type,
            } => {
                let public_key = match key_type.to_lowercase().as_str() {
                    "feed" => {
                        let secret = match path {
                            Some(path) => path,
                            None => default_feed_key_path()?,
                        };
                        gips_trust::feed::export_public_key(&secret)?
                    }
                    _ => {
                        let secret = match path {
                            Some(path) => path,
                            None => default_guix_key_path()?,
                        };
                        gips_trust::guix::export_public_key(&secret)?
                    }
                };

                let token = load_auth_token(token_file)?;
                let body = serde_json::json!({
                    "gns_name": name,
                    "public_key": public_key,
                    "key_type": key_type,
                });
                let url = format!("{}/key/advertise", cli.daemon);
                let resp = client
                    .post(url)
                    .bearer_auth(token.as_str())
                    .json(&body)
                    .send()
                    .await
                    .context("failed to connect to daemon")?;
                if !resp.status().is_success() {
                    let err = resp.text().await.unwrap_or_default();
                    anyhow::bail!("failed to advertise key: {}", err);
                }
                println!(
                    "Successfully advertised {} public key for {}",
                    key_type, name
                );
            }
            KeyCommands::FetchGns { name, key_type } => {
                let url = format!("{}/key/resolve", cli.daemon);
                let resp = client
                    .get(url)
                    .query(&[("name", &name), ("type", &key_type)])
                    .send()
                    .await
                    .context("failed to connect to daemon")?;
                if !resp.status().is_success() {
                    let err = resp.text().await.unwrap_or_default();
                    anyhow::bail!("failed to fetch key for {}: {}", name, err);
                }
                let text = resp.text().await.context("failed to read response")?;
                print!("{}", text);
            }
            KeyCommands::Acl { acl_command } => match acl_command {
                AclCommands::List { acl_file, json } => {
                    let path = resolve_acl_path(acl_file);
                    let acl = gips_trust::read_acl(&path)
                        .map_err(|e| anyhow::anyhow!("{}", e))
                        .with_context(|| format!("failed to read ACL from {}", path.display()))?;
                    if json {
                        println!("{}", serde_json::to_string_pretty(&acl.entries)?);
                    } else if acl.entries.is_empty() {
                        println!("No authorized keys found in {}.", path.display());
                    } else {
                        println!(
                            "Authorized Guix Keys ({}): {} key(s)",
                            path.display(),
                            acl.entries.len()
                        );
                        for (idx, entry) in acl.entries.iter().enumerate() {
                            let curve = entry.curve_or_algo.as_deref().unwrap_or("none");
                            let tags = entry.tags.join(" ");
                            println!(
                                "[{}] Type: {} (Curve/Algo: {})",
                                idx + 1,
                                entry.key_type.to_uppercase(),
                                curve
                            );
                            println!("    Identifier: {}", entry.identifier);
                            println!("    Tags: {}", tags);
                        }
                    }
                }
                AclCommands::Check {
                    acl_file,
                    key_file,
                    name,
                    key,
                } => {
                    let path = resolve_acl_path(acl_file);
                    let key_str = resolve_guix_public_key(
                        &client,
                        &cli.daemon,
                        key_file.as_deref(),
                        name.as_deref(),
                        key.as_deref(),
                    )
                    .await?;
                    let acl = gips_trust::read_acl(&path)
                        .map_err(|e| anyhow::anyhow!("{}", e))
                        .with_context(|| format!("failed to read ACL from {}", path.display()))?;
                    if acl.contains_key(&key_str) {
                        println!("Key is AUTHORIZED in {}.", path.display());
                    } else {
                        eprintln!("Key is NOT authorized in {}.", path.display());
                        std::process::exit(1);
                    }
                }
                AclCommands::Authorize {
                    acl_file,
                    key_file,
                    name,
                    key,
                    dry_run,
                } => {
                    let path = resolve_acl_path(acl_file);
                    let key_str = resolve_guix_public_key(
                        &client,
                        &cli.daemon,
                        key_file.as_deref(),
                        name.as_deref(),
                        key.as_deref(),
                    )
                    .await?;
                    let mut acl = gips_trust::read_acl(&path)
                        .map_err(|e| anyhow::anyhow!("{}", e))
                        .with_context(|| format!("failed to read ACL from {}", path.display()))?;
                    let added = acl
                        .authorize(&key_str, None)
                        .map_err(|e| anyhow::anyhow!("{}", e))?;
                    if !added {
                        println!("Key is already authorized in {}.", path.display());
                    } else if dry_run {
                        println!(
                            "[dry-run] Proposed updated ACL for {}:\n{}",
                            path.display(),
                            acl.to_sexp_string()
                        );
                    } else {
                        gips_trust::write_acl(&path, &acl)
                            .map_err(|e| anyhow::anyhow!("{}", e))
                            .with_context(|| {
                                format!("failed to write updated ACL to {}", path.display())
                            })?;
                        println!("Successfully authorized key into {}.", path.display());
                    }
                }
                AclCommands::Revoke {
                    acl_file,
                    key_file,
                    name,
                    key,
                    dry_run,
                } => {
                    let path = resolve_acl_path(acl_file);
                    let key_str = resolve_guix_public_key(
                        &client,
                        &cli.daemon,
                        key_file.as_deref(),
                        name.as_deref(),
                        key.as_deref(),
                    )
                    .await?;
                    let mut acl = gips_trust::read_acl(&path)
                        .map_err(|e| anyhow::anyhow!("{}", e))
                        .with_context(|| format!("failed to read ACL from {}", path.display()))?;
                    let revoked = acl.revoke(&key_str).map_err(|e| anyhow::anyhow!("{}", e))?;
                    if !revoked {
                        println!("Key was not found in {}.", path.display());
                    } else if dry_run {
                        println!(
                            "[dry-run] Proposed updated ACL for {}:\n{}",
                            path.display(),
                            acl.to_sexp_string()
                        );
                    } else {
                        gips_trust::write_acl(&path, &acl)
                            .map_err(|e| anyhow::anyhow!("{}", e))
                            .with_context(|| {
                                format!("failed to write updated ACL to {}", path.display())
                            })?;
                        println!("Successfully revoked key from {}.", path.display());
                    }
                }
                AclCommands::Diff {
                    acl_file,
                    key_files,
                    json,
                } => {
                    let path = resolve_acl_path(acl_file);
                    let acl = gips_trust::read_acl(&path)
                        .map_err(|e| anyhow::anyhow!("{}", e))
                        .with_context(|| format!("failed to read ACL from {}", path.display()))?;

                    let mut candidate_pubkeys = Vec::new();
                    if key_files.is_empty() {
                        let default_sec = default_guix_key_path()?;
                        let default_pub = gips_trust::guix::public_key_path(&default_sec);
                        if default_pub.exists() {
                            candidate_pubkeys.push(std::fs::read_to_string(&default_pub)?);
                        }
                    } else {
                        for kf in &key_files {
                            if kf.extension().map_or(false, |ext| ext == "sec") {
                                let pub_path = gips_trust::guix::public_key_path(kf);
                                if pub_path.exists() {
                                    candidate_pubkeys.push(std::fs::read_to_string(&pub_path)?);
                                    continue;
                                }
                            }
                            candidate_pubkeys.push(std::fs::read_to_string(kf)?);
                        }
                    }

                    let diff = gips_trust::diff_acl(&acl, &candidate_pubkeys)
                        .map_err(|e| anyhow::anyhow!("{}", e))?;
                    if json {
                        println!("{}", serde_json::to_string_pretty(&diff)?);
                    } else {
                        println!("=== Guix ACL Diff: {} ===", path.display());
                        println!(
                            "Matching in both ACL and trusted set ({}):",
                            diff.matching.len()
                        );
                        for entry in &diff.matching {
                            println!(
                                "  [+] {} (Identifier: {})",
                                entry.key_type.to_uppercase(),
                                entry.identifier
                            );
                        }
                        println!(
                            "In Guix ACL only (not in candidate trusted set) ({}):",
                            diff.in_acl_only.len()
                        );
                        for entry in &diff.in_acl_only {
                            println!(
                                "  [*] {} (Identifier: {})",
                                entry.key_type.to_uppercase(),
                                entry.identifier
                            );
                        }
                        println!(
                            "In candidate trusted set only (NOT authorized in Guix ACL) ({}):",
                            diff.in_trusted_only.len()
                        );
                        for key in &diff.in_trusted_only {
                            println!("  [-] Key: {}", key.lines().next().unwrap_or(key));
                        }
                    }
                }
            },
        },
        Commands::Auth { auth_command } => match auth_command {
            AuthCommands::Rotate { token_file } => {
                let path = match token_file {
                    Some(p) => p,
                    None => {
                        let config_dir = gips_config::config_home()?;
                        config_dir.join("auth.token")
                    }
                };
                let new_token = AuthToken::rotate(&path)?;
                println!(
                    "Successfully rotated auth token at {}: {}",
                    path.display(),
                    new_token.as_str()
                );
            }
        },
        Commands::Metrics { metrics_command } => {
            let token = load_auth_token(token_file)?;
            match metrics_command {
                MetricsCommands::Current { prometheus } => {
                    let url = format!("{}/metrics", cli.daemon);
                    let mut req = client.get(url).bearer_auth(token.as_str());
                    if prometheus {
                        req = req.header("Accept", "text/plain");
                    }
                    let resp = req.send().await.context("failed to connect to daemon")?;
                    let text = resp.text().await.context("failed to read response")?;
                    println!("{}", text);
                }
                MetricsCommands::History { limit } => {
                    let url = format!("{}/metrics/history", cli.daemon);
                    let req = client
                        .get(url)
                        .query(&[("limit", limit)])
                        .bearer_auth(token.as_str());
                    let resp = req.send().await.context("failed to connect to daemon")?;
                    let text = resp.text().await.context("failed to read response")?;
                    println!("{}", text);
                }
            }
        }
        Commands::Vouch { vouch_command } => match vouch_command {
            VouchCommands::Mint {
                issuer_key,
                subject,
                expires_in,
                parent_token,
                depth,
                stake,
                prefix,
            } => {
                let issuer_pem = std::fs::read_to_string(&issuer_key).with_context(|| {
                    format!("failed to read issuer key from {}", issuer_key.display())
                })?;
                let subject_pem = if Path::new(&subject).exists() {
                    std::fs::read_to_string(&subject)
                        .with_context(|| format!("failed to read subject key from {}", subject))?
                } else {
                    subject
                };
                let parent_sig = match parent_token {
                    Some(p) => {
                        let raw = if Path::new(&p).exists() {
                            std::fs::read_to_string(&p).with_context(|| {
                                format!("failed to read parent token from {}", p)
                            })?
                        } else {
                            p
                        };
                        if let Ok(tok) = serde_json::from_str::<gips_trust::VouchToken>(&raw) {
                            Some(tok.signature)
                        } else {
                            Some(raw.trim().to_string())
                        }
                    }
                    None => None,
                };
                let prefixes = if prefix.is_empty() {
                    vec!["/gnu/store/".to_string()]
                } else {
                    prefix
                };
                let capabilities = gips_trust::VouchCapabilities {
                    path_prefixes: prefixes,
                    max_depth: depth,
                    stake_score: stake,
                };
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_secs();
                let issued_at = now;
                let expires_at = now + expires_in;
                let token = gips_trust::mint_vouch_token(
                    &issuer_pem,
                    &subject_pem,
                    parent_sig,
                    issued_at,
                    expires_at,
                    capabilities,
                )
                .map_err(|e| anyhow::anyhow!("{}", e))
                .context("failed to mint vouch token")?;
                let json = serde_json::to_string_pretty(&token)?;
                println!("{}", json);
            }
            VouchCommands::Verify {
                root_key,
                chain,
                target,
            } => {
                let root_pem = if Path::new(&root_key).exists() {
                    std::fs::read_to_string(&root_key)
                        .with_context(|| format!("failed to read root key from {}", root_key))?
                } else {
                    root_key
                };
                let chain_json = if Path::new(&chain).exists() {
                    std::fs::read_to_string(&chain)
                        .with_context(|| format!("failed to read chain from {}", chain))?
                } else {
                    chain
                };
                let tokens: Vec<gips_trust::VouchToken> = match serde_json::from_str(&chain_json) {
                    Ok(v) => v,
                    Err(_) => {
                        let single: gips_trust::VouchToken = serde_json::from_str(&chain_json)
                            .context("failed to parse chain JSON as array or single token")?;
                        vec![single]
                    }
                };
                let target_pem =
                    match target {
                        Some(t) => {
                            if Path::new(&t).exists() {
                                Some(std::fs::read_to_string(&t).with_context(|| {
                                    format!("failed to read target key from {}", t)
                                })?)
                            } else {
                                Some(t)
                            }
                        }
                        None => None,
                    };
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_secs();
                let effective_caps =
                    gips_trust::verify_vouch_chain(&root_pem, &tokens, target_pem.as_deref(), now)
                        .map_err(|e| anyhow::anyhow!("{}", e))
                        .context("vouch chain verification failed")?;
                println!(
                    "Vouch chain verified successfully ({} hop(s)).",
                    tokens.len()
                );
                println!("Effective capabilities:");
                println!("  Max delegation depth: {}", effective_caps.max_depth);
                println!("  Stake score: {}", effective_caps.stake_score);
                println!(
                    "  Allowed path prefixes: {}",
                    effective_caps.path_prefixes.join(", ")
                );
            }
            VouchCommands::Inspect { token } => {
                let token_json = if Path::new(&token).exists() {
                    std::fs::read_to_string(&token)
                        .with_context(|| format!("failed to read token from {}", token))?
                } else {
                    token
                };
                let tok: gips_trust::VouchToken =
                    serde_json::from_str(&token_json).context("failed to parse token JSON")?;
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_secs();
                let status_str = match gips_trust::verify_vouch_token(&tok, now) {
                    Ok(()) => "Valid (active)".to_string(),
                    Err(e) => format!("Invalid: {}", e),
                };
                println!("Token Status: {}", status_str);
                println!("Issuer:\n{}", tok.payload.issuer.trim());
                println!("Subject:\n{}", tok.payload.subject.trim());
                println!(
                    "Parent Token: {}",
                    tok.payload.parent_token.as_deref().unwrap_or("<none>")
                );
                println!("Issued At: {}", tok.payload.issued_at);
                println!("Expires At: {}", tok.payload.expires_at);
                println!("Capabilities:");
                println!("  Max Depth: {}", tok.payload.capabilities.max_depth);
                println!("  Stake Score: {}", tok.payload.capabilities.stake_score);
                println!(
                    "  Path Prefixes: {}",
                    tok.payload.capabilities.path_prefixes.join(", ")
                );
                println!("Signature: {}", tok.signature);
            }
            VouchCommands::Ingest { chain } => {
                let chain_json = if Path::new(&chain).exists() {
                    std::fs::read_to_string(&chain)
                        .with_context(|| format!("failed to read chain from {}", chain))?
                } else {
                    chain
                };
                let tokens: Vec<gips_trust::VouchToken> = match serde_json::from_str(&chain_json) {
                    Ok(v) => v,
                    Err(_) => {
                        let single: gips_trust::VouchToken = serde_json::from_str(&chain_json)
                            .context("failed to parse chain JSON as array or single token")?;
                        vec![single]
                    }
                };

                let req = VouchIngestBody { chain: tokens };
                let token = load_auth_token(token_file)?;
                let res: VouchIngestReply =
                    post_authorized_json(&client, &cli.daemon, "/vouch/ingest", &req, &token)
                        .await?;

                println!("{}", res.message);
                println!("  Root:    {}", res.root_key.trim());
                println!("  Subject: {}", res.subject_key.trim());
            }
        },
        Commands::Trust { trust_command } => match trust_command {
            TrustCommands::Evaluate {
                publisher,
                path,
                chain,
            } => {
                let publisher_pem = if Path::new(&publisher).exists() {
                    std::fs::read_to_string(&publisher).with_context(|| {
                        format!("failed to read publisher key from {}", publisher)
                    })?
                } else {
                    publisher
                };

                let chain_tokens = match chain {
                    Some(c) => {
                        let raw = if Path::new(&c).exists() {
                            std::fs::read_to_string(&c)
                                .with_context(|| format!("failed to read chain from {}", c))?
                        } else {
                            c
                        };
                        let tokens: Vec<gips_trust::VouchToken> = match serde_json::from_str(&raw) {
                            Ok(v) => v,
                            Err(_) => {
                                let single: gips_trust::VouchToken = serde_json::from_str(&raw)
                                    .context(
                                        "failed to parse chain JSON as array or single token",
                                    )?;
                                vec![single]
                            }
                        };
                        Some(tokens)
                    }
                    None => None,
                };

                let req = TrustEvaluateBody {
                    publisher_key: publisher_pem.trim().to_string(),
                    store_path: path,
                    chain: chain_tokens,
                };

                let url = format!("{}/trust/evaluate", cli.daemon.trim_end_matches('/'));
                let response = client
                    .post(&url)
                    .header("Content-Type", "application/json")
                    .json(&req)
                    .send()
                    .await
                    .with_context(|| format!("cannot reach gipsd at {}", url))?;

                let status = response.status();
                let text = response.text().await.unwrap_or_default();
                if !status.is_success() {
                    anyhow::bail!("daemon returned error {}: {}", status, text);
                }

                let eval_res: TrustEvaluateReply = serde_json::from_str(&text)
                    .with_context(|| format!("failed to parse evaluation response: {}", text))?;

                println!("Trust Evaluation Report:");
                println!("  Publisher: {}", publisher_pem.trim());
                println!("  Score:     {}/100", eval_res.score);
                println!(
                    "  Trusted:   {}",
                    if eval_res.trusted { "YES" } else { "NO" }
                );
                println!("  Reason:    {}", eval_res.reason);
            }
        },
        Commands::FraudProof { fraud_command } => match fraud_command {
            FraudProofCommands::Generate { generate_command } => match generate_command {
                FraudProofGenerateCommands::HashMismatch {
                    narinfo,
                    signature,
                    artifact,
                    publisher,
                } => {
                    let narinfo_body = if Path::new(&narinfo).exists() {
                        std::fs::read_to_string(&narinfo)
                            .with_context(|| format!("failed to read narinfo from {}", narinfo))?
                    } else {
                        narinfo
                    };
                    let sig_str = if Path::new(&signature).exists() {
                        std::fs::read_to_string(&signature).with_context(|| {
                            format!("failed to read signature from {}", signature)
                        })?
                    } else {
                        signature
                    };
                    let artifact_bytes = if Path::new(&artifact).exists() {
                        std::fs::read(&artifact).with_context(|| {
                            format!("failed to read artifact bytes from {}", artifact)
                        })?
                    } else {
                        artifact.into_bytes()
                    };
                    let pub_key = if Path::new(&publisher).exists() {
                        std::fs::read_to_string(&publisher).with_context(|| {
                            format!("failed to read publisher key from {}", publisher)
                        })?
                    } else {
                        publisher
                    };

                    let proof = gips_trust::generate_hash_mismatch_proof(
                        &pub_key,
                        &narinfo_body,
                        &sig_str,
                        &artifact_bytes,
                    );
                    let json = serde_json::to_string_pretty(&proof)?;
                    println!("{}", json);
                }
                FraudProofGenerateCommands::Equivocation {
                    feed_a,
                    feed_b,
                    publisher,
                } => {
                    let feed_a_str = if Path::new(&feed_a).exists() {
                        std::fs::read_to_string(&feed_a)
                            .with_context(|| format!("failed to read feed-a from {}", feed_a))?
                    } else {
                        feed_a
                    };
                    let feed_b_str = if Path::new(&feed_b).exists() {
                        std::fs::read_to_string(&feed_b)
                            .with_context(|| format!("failed to read feed-b from {}", feed_b))?
                    } else {
                        feed_b
                    };
                    let pub_key = if Path::new(&publisher).exists() {
                        std::fs::read_to_string(&publisher).with_context(|| {
                            format!("failed to read publisher key from {}", publisher)
                        })?
                    } else {
                        publisher
                    };

                    let proof =
                        gips_trust::generate_equivocation_proof(&pub_key, &feed_a_str, &feed_b_str);
                    let json = serde_json::to_string_pretty(&proof)?;
                    println!("{}", json);
                }
            },
            FraudProofCommands::Verify { proof } => {
                let proof_json = if Path::new(&proof).exists() {
                    std::fs::read_to_string(&proof)
                        .with_context(|| format!("failed to read proof from {}", proof))?
                } else {
                    proof
                };
                let parsed: gips_trust::FraudProof = serde_json::from_str(&proof_json)
                    .or_else(|_| {
                        gips_trust::FraudProof::from_json(&proof_json)
                            .map_err(|e| anyhow::anyhow!(e))
                    })
                    .context("failed to parse fraud proof JSON")?;

                gips_trust::verify_fraud_proof(&parsed)
                    .map_err(|e| anyhow::anyhow!("{}", e))
                    .context("fraud proof verification failed")?;

                let kind = match parsed.proof_type {
                    gips_trust::FraudProofType::HashMismatch { .. } => "HashMismatch",
                    gips_trust::FraudProofType::Equivocation { .. } => "Equivocation",
                };
                println!(
                    "Fraud proof verified successfully (valid {} proof against publisher:\n{}).",
                    kind,
                    parsed.publisher_key.trim()
                );
            }
            FraudProofCommands::Submit { proof } => {
                let proof_json = if Path::new(&proof).exists() {
                    std::fs::read_to_string(&proof)
                        .with_context(|| format!("failed to read proof from {}", proof))?
                } else {
                    proof
                };
                let parsed: gips_trust::FraudProof = serde_json::from_str(&proof_json)
                    .or_else(|_| {
                        gips_trust::FraudProof::from_json(&proof_json)
                            .map_err(|e| anyhow::anyhow!(e))
                    })
                    .context("failed to parse fraud proof JSON")?;

                let url = format!("{}/fraud-proof/submit", cli.daemon);
                let response = client
                    .post(&url)
                    .header("Content-Type", "application/json")
                    .json(&parsed)
                    .send()
                    .await
                    .with_context(|| format!("cannot reach gipsd at {}", url))?;

                let status = response.status();
                let text = response.text().await.unwrap_or_default();
                if !status.is_success() {
                    anyhow::bail!(
                        "gipsd rejected fraud proof ({}): {}",
                        status,
                        first_line(&text)
                    );
                }
                println!("{}", text);
            }
            FraudProofCommands::List => {
                let url = format!("{}/fraud-proof/list", cli.daemon);
                let response = client
                    .get(&url)
                    .send()
                    .await
                    .with_context(|| format!("cannot reach gipsd at {}", url))?;

                let status = response.status();
                let text = response.text().await.unwrap_or_default();
                if !status.is_success() {
                    anyhow::bail!("gipsd returned error ({}): {}", status, first_line(&text));
                }
                println!("{}", text);
            }
        },
        Commands::Gossip { gossip_command } => match gossip_command {
            GossipCommands::Status => {
                let url = format!("{}/gossip/status", cli.daemon.trim_end_matches('/'));
                let response = client
                    .get(&url)
                    .send()
                    .await
                    .with_context(|| format!("cannot reach gipsd at {}", url))?;

                let status = response.status();
                let text = response.text().await.unwrap_or_default();
                if !status.is_success() {
                    anyhow::bail!("gipsd returned error ({}): {}", status, first_line(&text));
                }
                println!("{}", text);
            }
        },
        Commands::Monitor {
            once,
            watch,
            interval_secs,
            json,
        } => {
            let is_watch = watch && !once;
            let daemon = cli.daemon.trim_end_matches('/').to_string();
            let interval = std::cmp::max(interval_secs, 1);

            loop {
                let data = fetch_monitor_data(&client, &daemon).await;
                if is_watch {
                    // ANSI escape to clear screen and reset cursor
                    print!("\x1B[2J\x1B[1;1H");
                }

                if json {
                    println!("{}", serde_json::to_string_pretty(&data)?);
                } else {
                    render_monitor_data(&data);
                }

                if !is_watch {
                    break;
                }

                tokio::time::sleep(std::time::Duration::from_secs(interval)).await;
            }
        }
    }

    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct MonitorData {
    pub daemon_url: String,
    pub timestamp: u64,
    pub status: Option<serde_json::Value>,
    pub gossip: Option<serde_json::Value>,
    pub metrics: Option<serde_json::Value>,
    pub fraud_proofs_count: usize,
}

async fn fetch_monitor_data(client: &reqwest::Client, daemon: &str) -> MonitorData {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let status = if let Ok(resp) = client.get(format!("{}/status", daemon)).send().await {
        if resp.status().is_success() {
            resp.json::<serde_json::Value>().await.ok()
        } else {
            None
        }
    } else {
        None
    };

    let gossip = if let Ok(resp) = client.get(format!("{}/gossip/status", daemon)).send().await {
        if resp.status().is_success() {
            resp.json::<serde_json::Value>().await.ok()
        } else {
            None
        }
    } else {
        None
    };

    let metrics = if let Ok(resp) = client.get(format!("{}/metrics", daemon)).send().await {
        if resp.status().is_success() {
            resp.json::<serde_json::Value>().await.ok()
        } else {
            None
        }
    } else {
        None
    };

    let fraud_proofs_count = if let Ok(resp) = client
        .get(format!("{}/fraud-proof/list", daemon))
        .send()
        .await
    {
        if resp.status().is_success() {
            resp.json::<Vec<serde_json::Value>>()
                .await
                .ok()
                .map(|v| v.len())
                .unwrap_or(0)
        } else {
            0
        }
    } else {
        0
    };

    MonitorData {
        daemon_url: daemon.to_string(),
        timestamp: now,
        status,
        gossip,
        metrics,
        fraud_proofs_count,
    }
}

fn render_monitor_data(data: &MonitorData) {
    let transport = data
        .gossip
        .as_ref()
        .and_then(|g| g.get("transport_type"))
        .and_then(|t| t.as_str())
        .unwrap_or("unknown");
    let peer_count = data
        .gossip
        .as_ref()
        .and_then(|g| g.get("peer_count"))
        .and_then(|p| p.as_u64())
        .unwrap_or(0);
    let topics = data
        .gossip
        .as_ref()
        .and_then(|g| g.get("topics"))
        .and_then(|t| t.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        })
        .unwrap_or_else(|| "none".to_string());

    let vouches_rcv = data
        .gossip
        .as_ref()
        .and_then(|g| g.get("vouches_received"))
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    let vouches_acc = data
        .gossip
        .as_ref()
        .and_then(|g| g.get("vouches_accepted"))
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    let vouches_rej = data
        .gossip
        .as_ref()
        .and_then(|g| g.get("vouches_rejected"))
        .and_then(|v| v.as_u64())
        .unwrap_or(0);

    let fraud_rcv = data
        .gossip
        .as_ref()
        .and_then(|g| g.get("fraud_proofs_received"))
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    let fraud_acc = data
        .gossip
        .as_ref()
        .and_then(|g| g.get("fraud_proofs_accepted"))
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    let fraud_rej = data
        .gossip
        .as_ref()
        .and_then(|g| g.get("fraud_proofs_rejected"))
        .and_then(|v| v.as_u64())
        .unwrap_or(0);

    println!("================================================================================");
    println!("  GIPS SWARM & NODE MONITOR");
    println!("================================================================================");
    println!("  Daemon URL:     {}", data.daemon_url);
    println!(
        "  Gossip Backend: {} (Connected Peers: {})",
        transport, peer_count
    );
    println!("  Active Topics:  {}", topics);
    println!();
    println!("  [Gossip Telemetry]");
    println!(
        "    Vouches:       Received: {:<4} | Accepted: {:<4} | Rejected: {:<4}",
        vouches_rcv, vouches_acc, vouches_rej
    );
    println!(
        "    Fraud Proofs:  Received: {:<4} | Accepted: {:<4} | Rejected: {:<4}",
        fraud_rcv, fraud_acc, fraud_rej
    );
    println!(
        "    Active Proofs: {} revoked publisher(s)",
        data.fraud_proofs_count
    );
    println!();
    println!("  [Performance & Serving]");
    let reqs = data
        .metrics
        .as_ref()
        .and_then(|m| m.get("requests_total"))
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    println!("    Requests:      {}", reqs);
    println!("================================================================================");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::process::Command;
    use std::time::Duration;

    /// A single-request HTTP server that answers 200 only when the request
    /// carries `Authorization: Bearer <expected>`. Returns its base URL and a
    /// handle yielding what it actually saw.
    fn spawn_token_probe(expected: String) -> (String, std::thread::JoinHandle<Option<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());

        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();

            let mut buffer = vec![0u8; 8192];
            let read = stream.read(&mut buffer).unwrap_or(0);
            let request = String::from_utf8_lossy(&buffer[..read]).to_string();

            let seen = request.lines().find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.trim()
                    .eq_ignore_ascii_case("authorization")
                    .then(|| value.trim().to_string())
            });

            let response = if seen.as_deref() == Some(expected.as_str()) {
                "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}"
            } else {
                "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            };
            stream.write_all(response.as_bytes()).unwrap();
            stream.flush().unwrap();
            seen
        });

        (url, handle)
    }

    fn write_token(dir: &tempfile::TempDir) -> (PathBuf, AuthToken) {
        let path = dir.path().join("auth-token");
        let token = AuthToken::generate().unwrap();
        token.store(&path).unwrap();
        (path, token)
    }

    /// Enumerated test 4: a mutating CLI command round-trips using the token
    /// that is on disk — read from the file, presented as a bearer token,
    /// accepted by the server.
    #[tokio::test]
    async fn cli_round_trips_a_mutating_command_with_the_on_disk_token() {
        let dir = tempfile::tempdir().unwrap();
        let (path, token) = write_token(&dir);

        let loaded = load_auth_token(Some(&path)).expect("the CLI must read the on-disk token");
        assert_eq!(loaded.as_str(), token.as_str());

        let (url, probe) = spawn_token_probe(format!("Bearer {}", token.as_str()));
        let body = PinBody {
            ipfs_cid: "QmSomethingWorthPinning",
        };
        let text = post_authorized(&Client::new(), &url, "/pin", &body, &loaded)
            .await
            .expect("the daemon accepted the token");

        assert_eq!(text, "{\"ok\":true}");
        assert_eq!(
            probe.join().unwrap(),
            Some(format!("Bearer {}", token.as_str())),
            "the CLI must send the on-disk token"
        );
    }

    /// Stage 25, enumerated test 4 (CLI half): `gips reindex` round-trips with
    /// the on-disk token, and the body it sends says what the flags said.
    #[tokio::test]
    async fn cli_reindex_sends_the_on_disk_token_and_the_flags_it_was_given() {
        let dir = tempfile::tempdir().unwrap();
        let (path, token) = write_token(&dir);
        let loaded = load_auth_token(Some(&path)).expect("the CLI must read the on-disk token");

        let (url, probe) = spawn_token_probe(format!("Bearer {}", token.as_str()));
        let body = ReindexBody {
            prune_missing: true,
            store_paths: Some(vec![
                "/gnu/store/8009y4y5d4rhm796p02a7b8w6k2hvwq2-bash-5.1.16",
            ]),
        };
        let text = post_authorized(&Client::new(), &url, "/reindex", &body, &loaded)
            .await
            .expect("the daemon accepted the token");

        assert_eq!(text, "{\"ok\":true}");
        assert_eq!(
            probe.join().unwrap(),
            Some(format!("Bearer {}", token.as_str())),
            "gips reindex must send the on-disk token"
        );
    }

    /// Naming no `--store-path` must omit the field entirely: the daemon reads
    /// an absent list as "every row" and an empty one as "no rows", and a full
    /// pass is what `gips reindex` with no scope means.
    #[test]
    fn reindex_body_omits_an_empty_scope_rather_than_sending_an_empty_list() {
        let all = ReindexBody {
            prune_missing: false,
            store_paths: None,
        };
        assert_eq!(
            serde_json::to_string(&all).unwrap(),
            "{\"prune_missing\":false}"
        );

        let scoped = ReindexBody {
            prune_missing: true,
            store_paths: Some(vec!["/gnu/store/x"]),
        };
        assert_eq!(
            serde_json::to_string(&scoped).unwrap(),
            "{\"prune_missing\":true,\"store_paths\":[\"/gnu/store/x\"]}"
        );
    }

    /// The other half: a token that does not match is reported, not swallowed.
    #[tokio::test]
    async fn cli_reports_a_rejected_token_instead_of_printing_the_401_body() {
        let dir = tempfile::tempdir().unwrap();
        let (path, _token) = write_token(&dir);
        let loaded = load_auth_token(Some(&path)).unwrap();

        let (url, probe) = spawn_token_probe("Bearer something-else".to_string());
        let body = PinBody {
            ipfs_cid: "QmSomethingWorthPinning",
        };
        let err = post_authorized(&Client::new(), &url, "/pin", &body, &loaded)
            .await
            .expect_err("a 401 must be an error");
        assert!(
            err.to_string().contains("rejected the auth token"),
            "{}",
            err
        );
        let _ = probe.join();
    }

    #[test]
    fn explicit_token_path_wins_over_the_environment() {
        std::env::set_var("GIPS_AUTH_TOKEN_FILE", "/from/env");
        assert_eq!(
            auth_token_path(Some(Path::new("/explicit"))),
            PathBuf::from("/explicit")
        );
        assert_eq!(auth_token_path(None), PathBuf::from("/from/env"));
        std::env::remove_var("GIPS_AUTH_TOKEN_FILE");
        assert_eq!(
            auth_token_path(None),
            gips_config::default_auth_token_path()
        );
    }

    #[test]
    fn a_missing_token_is_a_hard_error() {
        let dir = tempfile::tempdir().unwrap();
        let err = load_auth_token(Some(&dir.path().join("nothing-here")))
            .expect_err("no token means no request");
        assert!(err.to_string().contains("cannot authenticate"), "{}", err);
    }

    // -----------------------------------------------------------------------
    // Stage 31: `gips snapshot create`.
    //
    // The guix half is driven through the command seam (this machine has no
    // Guix); the HTTP half is driven against a real axum stub on a loopback
    // port, so the assertions are about what a socket saw.
    // -----------------------------------------------------------------------

    use std::sync::{Arc, Mutex};

    // Three well-formed store paths. Sorted, they are BASH < GLIBC < ZLIB.
    const P_BASH: &str = "/gnu/store/8009y4y5d4rhm796p02a7b8w6k2hvwq2-bash-5.1.16";
    const P_GLIBC: &str = "/gnu/store/9wq2hvwq28009y4y5d4rhm796p02a7b8-glibc-2.35";
    const P_ZLIB: &str = "/gnu/store/hm796p02a7b8w6k2hvwq28009y4y5d4r-zlib-1.3";

    /// One canned answer from the guix seam.
    #[derive(Clone)]
    enum Canned {
        /// Exit 0 with this stdout.
        Out(String),
        /// Exit 1 with this stderr.
        Fail(String),
        /// Never answer at all — the subprocess that hangs.
        Hang,
    }

    fn out(lines: &[&str]) -> Canned {
        Canned::Out(lines.join("\n") + "\n")
    }

    /// A `guix` stand-in: answers `build` and `gc` from canned results and
    /// records every invocation it was handed.
    fn guix_double(
        build: Canned,
        gc: Canned,
        calls: Arc<Mutex<Vec<Vec<String>>>>,
    ) -> impl Fn(&str, &[String]) -> CommandFuture + Send + Sync + 'static {
        move |program: &str, args: &[String]| {
            assert_eq!(program, "guix", "only guix is ever shelled out to");
            calls.lock().unwrap().push(args.to_vec());
            let canned = match args.first().map(String::as_str) {
                Some("build") => build.clone(),
                Some("gc") => gc.clone(),
                other => panic!("unexpected guix subcommand: {other:?}"),
            };
            Box::pin(async move {
                match canned {
                    Canned::Out(stdout) => Ok(CommandOutput {
                        success: true,
                        status: "exit status: 0".to_string(),
                        stdout,
                        stderr: String::new(),
                    }),
                    Canned::Fail(stderr) => Ok(CommandOutput {
                        success: false,
                        status: "exit status: 1".to_string(),
                        stdout: String::new(),
                        stderr,
                    }),
                    Canned::Hang => {
                        std::future::pending::<()>().await;
                        unreachable!("a hanging command never answers")
                    }
                }
            })
        }
    }

    /// What the stub daemon saw on one request.
    struct StubRequest {
        path: String,
        authorization: Option<String>,
        body: serde_json::Value,
    }

    #[derive(Default)]
    struct StubDaemon {
        requests: Mutex<Vec<StubRequest>>,
    }

    impl StubDaemon {
        fn count(&self) -> usize {
            self.requests.lock().unwrap().len()
        }
    }

    fn record(
        stub: &Arc<StubDaemon>,
        path: &str,
        headers: axum::http::HeaderMap,
        body: &str,
    ) -> serde_json::Value {
        let parsed: serde_json::Value =
            serde_json::from_str(body).unwrap_or(serde_json::Value::Null);
        stub.requests.lock().unwrap().push(StubRequest {
            path: path.to_string(),
            authorization: headers
                .get(axum::http::header::AUTHORIZATION)
                .map(|v| v.to_str().unwrap_or_default().to_string()),
            body: parsed.clone(),
        });
        parsed
    }

    async fn stub_publish(
        axum::extract::State(stub): axum::extract::State<Arc<StubDaemon>>,
        headers: axum::http::HeaderMap,
        body: String,
    ) -> String {
        let parsed = record(&stub, "/publish", headers, &body);
        let store_path = parsed
            .get("store_path")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        serde_json::json!({ "store_path": store_path, "ipfs_cid": "QmStubArtifact" }).to_string()
    }

    async fn stub_snapshot_create(
        axum::extract::State(stub): axum::extract::State<Arc<StubDaemon>>,
        headers: axum::http::HeaderMap,
        body: String,
    ) -> String {
        record(&stub, "/snapshot/create", headers, &body);
        serde_json::json!({ "snapshot_cid": "QmStubSnapshotManifest" }).to_string()
    }

    async fn spawn_stub_daemon() -> (String, Arc<StubDaemon>) {
        let stub = Arc::new(StubDaemon::default());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let app = axum::Router::new()
            .route("/publish", axum::routing::post(stub_publish))
            .route(
                "/snapshot/create",
                axum::routing::post(stub_snapshot_create),
            )
            .with_state(stub.clone());
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        (format!("http://{addr}"), stub)
    }

    /// Enumerated test 1: canned guix output becomes a sorted, deduped closure.
    #[tokio::test]
    async fn the_closure_is_sorted_and_deduped() {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let run = guix_double(
            out(&[P_ZLIB, P_BASH]),
            // `guix gc` repeats what it was asked about and adds the rest.
            out(&[P_BASH, P_GLIBC, P_ZLIB, P_GLIBC]),
            calls.clone(),
        );

        let closure = compute_manifest_closure("sync-manifest.scm", &run, Duration::from_secs(5))
            .await
            .expect("canned output must parse");
        assert_eq!(closure, vec![P_BASH, P_GLIBC, P_ZLIB]);

        // Step 1 asked about the manifest; step 2 asked about step 1's outputs.
        let calls = calls.lock().unwrap();
        assert_eq!(
            calls[0],
            vec![
                "build".to_string(),
                "-m".to_string(),
                "sync-manifest.scm".to_string()
            ]
        );
        assert_eq!(calls[1][0], "gc");
        assert_eq!(calls[1][1], "--requisites");
        assert!(calls[1].contains(&P_BASH.to_string()));
        assert!(calls[1].contains(&P_ZLIB.to_string()));
    }

    /// Enumerated test 1, second half: a line that is not a store path fails
    /// the whole run rather than being skipped.
    #[test]
    fn a_line_that_is_not_a_store_path_is_refused() {
        for bad in [
            "gnu/store/8009y4y5d4rhm796p02a7b8w6k2hvwq2-bash-5.1.16", // relative
            "/etc/passwd",                                            // outside the store
            "/gnu/store/../etc/passwd",                               // traversal
            "/gnu/store/8009y4y5d4rhm796p02a7b8w6k2hvwq2-bash/../..", // traversal, deeper
            "/gnu/store/short-name",                                  // no 32-char hash
        ] {
            assert!(!is_valid_store_path(bad), "{bad} must be refused");
            let err = parse_store_paths("`guix build -m`", &format!("{P_BASH}\n{bad}\n"))
                .expect_err("one bad line fails the run");
            assert!(
                err.to_string().contains("not a store path"),
                "{err} must name the problem"
            );
        }

        // An embedded newline cannot survive line splitting, and a control
        // character in the line itself is refused outright.
        assert!(!is_valid_store_path(&format!("{P_BASH}\u{7}")));
        assert!(is_valid_store_path(P_BASH));
    }

    /// Enumerated test 1, third half: nothing reaches the daemon when the
    /// closure could not be read.
    #[tokio::test]
    async fn garbage_output_aborts_before_any_request() {
        let (daemon, stub) = spawn_stub_daemon().await;
        let dir = tempfile::tempdir().unwrap();
        let (token_path, _token) = write_token(&dir);
        let calls = Arc::new(Mutex::new(Vec::new()));
        let run = guix_double(out(&[P_BASH]), out(&["/etc/passwd"]), calls);

        let err = run_snapshot_create(
            &Client::new(),
            &daemon,
            Some(&token_path),
            "sync-manifest.scm",
            None,
            &run,
            Duration::from_secs(5),
        )
        .await
        .expect_err("a closure we cannot read must not be published");

        assert!(err.to_string().contains("step 2/4"), "{err}");
        assert_eq!(stub.count(), 0, "nothing may be published");
    }

    /// Enumerated test 2: a non-zero guix exit aborts, names the command, and
    /// publishes nothing.
    #[tokio::test]
    async fn a_failing_guix_command_aborts_naming_it() {
        let (daemon, stub) = spawn_stub_daemon().await;
        let dir = tempfile::tempdir().unwrap();
        let (token_path, _token) = write_token(&dir);
        let calls = Arc::new(Mutex::new(Vec::new()));
        let run = guix_double(
            Canned::Fail("guix build: error: no such manifest\n".to_string()),
            out(&[P_BASH]),
            calls.clone(),
        );

        let err = run_snapshot_create(
            &Client::new(),
            &daemon,
            Some(&token_path),
            "sync-manifest.scm",
            None,
            &run,
            Duration::from_secs(5),
        )
        .await
        .expect_err("a failed guix build must abort the run");

        let message = format!("{err:#}");
        assert!(message.contains("step 1/4"), "{message}");
        assert!(message.contains("guix build -m"), "{message}");
        assert!(message.contains("no such manifest"), "{message}");
        assert_eq!(stub.count(), 0, "nothing may be published");
        // The second step was never attempted.
        assert_eq!(calls.lock().unwrap().len(), 1);
    }

    /// Enumerated test 2, second half: a subprocess that never answers hits
    /// the timeout instead of hanging the CLI forever.
    #[tokio::test]
    async fn a_hanging_guix_command_hits_the_timeout() {
        let (daemon, stub) = spawn_stub_daemon().await;
        let dir = tempfile::tempdir().unwrap();
        let (token_path, _token) = write_token(&dir);
        let calls = Arc::new(Mutex::new(Vec::new()));
        let run = guix_double(Canned::Hang, out(&[P_BASH]), calls);

        let err = tokio::time::timeout(
            Duration::from_secs(10),
            run_snapshot_create(
                &Client::new(),
                &daemon,
                Some(&token_path),
                "sync-manifest.scm",
                None,
                &run,
                Duration::from_millis(50),
            ),
        )
        .await
        .expect("the CLI must give up long before the test does")
        .expect_err("a hung subprocess must abort the run");

        let message = format!("{err:#}");
        assert!(message.contains("did not finish within"), "{message}");
        assert_eq!(stub.count(), 0, "nothing may be published");
    }

    /// Enumerated test 3: the happy path publishes every closure path, then
    /// asks for the snapshot — every request carrying the on-disk token.
    #[tokio::test]
    async fn the_happy_path_publishes_the_closure_then_creates_the_snapshot() {
        let (daemon, stub) = spawn_stub_daemon().await;
        let dir = tempfile::tempdir().unwrap();
        let (token_path, token) = write_token(&dir);
        let calls = Arc::new(Mutex::new(Vec::new()));
        let run = guix_double(
            out(&[P_BASH]),
            out(&[P_BASH, P_ZLIB, P_BASH]),
            calls.clone(),
        );

        let created = run_snapshot_create(
            &Client::new(),
            &daemon,
            Some(&token_path),
            "sync-manifest.scm",
            Some("desktop-sync.gnu"),
            &run,
            Duration::from_secs(5),
        )
        .await
        .expect("the stub daemon accepts everything");

        assert_eq!(created.snapshot_cid, "QmStubSnapshotManifest");
        assert_eq!(created.published, 2);
        assert_eq!(created.gns_name.as_deref(), Some("desktop-sync.gnu"));

        let requests = stub.requests.lock().unwrap();
        assert_eq!(requests.len(), 3, "two publishes and one snapshot create");
        for request in requests.iter() {
            assert_eq!(
                request.authorization.as_deref(),
                Some(format!("Bearer {}", token.as_str()).as_str()),
                "every mutating request must carry the token: {}",
                request.path
            );
        }

        assert_eq!(requests[0].path, "/publish");
        assert_eq!(requests[0].body["store_path"], P_BASH);
        // The closure paths are published under no GNS name: the name belongs
        // to the snapshot, not to every path in it.
        assert!(requests[0].body.get("gns_name").is_none_or(|v| v.is_null()));
        assert_eq!(requests[1].path, "/publish");
        assert_eq!(requests[1].body["store_path"], P_ZLIB);

        assert_eq!(requests[2].path, "/snapshot/create");
        assert_eq!(
            requests[2].body["store_paths"],
            serde_json::json!([P_BASH, P_ZLIB])
        );
        assert_eq!(requests[2].body["gns_name"], "desktop-sync.gnu");
    }

    /// Without `--gns-name` the request the daemon sees is the one it has
    /// always seen: no `gns_name` field at all.
    #[test]
    fn the_snapshot_body_omits_an_absent_gns_name() {
        let named = CreateSnapshotBody {
            store_paths: vec![P_BASH],
            gns_name: Some("desktop-sync.gnu"),
        };
        assert_eq!(
            serde_json::to_string(&named).unwrap(),
            format!("{{\"store_paths\":[\"{P_BASH}\"],\"gns_name\":\"desktop-sync.gnu\"}}")
        );

        let anonymous = CreateSnapshotBody {
            store_paths: vec![P_BASH],
            gns_name: None,
        };
        assert_eq!(
            serde_json::to_string(&anonymous).unwrap(),
            format!("{{\"store_paths\":[\"{P_BASH}\"]}}")
        );
    }

    /// Enumerated test 4: a missing token file aborts naming the path, before
    /// any subprocess is spawned and before any request is sent.
    #[tokio::test]
    async fn a_missing_token_aborts_before_guix_and_before_the_network() {
        let (daemon, stub) = spawn_stub_daemon().await;
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("no-token-here");

        let never = |_: &str, _: &[String]| -> CommandFuture {
            panic!("no subprocess may run before the token is read")
        };

        let err = run_snapshot_create(
            &Client::new(),
            &daemon,
            Some(&missing),
            "sync-manifest.scm",
            None,
            &never,
            Duration::from_secs(5),
        )
        .await
        .expect_err("no token means no run");

        let message = format!("{err:#}");
        assert!(message.contains("cannot authenticate"), "{message}");
        assert!(
            message.contains(&missing.display().to_string()),
            "the error must name the token path: {message}"
        );
        assert_eq!(stub.count(), 0);
    }

    // -----------------------------------------------------------------------
    // The Scheme REPL client. These drive the real `scheme/gips/api.scm`
    // through `guile`, because the bugs they cover (env-var redirection and
    // curl flag injection) only exist in the shell-out path.
    // -----------------------------------------------------------------------

    fn repo_root() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("gips/ has a parent")
            .to_path_buf()
    }

    /// Runs a Guile snippet against the repo's scheme modules. `None` when
    /// `guile` is not installed — this is a test-harness capability check, not
    /// a fallback in shipped code.
    fn guile(script: &str, envs: &[(&str, &str)], path_prefix: Option<&Path>) -> Option<String> {
        let root = repo_root();
        let mut command = Command::new("guile");
        command
            .env("GUILE_LOAD_PATH", root.join("scheme"))
            .env("GUILE_AUTO_COMPILE", "0")
            .arg("-c")
            .arg(script);
        for (key, value) in envs {
            command.env(key, value);
        }
        if let Some(prefix) = path_prefix {
            let existing = std::env::var("PATH").unwrap_or_default();
            command.env("PATH", format!("{}:{}", prefix.display(), existing));
        }

        match command.output() {
            Ok(output) => {
                assert!(
                    output.status.success(),
                    "guile failed: {}",
                    String::from_utf8_lossy(&output.stderr)
                );
                Some(String::from_utf8_lossy(&output.stdout).to_string())
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                eprintln!("skipping: guile is not installed");
                None
            }
            Err(e) => panic!("failed to run guile: {}", e),
        }
    }

    /// Stage 31, enumerated test 6: `scripts/create_snapshot.scm` sends the
    /// local auth token, and refuses to run at all when it cannot read one.
    ///
    /// `/snapshot/create` has been behind the token check since stage 18, so
    /// the unauthenticated curl this replaces could only ever 401 — silently,
    /// because `curl -f` prints nothing. No daemon is needed to prove the
    /// refusal: the token is read before the first publish.
    #[test]
    fn the_snapshot_script_sends_the_token_and_refuses_to_run_without_one() {
        let script = repo_root().join("scripts").join("create_snapshot.scm");
        let source = std::fs::read_to_string(&script).unwrap();
        assert!(
            source.contains("\"Authorization: Bearer \" token"),
            "the script must send the token on /snapshot/create"
        );

        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("no-token-here");
        let output = match Command::new("guile")
            .arg(&script)
            .arg("alice.gnu")
            .arg("/gnu/store/8009y4y5d4rhm796p02a7b8w6k2hvwq2-bash-5.1.16")
            .env("GIPS_AUTH_TOKEN_FILE", &missing)
            .env("GUILE_AUTO_COMPILE", "0")
            .output()
        {
            Ok(output) => output,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                eprintln!("skipping: guile is not installed");
                return;
            }
            Err(e) => panic!("failed to run guile: {e}"),
        };

        assert!(
            !output.status.success(),
            "a missing token must be a hard error, not a silent unauthenticated attempt"
        );
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains(&missing.display().to_string()),
            "the error must name the token path it looked for: {stderr}"
        );
        assert!(
            !String::from_utf8_lossy(&output.stdout).contains("Publishing"),
            "nothing may be published before the token is read"
        );
    }

    /// Enumerated test 5: with `GIPS_DAEMON` set in the environment, an
    /// explicit `(gips-base-url "http://explicit")` still wins. Before the fix
    /// the env var silently redirected every request while the REPL reported
    /// the URL the user had asked for.
    #[test]
    fn explicit_base_url_wins_over_gips_daemon_env() {
        let script = r#"(use-modules (gips api))
(gips-base-url "http://explicit")
(display (gips-base-url))"#;
        let Some(out) = guile(
            script,
            &[("GIPS_DAEMON", "http://hostile.example:9999")],
            None,
        ) else {
            return;
        };
        assert_eq!(out.trim(), "http://explicit");
    }

    /// The environment is still honoured when nothing was set explicitly.
    #[test]
    fn gips_daemon_env_is_used_when_nothing_was_set_explicitly() {
        let script = "(use-modules (gips api)) (display (gips-base-url))";
        let Some(out) = guile(script, &[("GIPS_DAEMON", "http://from-env:9999")], None) else {
            return;
        };
        assert_eq!(out.trim(), "http://from-env:9999");
    }

    /// A base URL beginning with `-` must reach curl as an operand, not as an
    /// option: the `--` terminator is what stops `-K/etc/gips-token` from
    /// being read as a curl config file.
    #[test]
    fn base_url_cannot_inject_curl_options() {
        let dir = tempfile::tempdir().unwrap();
        let fake_curl = dir.path().join("curl");
        std::fs::write(
            &fake_curl,
            "#!/bin/sh\nfor a in \"$@\"; do echo \"ARG:$a\"; done\n",
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&fake_curl, std::fs::Permissions::from_mode(0o755)).unwrap();
        }

        let script = r#"(use-modules (gips api))
(gips-base-url "-K/etc/gips-hostile-config")
(display (gips-status))"#;
        let Some(out) = guile(script, &[], Some(dir.path())) else {
            return;
        };

        let args: Vec<&str> = out
            .lines()
            .filter_map(|line| line.strip_prefix("ARG:"))
            .collect();
        let terminator = args
            .iter()
            .position(|a| *a == "--")
            .expect("curl must be invoked with a -- terminator");
        let url = args
            .iter()
            .position(|a| *a == "-K/etc/gips-hostile-config/status")
            .expect("the base URL must be passed through as-is");
        assert!(
            terminator < url,
            "the URL must come after --, got {:?}",
            args
        );
    }

    // -----------------------------------------------------------------------
    // Stage 32: the feed-key ceremony, driven through the CLI's own argument
    // handling.
    // -----------------------------------------------------------------------

    /// Parses an argv the way `main` does and hands back the `key` subcommand.
    fn parse_key_command(args: &[&str]) -> KeyCommands {
        match Cli::try_parse_from(args).expect("argv must parse").command {
            Commands::Key { key_command } => key_command,
            other => panic!("expected a key command, got {:?}", other),
        }
    }

    /// Enumerated test 6: `generate-feed --path <tmp>` then
    /// `export-feed --path <tmp>` round-trip through clap and the handlers.
    ///
    /// Enumerated test 4 (CLI half) rides along: export prints exactly the
    /// bytes on disk, and a missing key is an `Err` — which `main` returns, so
    /// the process exits non-zero — naming the path it looked at.
    #[test]
    fn generate_feed_then_export_feed_round_trips_through_the_cli() {
        let dir = tempfile::tempdir().unwrap();
        let secret = dir.path().join("keys").join("feed-signing-key.pem");
        let secret_arg = secret.to_str().unwrap();

        // Nothing is there yet: export must fail, and say where it looked.
        let KeyCommands::ExportFeed { path } =
            parse_key_command(&["gips", "key", "export-feed", "--path", secret_arg])
        else {
            panic!("expected export-feed");
        };
        let error = export_feed_key(path).unwrap_err().to_string();
        assert!(
            error.contains("feed-signing-key.pub.pem"),
            "the failure must name the path it looked at, got {}",
            error
        );

        let KeyCommands::GenerateFeed { path } =
            parse_key_command(&["gips", "key", "generate-feed", "--path", secret_arg])
        else {
            panic!("expected generate-feed");
        };
        let summary = generate_feed_key(path).unwrap();
        let public = gips_trust::feed::public_key_path(&secret);
        assert!(summary.contains(secret_arg), "{}", summary);
        assert!(
            summary.contains(&public.display().to_string()),
            "both paths are printed, got {}",
            summary
        );
        // The two-key confusion the docs warn about is warned about here too.
        assert!(summary.contains("generate-guix"), "{}", summary);

        let KeyCommands::ExportFeed { path } =
            parse_key_command(&["gips", "key", "export-feed", "--path", secret_arg])
        else {
            panic!("expected export-feed");
        };
        let exported = export_feed_key(path).unwrap();
        assert_eq!(exported, std::fs::read_to_string(&public).unwrap());
        assert!(exported.starts_with("-----BEGIN PUBLIC KEY-----"));

        // The ceremony refuses a second time rather than overwriting.
        let KeyCommands::GenerateFeed { path } =
            parse_key_command(&["gips", "key", "generate-feed", "--path", secret_arg])
        else {
            panic!("expected generate-feed");
        };
        assert!(generate_feed_key(path).is_err());
        assert_eq!(export_feed_key(Some(secret)).unwrap(), exported);
    }

    #[test]
    fn auth_rotate_parses_and_rotates_token() {
        let dir = tempfile::tempdir().unwrap();
        let token_path = dir.path().join("auth.token");
        let initial = AuthToken::load_or_create(&token_path).unwrap();

        let cli = Cli::try_parse_from([
            "gips",
            "auth",
            "rotate",
            "--token-file",
            token_path.to_str().unwrap(),
        ])
        .unwrap();

        match cli.command {
            Commands::Auth {
                auth_command: AuthCommands::Rotate { token_file },
            } => {
                let path = token_file.unwrap();
                let rotated = AuthToken::rotate(&path).unwrap();
                assert_ne!(initial.as_str(), rotated.as_str());
                let loaded = AuthToken::load(&path).unwrap();
                assert_eq!(loaded.as_str(), rotated.as_str());
            }
            other => panic!("expected AuthCommands::Rotate, got {:?}", other),
        }
    }

    #[test]
    fn metrics_cli_parses_current_and_history() {
        let cli_current =
            Cli::try_parse_from(["gips", "metrics", "current", "--prometheus"]).unwrap();
        match cli_current.command {
            Commands::Metrics {
                metrics_command: MetricsCommands::Current { prometheus },
            } => assert!(prometheus),
            other => panic!("expected MetricsCommands::Current, got {:?}", other),
        }

        let cli_history =
            Cli::try_parse_from(["gips", "metrics", "history", "--limit", "25"]).unwrap();
        match cli_history.command {
            Commands::Metrics {
                metrics_command: MetricsCommands::History { limit },
            } => assert_eq!(limit, 25),
            other => panic!("expected MetricsCommands::History, got {:?}", other),
        }
    }

    #[test]
    fn key_gns_advertise_and_fetch_cli_parsing() {
        let cli_adv = Cli::try_parse_from([
            "gips",
            "key",
            "advertise-gns",
            "--name",
            "alice.gnu",
            "--key-type",
            "guix",
        ])
        .unwrap();

        match cli_adv.command {
            Commands::Key {
                key_command: KeyCommands::AdvertiseGns { name, key_type, .. },
            } => {
                assert_eq!(name, "alice.gnu");
                assert_eq!(key_type, "guix");
            }
            other => panic!("expected KeyCommands::AdvertiseGns, got {:?}", other),
        }

        let cli_fetch = Cli::try_parse_from([
            "gips",
            "key",
            "fetch-gns",
            "--name",
            "alice.gnu",
            "--key-type",
            "guix",
        ])
        .unwrap();

        match cli_fetch.command {
            Commands::Key {
                key_command: KeyCommands::FetchGns { name, key_type },
            } => {
                assert_eq!(name, "alice.gnu");
                assert_eq!(key_type, "guix");
            }
            other => panic!("expected KeyCommands::FetchGns, got {:?}", other),
        }
    }

    #[test]
    fn vouch_cli_mint_verify_inspect_parsing() {
        let dir = tempfile::tempdir().unwrap();
        let issuer_key = dir.path().join("issuer.pem");
        let pair = gips_trust::feed::generate_key_pair(&issuer_key).unwrap();

        // 1. Parse mint
        let cli_mint = Cli::try_parse_from([
            "gips",
            "vouch",
            "mint",
            "--issuer-key",
            pair.secret_key.to_str().unwrap(),
            "--subject",
            pair.public_key.to_str().unwrap(),
            "--expires-in",
            "86400",
            "--depth",
            "2",
            "--stake",
            "80",
            "--prefix",
            "/gnu/store/",
        ])
        .unwrap();

        match cli_mint.command {
            Commands::Vouch {
                vouch_command:
                    VouchCommands::Mint {
                        issuer_key: k,
                        subject: s,
                        expires_in: exp,
                        depth,
                        stake,
                        prefix,
                        ..
                    },
            } => {
                assert_eq!(k, pair.secret_key);
                assert_eq!(s, pair.public_key.to_str().unwrap());
                assert_eq!(exp, 86400);
                assert_eq!(depth, 2);
                assert_eq!(stake, 80);
                assert_eq!(prefix, vec!["/gnu/store/"]);
            }
            other => panic!("expected VouchCommands::Mint, got {:?}", other),
        }

        // 2. Parse verify
        let cli_verify = Cli::try_parse_from([
            "gips",
            "vouch",
            "verify",
            "--root-key",
            pair.public_key.to_str().unwrap(),
            "--chain",
            "[]",
            "--target",
            "target-key",
        ])
        .unwrap();

        match cli_verify.command {
            Commands::Vouch {
                vouch_command:
                    VouchCommands::Verify {
                        root_key,
                        chain,
                        target,
                    },
            } => {
                assert_eq!(root_key, pair.public_key.to_str().unwrap());
                assert_eq!(chain, "[]");
                assert_eq!(target, Some("target-key".to_string()));
            }
            other => panic!("expected VouchCommands::Verify, got {:?}", other),
        }

        // 3. Parse inspect
        let cli_inspect =
            Cli::try_parse_from(["gips", "vouch", "inspect", "--token", "{}"]).unwrap();

        match cli_inspect.command {
            Commands::Vouch {
                vouch_command: VouchCommands::Inspect { token },
            } => {
                assert_eq!(token, "{}");
            }
            other => panic!("expected VouchCommands::Inspect, got {:?}", other),
        }
    }

    #[test]
    fn fraud_proof_cli_parsing() {
        // 1. Generate hash-mismatch
        let cli_gen_hm = Cli::try_parse_from([
            "gips",
            "fraud-proof",
            "generate",
            "hash-mismatch",
            "--narinfo",
            "narinfo.txt",
            "--signature",
            "1;alice;sig",
            "--artifact",
            "artifact.nar",
            "--publisher",
            "pub.pem",
        ])
        .unwrap();

        match cli_gen_hm.command {
            Commands::FraudProof {
                fraud_command:
                    FraudProofCommands::Generate {
                        generate_command:
                            FraudProofGenerateCommands::HashMismatch {
                                narinfo,
                                signature,
                                artifact,
                                publisher,
                            },
                    },
            } => {
                assert_eq!(narinfo, "narinfo.txt");
                assert_eq!(signature, "1;alice;sig");
                assert_eq!(artifact, "artifact.nar");
                assert_eq!(publisher, "pub.pem");
            }
            other => panic!("expected FraudProof Generate HashMismatch, got {:?}", other),
        }

        // 2. Generate equivocation
        let cli_gen_eq = Cli::try_parse_from([
            "gips",
            "fraud-proof",
            "generate",
            "equivocation",
            "--feed-a",
            "feed_a.json",
            "--feed-b",
            "feed_b.json",
            "--publisher",
            "pub.pem",
        ])
        .unwrap();

        match cli_gen_eq.command {
            Commands::FraudProof {
                fraud_command:
                    FraudProofCommands::Generate {
                        generate_command:
                            FraudProofGenerateCommands::Equivocation {
                                feed_a,
                                feed_b,
                                publisher,
                            },
                    },
            } => {
                assert_eq!(feed_a, "feed_a.json");
                assert_eq!(feed_b, "feed_b.json");
                assert_eq!(publisher, "pub.pem");
            }
            other => panic!("expected FraudProof Generate Equivocation, got {:?}", other),
        }

        // 3. Verify
        let cli_verify =
            Cli::try_parse_from(["gips", "fraud-proof", "verify", "--proof", "proof.json"])
                .unwrap();

        match cli_verify.command {
            Commands::FraudProof {
                fraud_command: FraudProofCommands::Verify { proof },
            } => {
                assert_eq!(proof, "proof.json");
            }
            other => panic!("expected FraudProof Verify, got {:?}", other),
        }

        // 4. Submit
        let cli_submit =
            Cli::try_parse_from(["gips", "fraud-proof", "submit", "--proof", "proof.json"])
                .unwrap();

        match cli_submit.command {
            Commands::FraudProof {
                fraud_command: FraudProofCommands::Submit { proof },
            } => {
                assert_eq!(proof, "proof.json");
            }
            other => panic!("expected FraudProof Submit, got {:?}", other),
        }

        // 5. List
        let cli_list = Cli::try_parse_from(["gips", "fraud-proof", "list"]).unwrap();

        match cli_list.command {
            Commands::FraudProof {
                fraud_command: FraudProofCommands::List,
            } => {}
            other => panic!("expected FraudProof List, got {:?}", other),
        }
    }

    #[test]
    fn cli_parses_trust_evaluate_and_vouch_ingest() {
        // 1. Trust evaluate
        let cli_eval = Cli::try_parse_from([
            "gips",
            "trust",
            "evaluate",
            "--publisher",
            "alice_pub.pem",
            "--path",
            "/gnu/store/8009y4y5d4rhm796p02a7b8w6k2hvwq2-bash-5.1.16",
            "--chain",
            "chain.json",
        ])
        .unwrap();

        match cli_eval.command {
            Commands::Trust {
                trust_command:
                    TrustCommands::Evaluate {
                        publisher,
                        path,
                        chain,
                    },
            } => {
                assert_eq!(publisher, "alice_pub.pem");
                assert_eq!(
                    path,
                    Some("/gnu/store/8009y4y5d4rhm796p02a7b8w6k2hvwq2-bash-5.1.16".to_string())
                );
                assert_eq!(chain, Some("chain.json".to_string()));
            }
            other => panic!("expected Trust Evaluate, got {:?}", other),
        }

        // 2. Vouch ingest
        let cli_ingest =
            Cli::try_parse_from(["gips", "vouch", "ingest", "--chain", "chain.json"]).unwrap();

        match cli_ingest.command {
            Commands::Vouch {
                vouch_command: VouchCommands::Ingest { chain },
            } => {
                assert_eq!(chain, "chain.json");
            }
            other => panic!("expected Vouch Ingest, got {:?}", other),
        }
    }

    #[test]
    fn cli_snapshot_subcommands_parse_correctly() {
        // Snapshot List
        let cli_list = Cli::try_parse_from(["gips", "snapshot", "list"]).unwrap();
        match cli_list.command {
            Commands::Snapshot {
                snapshot_command: SnapshotCommands::List,
            } => {}
            other => panic!("expected Snapshot List, got {:?}", other),
        }

        // Snapshot Import
        let cli_import =
            Cli::try_parse_from(["gips", "snapshot", "import", "QmSnapCid123"]).unwrap();
        match cli_import.command {
            Commands::Snapshot {
                snapshot_command: SnapshotCommands::Import { cid },
            } => {
                assert_eq!(cid, "QmSnapCid123");
            }
            other => panic!("expected Snapshot Import, got {:?}", other),
        }

        // Snapshot Export default output
        let cli_export1 =
            Cli::try_parse_from(["gips", "snapshot", "export", "QmSnapCid456"]).unwrap();
        match cli_export1.command {
            Commands::Snapshot {
                snapshot_command: SnapshotCommands::Export { cid, output },
            } => {
                assert_eq!(cid, "QmSnapCid456");
                assert_eq!(output, None);
            }
            other => panic!("expected Snapshot Export, got {:?}", other),
        }

        // Snapshot Export custom output
        let cli_export2 = Cli::try_parse_from([
            "gips",
            "snapshot",
            "export",
            "QmSnapCid456",
            "-o",
            "/tmp/out.tar",
        ])
        .unwrap();
        match cli_export2.command {
            Commands::Snapshot {
                snapshot_command: SnapshotCommands::Export { cid, output },
            } => {
                assert_eq!(cid, "QmSnapCid456");
                assert_eq!(output, Some(PathBuf::from("/tmp/out.tar")));
            }
            other => panic!("expected Snapshot Export, got {:?}", other),
        }
        // Gossip Status
        let cli_gossip = Cli::try_parse_from(["gips", "gossip", "status"]).unwrap();
        match cli_gossip.command {
            Commands::Gossip {
                gossip_command: GossipCommands::Status,
            } => {}
            other => panic!("expected Gossip Status, got {:?}", other),
        }

        // Monitor Default
        let cli_mon1 = Cli::try_parse_from(["gips", "monitor", "--once"]).unwrap();
        match cli_mon1.command {
            Commands::Monitor {
                once,
                watch,
                interval_secs,
                json,
            } => {
                assert!(once);
                assert!(!watch);
                assert_eq!(interval_secs, 2);
                assert!(!json);
            }
            other => panic!("expected Monitor, got {:?}", other),
        }

        // Monitor Watch with JSON
        let cli_mon2 = Cli::try_parse_from([
            "gips",
            "monitor",
            "--watch",
            "--interval-secs",
            "5",
            "--json",
        ])
        .unwrap();
        match cli_mon2.command {
            Commands::Monitor {
                once,
                watch,
                interval_secs,
                json,
            } => {
                assert!(!once);
                assert!(watch);
                assert_eq!(interval_secs, 5);
                assert!(json);
            }
            other => panic!("expected Monitor, got {:?}", other),
        }

        // Search Prefix
        let cli_prefix = Cli::try_parse_from(["gips", "search-prefix", "4zi91dws"]).unwrap();
        match cli_prefix.command {
            Commands::SearchPrefix { prefix } => {
                assert_eq!(prefix, "4zi91dws");
            }
            other => panic!("expected SearchPrefix, got {:?}", other),
        }

        // Publish Tree
        let cli_tree = Cli::try_parse_from([
            "gips",
            "publish-tree",
            "/gnu/store/4zi91dws060g7x6a19ffmvf16f56s92c-hello-2.10",
            "--gns-name",
            "alice.gnu",
        ])
        .unwrap();
        match cli_tree.command {
            Commands::PublishTree {
                store_path,
                gns_name,
                ..
            } => {
                assert_eq!(
                    store_path,
                    "/gnu/store/4zi91dws060g7x6a19ffmvf16f56s92c-hello-2.10"
                );
                assert_eq!(gns_name.as_deref(), Some("alice.gnu"));
            }
            other => panic!("expected PublishTree, got {:?}", other),
        }
    }
}
