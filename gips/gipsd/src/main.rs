use anyhow::{Context, Result};
use gips_config::{AuthToken, BindPlan, ConfigLocationError, Exposure, GipsdConfig};
use gips_db::Database;
use gips_http::{build_router, start_mirror_worker};
use gips_scheme_config::merge_guile_config;
use gips_trust::fsintegrity::Expectation;
use std::path::{Path, PathBuf};
use tokio::net::TcpListener;
use tracing::{error, info, warn};

/// Decides where the daemon may listen, before anything is bound.
///
/// Kept as its own function so the refusal is exercisable: the only way `main`
/// reaches `TcpListener::bind` is through a `BindPlan` this returned.
fn startup_bind_plan(config: &GipsdConfig) -> Result<BindPlan> {
    let plan = gips_config::plan_bind(&config.listen, config.insecure_bind)?;
    Ok(plan)
}

/// Loads the local auth token, minting one on first run.
fn startup_auth_token(config: &GipsdConfig) -> Result<AuthToken> {
    let path = config.resolved_auth_token_path()?;
    let token = AuthToken::load_or_create(&path)?;
    // The path, never the token.
    info!(
        "mutating endpoints require the auth token in {}",
        path.display()
    );
    Ok(token)
}

/// Assembles the configuration, or refuses to start.
///
/// Takes the config home as a `Result` so the "there is no config home" branch
/// is exercisable without mutating process-wide environment variables — and so
/// that the refusal is the same code path in tests as in production.
///
/// Three things can stop the daemon here, all of them deliberately fatal:
///
/// 1. No resolvable config directory. The daemon used to read
///    `./gips/gipsd.toml` in that case, and that file names `gns_command` and
///    `guile_config`, both executed as subprocesses.
/// 2. An unreadable or malformed `gipsd.toml`.
/// 3. A `guile_config` script that fails, times out or prints something that
///    is not TOML. Starting on defaults would silently discard the trust
///    settings the operator wrote.
async fn startup_config(home: Result<PathBuf, ConfigLocationError>) -> Result<GipsdConfig> {
    let home = home.context("gipsd cannot decide where its configuration lives")?;
    info!("configuration directory: {}", home.display());

    for warning in gips_config::audit_warnings(&home, Expectation::OwnerOnly) {
        warn!("SECURITY: configuration directory {}", warning);
    }

    let base = GipsdConfig::load_from_home(&home)
        .with_context(|| format!("load configuration from {}", home.display()))?;
    let config = merge_guile_config(base).await?;

    audit_executables_named_by_config(&config);
    Ok(config)
}

/// Warns about programs the configuration will run.
///
/// `gns_command` and `guile_config` are executed as the daemon user, so
/// whoever can write them — or the directory holding them — decides what runs.
/// This is a warning rather than a refusal because a legitimately
/// root-installed program is "not owned by us" on a rootless daemon; the point
/// is that the boundary is stated rather than invisible.
fn audit_executables_named_by_config(config: &GipsdConfig) {
    // A bare command name (`gnunet-gns`) is resolved through `PATH`, which is
    // not a path we can audit; only an explicit path is checkable.
    let gns_path = Path::new(&config.gns_command);
    if config.gns_command.contains(std::path::MAIN_SEPARATOR) {
        for warning in gips_config::audit_warnings(gns_path, Expectation::NotWorldWritable) {
            warn!("SECURITY: gns_command {}", warning);
        }
    }

    if let Some(script) = &config.guile_config {
        for warning in gips_config::audit_warnings(script, Expectation::NotWorldWritable) {
            warn!("SECURITY: guile_config {}", warning);
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let config = startup_config(gips_config::config_home()).await?;

    // Both of these run before any socket, database or IPFS work: a daemon
    // that would expose itself publicly, or that has no usable auth token,
    // must not come up at all.
    let plan = startup_bind_plan(&config)?;
    let auth = startup_auth_token(&config)?;

    let db = Database::connect(&config).await?;

    start_mirror_worker(db.clone(), config.clone(), None);

    let mut snapshot = None;
    if let Some(ref cid) = config.snapshot_cid {
        info!("loading offline snapshot from {}", cid);
        let ipfs = gips_ipfs::IpfsClient::new(config.ipfs_api.clone());
        let bytes = ipfs.cat(cid).await.map_err(|e| {
            error!("failed to fetch snapshot CID {}: {:?}", cid, e);
            e
        })?;
        let manifest: gips_http::SnapshotManifest =
            serde_json::from_slice(&bytes).map_err(|e| {
                error!("failed to parse snapshot JSON from {}: {:?}", cid, e);
                e
            })?;

        let manifest_json = serde_json::to_string(&manifest.manifest)?;

        if !config.trust.allow_unsigned {
            let parts: Vec<&str> = manifest.signature.split(';').collect();
            if parts.len() == 3 {
                let pub_name = parts[1];
                if let Some(publisher) = config
                    .trust
                    .trusted_publishers
                    .iter()
                    .find(|p| p.gns_name == pub_name)
                {
                    if let Ok(pem) = std::fs::read_to_string(&publisher.public_key) {
                        if let Err(e) =
                            gips_trust::verify_narinfo(&manifest_json, &manifest.signature, &pem)
                        {
                            anyhow::bail!("Snapshot signature verification failed: {}", e);
                        }
                    } else {
                        anyhow::bail!("Failed to read public key file for publisher {}", pub_name);
                    }
                } else {
                    anyhow::bail!("Publisher {} not in trusted_publishers list", pub_name);
                }
            } else {
                anyhow::bail!("Malformed snapshot signature: {}", manifest.signature);
            }
        }

        info!("loaded snapshot with {} entries", manifest.manifest.len());
        snapshot = Some(manifest);
    }

    let auth_holder = std::sync::Arc::new(std::sync::RwLock::new(auth));
    let router = build_router(db, config.clone(), snapshot, auth_holder.clone());

    #[cfg(unix)]
    {
        let auth_holder = auth_holder.clone();
        let token_path = config.resolved_auth_token_path().ok();
        tokio::spawn(async move {
            use tokio::signal::unix::{signal, SignalKind};
            if let Ok(mut sighup) = signal(SignalKind::hangup()) {
                while sighup.recv().await.is_some() {
                    info!("SIGHUP received: reloading configuration and auth token");
                    if let Some(ref path) = token_path {
                        match AuthToken::load(path) {
                            Ok(new_token) => {
                                if let Ok(mut guard) = auth_holder.write() {
                                    *guard = new_token;
                                    info!("reloaded auth token from {}", path.display());
                                }
                            }
                            Err(e) => {
                                warn!("failed to reload auth token on SIGHUP: {}", e);
                            }
                        }
                    }
                }
            }
        });
    }

    if plan.exposure == Exposure::PublicOptedIn {
        warn!(
            "SECURITY: gipsd is listening on {}, which is reachable from outside this machine, \
             because insecure_bind = true. Every request that knows the auth token can publish, \
             pin and evict on this host. gipsd does not need this for multi-machine sync — IPFS \
             carries that traffic — so unset insecure_bind unless you are certain.",
            plan.addr
        );
    }

    let listener = TcpListener::bind(plan.addr).await?;
    info!("gipsd listening on {}", plan.addr);
    // The path to the telemetry UI, never the token that reads it: the token's
    // location was already logged by `startup_auth_token`.
    info!(
        "telemetry dashboard at http://{}/dashboard (it reads /metrics, which needs the auth token)",
        plan.addr
    );

    if let Err(e) = axum::serve(listener, router).await {
        error!("server error: {:?}", e);
        return Err(e.into());
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpStream;
    use std::time::Duration;

    /// Enumerated test 2: a `listen` of `0.0.0.0:9090` with no `insecure_bind`
    /// stops startup before anything is bound.
    #[test]
    fn public_listen_without_opt_in_refuses_to_start() {
        let config = GipsdConfig {
            listen: "0.0.0.0:9090".to_string(),
            insecure_bind: false,
            ..Default::default()
        };

        let err = startup_bind_plan(&config).expect_err("gipsd must refuse to start");
        let message = err.to_string();
        assert!(
            message.contains("refusing to listen on 0.0.0.0:9090"),
            "the error must name the address: {}",
            message
        );
        assert!(
            message.contains("insecure_bind"),
            "the error must say how to opt in: {}",
            message
        );

        // `main` binds a `BindPlan` and nothing else, so a refusal here is a
        // refusal to open the socket. Confirm the port really is not listening.
        let addr = "127.0.0.1:9090".parse().unwrap();
        assert!(
            TcpStream::connect_timeout(&addr, Duration::from_millis(200)).is_err(),
            "nothing may be listening on 9090"
        );
    }

    #[test]
    fn loopback_listen_starts_normally() {
        let config = GipsdConfig::default();
        let plan = startup_bind_plan(&config).expect("the default config must start");
        assert_eq!(plan.exposure, Exposure::Loopback);
        assert_eq!(plan.addr.to_string(), "127.0.0.1:8080");
    }

    #[test]
    fn public_listen_with_opt_in_starts_and_is_flagged_public() {
        let config = GipsdConfig {
            listen: "0.0.0.0:9090".to_string(),
            insecure_bind: true,
            ..Default::default()
        };

        let plan = startup_bind_plan(&config).expect("an explicit opt-in must be honoured");
        assert_eq!(plan.exposure, Exposure::PublicOptedIn);
    }

    #[test]
    fn malformed_listen_refuses_to_start() {
        let config = GipsdConfig {
            listen: "totally:not:an:address".to_string(),
            ..Default::default()
        };
        assert!(startup_bind_plan(&config).is_err());
    }

    // -----------------------------------------------------------------------
    // Stage 20: startup failure modes.
    // -----------------------------------------------------------------------

    /// Enumerated test 1 (config half): with no resolvable config directory
    /// the daemon stops with an error, rather than reading `./gips/gipsd.toml`
    /// out of whatever directory it was started in.
    #[tokio::test]
    async fn an_unresolvable_config_home_stops_startup() {
        let planted = std::env::current_dir().unwrap().join("gips");
        let planted_existed = planted.exists();

        let err = startup_config(Err(ConfigLocationError::Unresolvable))
            .await
            .expect_err("gipsd must refuse to start with nowhere to read config from");

        let message = format!("{:#}", err);
        assert!(
            message.contains("cannot decide where its configuration lives"),
            "{}",
            message
        );
        assert!(
            message.contains("GIPS_CONFIG_DIR"),
            "the error must say how to fix it: {}",
            message
        );
        assert_eq!(
            planted.exists(),
            planted_existed,
            "nothing may be read from or written to {}",
            planted.display()
        );
    }

    /// Enumerated test 3: a `guile_config` that exits non-zero refuses to
    /// start, and the defaults it would otherwise have fallen back to are not
    /// used.
    #[tokio::test]
    async fn a_failing_guile_config_stops_startup() {
        if std::process::Command::new("guile")
            .arg("--version")
            .output()
            .map(|o| !o.status.success())
            .unwrap_or(true)
        {
            eprintln!("skipping: guile is not installed");
            return;
        }

        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("broken.scm");
        std::fs::write(
            &script,
            "(display \"listen = \\\"127.0.0.1:1\\\"\\n\")\n(exit 7)\n",
        )
        .unwrap();
        std::fs::write(
            dir.path().join("gipsd.toml"),
            format!(
                "listen = \"127.0.0.1:8080\"\ndb_path = \"{}/gipsd.sqlite\"\n\
                 ipfs_api = \"http://127.0.0.1:5001\"\ngns_command = \"gnunet-gns\"\n\
                 guile_config = \"{}\"\n",
                dir.path().display(),
                script.display()
            ),
        )
        .unwrap();

        let err = startup_config(Ok(dir.path().to_path_buf()))
            .await
            .expect_err("a failing config script must stop startup");
        let message = format!("{:#}", err);
        assert!(message.contains("refusing to start"), "{}", message);
        assert!(message.contains("broken.scm"), "{}", message);
    }

    /// The happy path: a scratch config home is read, and every path the
    /// daemon will use is anchored there rather than at the working directory.
    #[tokio::test]
    async fn a_readable_config_home_starts_and_anchors_every_path() {
        let dir = tempfile::tempdir().unwrap();
        let config = startup_config(Ok(dir.path().to_path_buf()))
            .await
            .expect("a scratch config home must be usable");

        assert_eq!(config.db_path, dir.path().join("gipsd.sqlite"));
        assert_eq!(
            config.resolved_auth_token_path().unwrap(),
            gips_config::default_auth_token_path(),
            "an unset auth_token_path still resolves against the platform config home"
        );
        assert!(config.db_path.is_absolute());
    }

    /// Auditing the programs named by config never panics, whether the path is
    /// a bare command name, an absolute path, or missing entirely.
    #[test]
    fn auditing_configured_executables_tolerates_every_shape() {
        let mut config = GipsdConfig::default();
        audit_executables_named_by_config(&config);

        config.gns_command = "/usr/bin/gnunet-gns".to_string();
        config.guile_config = Some(PathBuf::from("/nonexistent/config.scm"));
        audit_executables_named_by_config(&config);
    }
}
