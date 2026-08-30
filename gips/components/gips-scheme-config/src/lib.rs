use gips_config::GipsdConfig;
use std::fmt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;

/// How long the configuration script may run before it is killed.
///
/// A config script is expected to print a TOML document and exit; anything
/// slower is either wedged or waiting on something a daemon's startup must not
/// depend on. The child is spawned with `kill_on_drop`, so a timeout reaps it
/// rather than leaving it running.
pub const GUILE_CONFIG_TIMEOUT: Duration = Duration::from_secs(5);

/// How far the script's stderr is quoted back in an error. Enough to diagnose,
/// bounded so a chatty script cannot flood the log.
const STDERR_EXCERPT_BYTES: usize = 2000;

/// Every way the Guile configuration path can fail.
///
/// All of these are fatal. Before Stage 20, a script that failed to run, timed
/// out, exited non-zero or printed garbage was answered with `Ok(base)` — the
/// daemon came up on defaults, which for a Scheme-configured install means an
/// empty trust list and whatever `listen`/`db_path` the Rust defaults choose.
/// Silently discarding the operator's security configuration is worse than not
/// starting.
#[derive(Debug)]
pub enum GuileConfigError {
    Spawn {
        path: PathBuf,
        source: std::io::Error,
    },
    Wait {
        path: PathBuf,
        source: std::io::Error,
    },
    TimedOut {
        path: PathBuf,
        timeout: Duration,
    },
    Failed {
        path: PathBuf,
        status: Option<i32>,
        stderr: String,
    },
    Malformed {
        path: PathBuf,
        source: toml::de::Error,
    },
    /// The script emitted a `[trust]` table the daemon cannot make sense of.
    MalformedTrust {
        path: PathBuf,
        source: toml::de::Error,
    },
    /// The script emitted a `[guix_signing]` table the daemon cannot make sense
    /// of. Fatal for the same reason as `MalformedTrust`: falling back to
    /// "signing off" would serve unsigned narinfos from a node whose operator
    /// declared, in writing, that it signs.
    MalformedGuixSigning {
        path: PathBuf,
        source: toml::de::Error,
    },
}

impl fmt::Display for GuileConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            GuileConfigError::Spawn { path, source } => write!(
                f,
                "refusing to start: could not run the guile_config script {}: {}",
                path.display(),
                source
            ),
            GuileConfigError::Wait { path, source } => write!(
                f,
                "refusing to start: the guile_config script {} could not be waited on: {}",
                path.display(),
                source
            ),
            GuileConfigError::TimedOut { path, timeout } => write!(
                f,
                "refusing to start: the guile_config script {} did not finish within {:?}",
                path.display(),
                timeout
            ),
            GuileConfigError::Failed {
                path,
                status,
                stderr,
            } => write!(
                f,
                "refusing to start: the guile_config script {} exited with {} and its \
                 configuration was therefore not applied; starting on defaults would silently \
                 drop the trust settings it declares. stderr: {}",
                path.display(),
                match status {
                    Some(code) => format!("status {}", code),
                    None => "a signal".to_string(),
                },
                stderr.trim()
            ),
            GuileConfigError::Malformed { path, source } => write!(
                f,
                "refusing to start: the guile_config script {} did not print valid TOML: {}",
                path.display(),
                source
            ),
            GuileConfigError::MalformedTrust { path, source } => write!(
                f,
                "refusing to start: the [trust] table printed by {} is not valid: {}",
                path.display(),
                source
            ),
            GuileConfigError::MalformedGuixSigning { path, source } => write!(
                f,
                "refusing to start: the [guix_signing] table printed by {} is not valid, so \
                 narinfos would be served unsigned by a node configured to sign them: {}",
                path.display(),
                source
            ),
        }
    }
}

impl std::error::Error for GuileConfigError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            GuileConfigError::Spawn { source, .. } | GuileConfigError::Wait { source, .. } => {
                Some(source)
            }
            GuileConfigError::Malformed { source, .. }
            | GuileConfigError::MalformedTrust { source, .. }
            | GuileConfigError::MalformedGuixSigning { source, .. } => Some(source),
            _ => None,
        }
    }
}

/// Load configuration overrides from a Guile Scheme file, if configured.
///
/// The Scheme file is expected to print a TOML document to stdout when
/// evaluated. Any keys it defines override the corresponding fields in
/// `GipsdConfig`, while unspecified fields keep their existing values.
///
/// Fail-closed: with `guile_config` set, either the script's configuration is
/// applied or the daemon does not start.
pub async fn merge_guile_config(base: GipsdConfig) -> Result<GipsdConfig, GuileConfigError> {
    merge_guile_config_within(base, GUILE_CONFIG_TIMEOUT).await
}

/// [`merge_guile_config`] with an explicit deadline, so the timeout path is
/// exercisable without a five-second test.
pub async fn merge_guile_config_within(
    base: GipsdConfig,
    timeout: Duration,
) -> Result<GipsdConfig, GuileConfigError> {
    let Some(path) = base.guile_config.clone() else {
        return Ok(base);
    };

    // This file is about to be executed as this user. Anyone who can write it
    // chooses what runs, so the boundary is stated out loud before we cross it.
    for warning in gips_config::audit_warnings(
        &path,
        gips_trust::fsintegrity::Expectation::NotWorldWritable,
    ) {
        eprintln!("gipsd: WARNING: guile_config {}", warning);
    }

    let child = Command::new("/usr/bin/env")
        .arg("guile")
        .arg("-s")
        .arg(&path)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|source| GuileConfigError::Spawn {
            path: path.clone(),
            source,
        })?;

    let output = match tokio::time::timeout(timeout, child.wait_with_output()).await {
        Ok(Ok(output)) => output,
        Ok(Err(source)) => {
            return Err(GuileConfigError::Wait {
                path: path.clone(),
                source,
            })
        }
        // Dropping the future drops the `Child`, which was spawned with
        // `kill_on_drop`, so the wedged script is reaped rather than left
        // running for the life of the daemon.
        Err(_) => return Err(GuileConfigError::TimedOut { path, timeout }),
    };

    if !output.status.success() {
        let mut stderr = String::from_utf8_lossy(&output.stderr).to_string();
        stderr.truncate(STDERR_EXCERPT_BYTES);
        return Err(GuileConfigError::Failed {
            path,
            status: output.status.code(),
            stderr,
        });
    }

    let toml_str = String::from_utf8_lossy(&output.stdout);
    merge_toml(base, &toml_str, &path)
}

/// Applies a TOML document emitted by a config script to `base`.
///
/// Split out from the subprocess so the merge — including the `trust` table,
/// which decides whose signatures this node accepts — is testable without
/// running `guile`.
pub fn merge_toml(
    base: GipsdConfig,
    toml_str: &str,
    path: &Path,
) -> Result<GipsdConfig, GuileConfigError> {
    let value: toml::Value =
        toml::from_str(toml_str).map_err(|source| GuileConfigError::Malformed {
            path: path.to_path_buf(),
            source,
        })?;

    let mut merged = base;

    if let Some(listen) = value.get("listen").and_then(|v| v.as_str()) {
        merged.listen = listen.to_string();
    }

    if let Some(db_path) = value.get("db_path").and_then(|v| v.as_str()) {
        merged.db_path = gips_config::expand_path(db_path);
    }

    if let Some(ipfs_api) = value.get("ipfs_api").and_then(|v| v.as_str()) {
        merged.ipfs_api = ipfs_api.to_string();
    }

    if let Some(gns_command) = value.get("gns_command").and_then(|v| v.as_str()) {
        merged.gns_command = gns_command.to_string();
    }

    if let Some(guile_cfg) = value.get("guile_config").and_then(|v| v.as_str()) {
        merged.guile_config = Some(gips_config::expand_path(guile_cfg));
    }

    if let Some(snapshot_cid) = value.get("snapshot_cid").and_then(|v| v.as_str()) {
        merged.snapshot_cid = Some(snapshot_cid.to_string());
    }

    // `trust` replaces wholesale rather than merging field by field: the
    // Scheme record is a complete declaration of who this node trusts, so a
    // publisher the operator removed there must not survive in the merged
    // config. An *absent* `[trust]` table still leaves `base.trust` alone —
    // that is "this script says nothing about trust", not "trust nobody".
    if let Some(trust) = value.get("trust") {
        merged.trust =
            trust
                .clone()
                .try_into()
                .map_err(|source| GuileConfigError::MalformedTrust {
                    path: path.to_path_buf(),
                    source,
                })?;
    }

    // `guix_signing` is an `Option`, and an absent table means "this script
    // says nothing about signing" — it leaves whatever the file config or the
    // defaults decided. A *declared* table replaces it wholesale, exactly like
    // `trust`, so a Scheme-configured node can finally turn signing on. Before
    // this, the block was parsed out of the TOML and then dropped on the floor:
    // `merge_toml` copies named keys onto `base` rather than deserializing the
    // whole document, so a table nobody names never reaches `GipsdConfig`.
    if let Some(guix_signing) = value.get("guix_signing") {
        merged.guix_signing = Some(guix_signing.clone().try_into().map_err(|source| {
            GuileConfigError::MalformedGuixSigning {
                path: path.to_path_buf(),
                source,
            }
        })?);
    }

    Ok(merged)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn base() -> GipsdConfig {
        GipsdConfig::rooted_at(Path::new("/tmp/gips-scheme-config-test"))
    }

    /// Writes an executable-by-guile script into `dir` and returns a config
    /// pointing at it.
    fn config_with_script(dir: &tempfile::TempDir, body: &str) -> GipsdConfig {
        let script = dir.path().join("config.scm");
        std::fs::write(&script, body).unwrap();
        let mut config = base();
        config.guile_config = Some(script);
        config
    }

    fn repo_root() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(|components| components.parent())
            .expect("components/gips-scheme-config has a grandparent")
            .to_path_buf()
    }

    fn guile_is_installed() -> bool {
        match std::process::Command::new("guile")
            .arg("--version")
            .output()
        {
            Ok(output) => output.status.success(),
            Err(_) => {
                eprintln!("skipping: guile is not installed");
                false
            }
        }
    }

    /// Enumerated test 3: a `guile_config` that exits non-zero refuses to
    /// start. It does not quietly hand back the defaults it was called with.
    #[tokio::test]
    async fn a_failing_guile_config_refuses_to_start() {
        if !guile_is_installed() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let config = config_with_script(
            &dir,
            "(display \"listen = \\\"127.0.0.1:9999\\\"\\n\")\n(exit 3)\n",
        );

        let err = merge_guile_config(config)
            .await
            .expect_err("a failing config script must be fatal");

        match &err {
            GuileConfigError::Failed { status, .. } => assert_eq!(*status, Some(3)),
            other => panic!("expected a Failed error, got {:?}", other),
        }
        let message = err.to_string();
        assert!(message.contains("refusing to start"), "{}", message);
    }

    #[tokio::test]
    async fn a_config_script_that_prints_garbage_refuses_to_start() {
        if !guile_is_installed() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let config = config_with_script(&dir, "(display \"this is not toml = = =\\n\")\n");

        assert!(matches!(
            merge_guile_config(config).await,
            Err(GuileConfigError::Malformed { .. })
        ));
    }

    #[tokio::test]
    async fn a_missing_config_script_refuses_to_start() {
        if !guile_is_installed() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let mut config = base();
        config.guile_config = Some(dir.path().join("does-not-exist.scm"));

        // `guile -s missing` exits non-zero; either way this is fatal, never
        // `Ok(base)`.
        assert!(merge_guile_config(config).await.is_err());
    }

    /// A config script that never finishes is fatal too — a wedged script must
    /// not hold startup open, nor be answered with the defaults.
    #[tokio::test]
    async fn a_hanging_guile_config_times_out_and_refuses_to_start() {
        if !guile_is_installed() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let config = config_with_script(&dir, "(sleep 30)\n(display \"listen = \\\"x\\\"\\n\")\n");

        let err = merge_guile_config_within(config, Duration::from_millis(200))
            .await
            .expect_err("a hanging config script must be fatal");
        assert!(matches!(err, GuileConfigError::TimedOut { .. }), "{}", err);
    }

    #[tokio::test]
    async fn no_guile_config_is_not_an_error() {
        let config = base();
        let merged = merge_guile_config(config.clone()).await.unwrap();
        assert_eq!(merged.listen, config.listen);
    }

    /// Enumerated test 4: a config emitted by the real `scheme/gips/config.scm`
    /// carries `trust.trusted_publishers` all the way into `GipsdConfig.trust`.
    ///
    /// This drives real `guile` over the real module, because the bug was that
    /// the emitter and the merge each knew about five keys and neither knew
    /// about `trust`.
    #[tokio::test]
    async fn scheme_emitted_trust_round_trips_into_the_rust_config() {
        if !guile_is_installed() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let scheme_dir = repo_root().join("scheme");
        let script = format!(
            r#"(add-to-load-path "{}")
(use-modules (gips config))
(display
 (gipsd-configuration->toml
  (gipsd-configuration
   #:listen "127.0.0.1:8081"
   #:trusted-publishers (list (trusted-publisher #:gns-name "alice.gnu"
                                                 #:public-key "/keys/alice.pem")
                              (trusted-publisher #:gns-name "bob.gnu"
                                                 #:public-key "/keys/bob.pem")))))
"#,
            scheme_dir.display()
        );

        let config = config_with_script(&dir, &script);
        let merged = merge_guile_config(config)
            .await
            .expect("the scheme config must load");

        assert_eq!(merged.listen, "127.0.0.1:8081");
        assert_eq!(
            merged
                .trust
                .trusted_publishers
                .iter()
                .map(|p| (
                    p.gns_name.as_str(),
                    p.public_key.to_string_lossy().to_string()
                ))
                .collect::<Vec<_>>(),
            vec![
                ("alice.gnu", "/keys/alice.pem".to_string()),
                ("bob.gnu", "/keys/bob.pem".to_string()),
            ],
            "trust must survive the Scheme round trip"
        );
        assert!(!merged.trust.allow_unsigned);
    }

    /// `allow_unsigned` is expressible from Scheme too — and, being a security
    /// downgrade, it has to be *said*, not inherited.
    #[tokio::test]
    async fn scheme_can_express_allow_unsigned() {
        if !guile_is_installed() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let scheme_dir = repo_root().join("scheme");
        let script = format!(
            r#"(add-to-load-path "{}")
(use-modules (gips config))
(display (gipsd-configuration->toml (gipsd-configuration #:allow-unsigned? #t)))
"#,
            scheme_dir.display()
        );

        let merged = merge_guile_config(config_with_script(&dir, &script))
            .await
            .unwrap();
        assert!(merged.trust.allow_unsigned);
        assert!(merged.trust.trusted_publishers.is_empty());
    }

    /// A script that says nothing about trust leaves the existing trust
    /// settings alone; one that declares `[trust]` replaces them wholesale.
    #[test]
    fn an_absent_trust_table_is_not_an_empty_trust_list() {
        let mut config = base();
        config.trust.trusted_publishers = vec![gips_trust::TrustedPublisher {
            gns_name: "existing.gnu".to_string(),
            public_key: PathBuf::from("/keys/existing.pem"),
        }];

        let untouched = merge_toml(
            config.clone(),
            "listen = \"127.0.0.1:1\"\n",
            Path::new("/config.scm"),
        )
        .unwrap();
        assert_eq!(untouched.trust.trusted_publishers.len(), 1);

        let replaced = merge_toml(
            config,
            "[trust]\nallow_unsigned = false\n",
            Path::new("/config.scm"),
        )
        .unwrap();
        assert!(
            replaced.trust.trusted_publishers.is_empty(),
            "a declared [trust] table is the whole truth about trust"
        );
    }

    /// Enumerated test 3: a `.scm` config that declares `guix-signing` produces
    /// a `GipsdConfig` whose `guix_signing.secret_key` is the path it named.
    ///
    /// Driven through real `guile` over the real `(gips config)` module — same
    /// shape as the trust round trip above — because the two halves of this
    /// path (the emitter and `merge_toml`) each used to know nothing about
    /// `[guix_signing]`, and a unit test of either half alone would have
    /// reported success while the feature stayed unconfigurable.
    #[tokio::test]
    async fn scheme_emitted_guix_signing_round_trips_into_the_rust_config() {
        if !guile_is_installed() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let scheme_dir = repo_root().join("scheme");
        let script = format!(
            r#"(add-to-load-path "{}")
(use-modules (gips config))
(display
 (gipsd-configuration->toml
  (gipsd-configuration
   #:listen "127.0.0.1:8082"
   #:trusted-publishers (list (trusted-publisher #:gns-name "alice.gnu"
                                                 #:public-key "/keys/alice.pem"))
   #:guix-signing (guix-signing #:secret-key "/etc/gips/signing-key.sec"
                                #:host "builder.example"
                                #:guile "/usr/local/bin/guile"))))
"#,
            scheme_dir.display()
        );

        let merged = merge_guile_config(config_with_script(&dir, &script))
            .await
            .expect("the scheme config must load");

        let signing = merged
            .guix_signing
            .expect("a declared #:guix-signing must reach GipsdConfig");
        assert_eq!(
            signing.secret_key,
            PathBuf::from("/etc/gips/signing-key.sec")
        );
        assert_eq!(signing.host.as_deref(), Some("builder.example"));
        assert_eq!(
            signing.guile,
            Some(PathBuf::from("/usr/local/bin/guile")),
            "the interpreter override must survive too"
        );
        // The `[guix_signing]` header must not have swallowed the trust table
        // that precedes it, nor the scalars above both.
        assert_eq!(merged.listen, "127.0.0.1:8082");
        assert_eq!(merged.trust.trusted_publishers.len(), 1);
    }

    /// The optional halves are optional: only `#:secret-key` is required, and
    /// omitting `#:host` must leave `None` (the daemon then discovers the host
    /// name the way `guix publish` does) rather than an empty string.
    #[tokio::test]
    async fn scheme_guix_signing_omits_the_optional_fields() {
        if !guile_is_installed() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let scheme_dir = repo_root().join("scheme");
        let script = format!(
            r#"(add-to-load-path "{}")
(use-modules (gips config))
(display
 (gipsd-configuration->toml
  (gipsd-configuration
   #:guix-signing (guix-signing #:secret-key "/keys/signing-key.sec"))))
"#,
            scheme_dir.display()
        );

        let signing = merge_guile_config(config_with_script(&dir, &script))
            .await
            .unwrap()
            .guix_signing
            .expect("secret-key alone is a complete signing declaration");
        assert_eq!(signing.secret_key, PathBuf::from("/keys/signing-key.sec"));
        assert!(signing.host.is_none(), "an unset host must stay None");
        assert!(signing.guile.is_none(), "an unset guile must stay None");
    }

    /// Enumerated test 4: a `.scm` config that says nothing about signing
    /// leaves `guix_signing = None`. Absence still means off through the
    /// Scheme path — the emitter must not volunteer an empty block, and the
    /// merge must not invent one.
    #[tokio::test]
    async fn a_scheme_config_without_guix_signing_leaves_it_off() {
        if !guile_is_installed() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let scheme_dir = repo_root().join("scheme");
        let script = format!(
            r#"(add-to-load-path "{}")
(use-modules (gips config))
(display (gipsd-configuration->toml (gipsd-configuration #:listen "127.0.0.1:8083")))
"#,
            scheme_dir.display()
        );

        let merged = merge_guile_config(config_with_script(&dir, &script))
            .await
            .unwrap();
        assert_eq!(merged.listen, "127.0.0.1:8083");
        assert!(
            merged.guix_signing.is_none(),
            "an undeclared [guix_signing] must not turn signing on"
        );
    }

    /// An absent table does not clear a signing config the file config already
    /// set, and a declared one replaces it — the same rule `trust` follows.
    #[test]
    fn an_absent_guix_signing_table_does_not_clear_an_existing_one() {
        let mut config = base();
        config.guix_signing = Some(gips_trust::guix::GuixSigningConfig {
            secret_key: PathBuf::from("/keys/from-the-file.sec"),
            host: None,
            guile: None,
        });

        let untouched = merge_toml(
            config.clone(),
            "listen = \"127.0.0.1:1\"\n",
            Path::new("/config.scm"),
        )
        .unwrap();
        assert_eq!(
            untouched.guix_signing.map(|s| s.secret_key),
            Some(PathBuf::from("/keys/from-the-file.sec"))
        );

        let replaced = merge_toml(
            config,
            "[guix_signing]\nsecret_key = \"/keys/from-the-script.sec\"\n",
            Path::new("/config.scm"),
        )
        .unwrap();
        assert_eq!(
            replaced.guix_signing.map(|s| s.secret_key),
            Some(PathBuf::from("/keys/from-the-script.sec"))
        );
    }

    /// A `[guix_signing]` block with no `secret_key` is a refusal to start, not
    /// a silent downgrade to serving unsigned narinfos.
    #[test]
    fn a_malformed_guix_signing_table_is_an_error_not_signing_off() {
        let err = merge_toml(
            base(),
            "[guix_signing]\nhost = \"builder.example\"\n",
            Path::new("/config.scm"),
        )
        .expect_err("a signing block with no key must not degrade to signing nothing");
        assert!(
            matches!(err, GuileConfigError::MalformedGuixSigning { .. }),
            "{:?}",
            err
        );
        assert!(err.to_string().contains("refusing to start"), "{}", err);
    }

    #[test]
    fn a_malformed_trust_table_is_an_error_not_an_empty_list() {
        let err = merge_toml(
            base(),
            "[trust]\ntrusted_publishers = \"alice\"\n",
            Path::new("/config.scm"),
        )
        .expect_err("a malformed trust table must not degrade to trusting nobody silently");
        assert!(matches!(err, GuileConfigError::MalformedTrust { .. }));
    }
}
