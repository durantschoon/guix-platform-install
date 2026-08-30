use anyhow::{Context, Result};
use gips_config::GipsdConfig;
use gips_trust::fsintegrity;
use serde::{Deserialize, Serialize};
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous};
use sqlx::{Pool, Sqlite};
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

#[derive(Clone)]
pub struct Database {
    pool: Arc<Pool<Sqlite>>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SubstituteRecord {
    pub id: i64,
    pub store_path: String,
    pub ipfs_cid: String,
    pub gns_name: Option<String>,
    pub narinfo_json: String,
    pub deriver: Option<String>,
    pub system: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MetricsHistoryRecord {
    pub id: i64,
    pub recorded_at: i64,
    pub snapshot_json: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SnapshotRecord {
    pub snapshot_cid: String,
    pub gns_name: Option<String>,
    pub store_paths: Vec<String>,
    pub created_at: i64,
}

/// A `db_path` that has been checked against the "never relative to the
/// working directory" rule.
///
/// Parse-don't-validate: [`Database::connect`] takes one of these on the way
/// to SQLite, so there is no code path from a config value to an open database
/// that skips the check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DbLocation(PathBuf);

/// Why a configured database path must not be opened.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DbLocationError {
    /// Empty, or relative — i.e. resolved against whatever directory the
    /// daemon was started in.
    NotAbsolute { given: PathBuf },
}

impl fmt::Display for DbLocationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DbLocationError::NotAbsolute { given } => write!(
                f,
                "refusing to open the database at {:?}: db_path must be an absolute path. A \
                 relative path is resolved against the daemon's working directory, so anyone who \
                 can write that directory could plant the substitute database gipsd trusts",
                given.display()
            ),
        }
    }
}

impl std::error::Error for DbLocationError {}

impl DbLocation {
    pub fn parse(path: &Path) -> Result<Self, DbLocationError> {
        if path.as_os_str().is_empty() || !path.is_absolute() {
            return Err(DbLocationError::NotAbsolute {
                given: path.to_path_buf(),
            });
        }
        Ok(Self(path.to_path_buf()))
    }

    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Database {
    /// Opens the pool with the durability/concurrency pragmas gipsd needs.
    ///
    /// Two writer paths share this pool — the HTTP handlers and the mirror
    /// worker's 60s tick — while `guix-daemon` reads it in narinfo bursts. On
    /// SQLite's stock rollback journal a reader and a writer cannot overlap, so
    /// those bursts turn into `SQLITE_BUSY` and, upstack, spurious 500s. WAL
    /// lets readers run against the last committed snapshot while a writer
    /// appends, and `busy_timeout` makes the writer that loses the single-writer
    /// race wait its turn instead of failing instantly. `synchronous = NORMAL`
    /// is the WAL-safe relaxation: a power loss may cost the last transactions
    /// but cannot corrupt the file, and this database is a rebuildable index
    /// over truth that lives in IPFS. `foreign_keys` is on ahead of the schema
    /// that will need it — no statement today declares one.
    ///
    /// sqlx already defaults `busy_timeout` to 5s and `foreign_keys` to ON, and
    /// deliberately leaves `journal_mode` alone; all four are stated here so the
    /// guarantee is ours and survives a dependency bump.
    async fn connect_at(location: &DbLocation) -> Result<Pool<Sqlite>> {
        let db_path = location.path();

        // The database records which CID each store path resolves to, so it is
        // as security-relevant as a key: 0700 directory, 0600 file. SQLite
        // copies the database file's mode onto its journal and WAL, so staking
        // the file out first covers those too — and under WAL the `-wal` and
        // `-shm` sidecars are always there, so that is now load-bearing rather
        // than precautionary (see `wal_sidecar_files_are_owner_only`).
        if let Some(parent) = db_path.parent() {
            fsintegrity::ensure_private_dir(parent)
                .with_context(|| format!("create database directory {}", parent.display()))?;
        }
        fsintegrity::create_private_file_if_missing(db_path)
            .with_context(|| format!("create database file {}", db_path.display()))?;

        for warning in gips_config::audit_warnings(db_path, fsintegrity::Expectation::OwnerOnly) {
            eprintln!("gipsd: WARNING: database {}", warning);
        }

        let opts = SqliteConnectOptions::new()
            .filename(db_path)
            .create_if_missing(true)
            .journal_mode(SqliteJournalMode::Wal)
            .synchronous(SqliteSynchronous::Normal)
            .busy_timeout(Duration::from_secs(5))
            .foreign_keys(true);
        SqlitePoolOptions::new()
            .max_connections(5)
            .connect_with(opts)
            .await
            .with_context(|| {
                format!(
                    "open database at {} (ensure the directory exists and is writable)",
                    db_path.display()
                )
            })
    }

    /// Opens the configured database, or fails.
    ///
    /// There is deliberately no fallback. The previous behaviour — retry
    /// against `<cwd>/gips/gipsd.sqlite` — meant that an unwritable configured
    /// path silently promoted whatever database happened to sit in the
    /// daemon's working directory into the substitute store's source of truth.
    pub async fn connect(config: &GipsdConfig) -> Result<Self> {
        let location = DbLocation::parse(&config.db_path)?;
        let pool = Self::connect_at(&location).await?;

        sqlx::query(
            r#"
            CREATE TABLE IF NOT EXISTS substitutes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                store_path TEXT NOT NULL,
                ipfs_cid TEXT NOT NULL,
                gns_name TEXT,
                narinfo_json TEXT NOT NULL
            );
            "#,
        )
        .execute(&pool)
        .await?;

        sqlx::query(
            r#"
            CREATE TABLE IF NOT EXISTS subscriptions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                gns_name TEXT NOT NULL UNIQUE
            );
            "#,
        )
        .execute(&pool)
        .await?;

        sqlx::query(
            r#"
            CREATE TABLE IF NOT EXISTS channels (
                channel_name TEXT PRIMARY KEY,
                gns_name TEXT NOT NULL
            );
            "#,
        )
        .execute(&pool)
        .await?;

        sqlx::query(
            r#"
            CREATE TABLE IF NOT EXISTS publisher_state (
                gns_name TEXT PRIMARY KEY,
                last_timestamp INTEGER NOT NULL,
                last_feed_cid TEXT
            );
            "#,
        )
        .execute(&pool)
        .await?;

        sqlx::query(
            r#"
            CREATE VIRTUAL TABLE IF NOT EXISTS substitutes_fts USING fts5(
                store_path, gns_name, content='substitutes', content_rowid='id'
            );
            "#,
        )
        .execute(&pool)
        .await?;

        sqlx::query(
            r#"
            CREATE TRIGGER IF NOT EXISTS substitutes_ai AFTER INSERT ON substitutes BEGIN
                INSERT INTO substitutes_fts(rowid, store_path, gns_name)
                VALUES (new.id, new.store_path, new.gns_name);
            END;
            "#,
        )
        .execute(&pool)
        .await?;

        sqlx::query(
            r#"
            CREATE TRIGGER IF NOT EXISTS substitutes_ad AFTER DELETE ON substitutes BEGIN
                INSERT INTO substitutes_fts(substitutes_fts, rowid, store_path, gns_name)
                VALUES('delete', old.id, old.store_path, old.gns_name);
            END;
            "#,
        )
        .execute(&pool)
        .await?;

        sqlx::query(
            r#"
            CREATE TRIGGER IF NOT EXISTS substitutes_au AFTER UPDATE ON substitutes BEGIN
                INSERT INTO substitutes_fts(substitutes_fts, rowid, store_path, gns_name)
                VALUES('delete', old.id, old.store_path, old.gns_name);
                INSERT INTO substitutes_fts(rowid, store_path, gns_name)
                VALUES (new.id, new.store_path, new.gns_name);
            END;
            "#,
        )
        .execute(&pool)
        .await?;

        sqlx::query(
            r#"
            CREATE TABLE IF NOT EXISTS metrics_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                recorded_at INTEGER NOT NULL,
                snapshot_json TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_metrics_history_recorded_at ON metrics_history(recorded_at);
            "#,
        )
        .execute(&pool)
        .await?;

        sqlx::query(
            r#"
            CREATE TABLE IF NOT EXISTS fraud_proofs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                publisher_key TEXT NOT NULL,
                proof_type TEXT NOT NULL,
                proof_json TEXT NOT NULL,
                verified_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_fraud_proofs_pubkey ON fraud_proofs(publisher_key);
            "#,
        )
        .execute(&pool)
        .await?;

        sqlx::query(
            r#"
            CREATE TABLE IF NOT EXISTS vouch_chains (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                subject_key TEXT NOT NULL,
                root_key TEXT NOT NULL,
                chain_json TEXT NOT NULL,
                expires_at INTEGER NOT NULL,
                stake_score INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_vouch_chains_subject ON vouch_chains(subject_key);
            "#,
        )
        .execute(&pool)
        .await?;

        sqlx::query(
            r#"
            CREATE TABLE IF NOT EXISTS snapshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                snapshot_cid TEXT NOT NULL UNIQUE,
                gns_name TEXT,
                store_paths_json TEXT NOT NULL,
                created_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_snapshots_cid ON snapshots(snapshot_cid);
            "#,
        )
        .execute(&pool)
        .await?;

        Self::migrate(&pool).await?;

        Ok(Self {
            pool: Arc::new(pool),
        })
    }

    /// Records a verified cryptographic fraud proof and revokes the publisher.
    pub async fn record_fraud_proof(&self, proof: &gips_trust::FraudProof) -> Result<()> {
        let proof_type = match proof.proof_type {
            gips_trust::FraudProofType::HashMismatch { .. } => "hash_mismatch",
            gips_trust::FraudProofType::Equivocation { .. } => "equivocation",
        };
        let proof_json = proof.to_json();
        let verified_at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;

        sqlx::query(
            "INSERT INTO fraud_proofs (publisher_key, proof_type, proof_json, verified_at) VALUES (?1, ?2, ?3, ?4)",
        )
        .bind(&proof.publisher_key)
        .bind(proof_type)
        .bind(&proof_json)
        .bind(verified_at)
        .execute(self.pool())
        .await?;

        Ok(())
    }

    /// Checks whether a publisher key has been revoked via recorded objective fraud proofs.
    pub async fn is_publisher_revoked(&self, publisher_key: &str) -> Result<bool> {
        let trimmed = publisher_key.trim();
        let direct_match: Option<i64> =
            sqlx::query_scalar("SELECT 1 FROM fraud_proofs WHERE publisher_key = ?1 LIMIT 1")
                .bind(trimmed)
                .fetch_optional(self.pool())
                .await?;

        if direct_match.is_some() {
            return Ok(true);
        }

        let revoked_keys: Vec<String> =
            sqlx::query_scalar("SELECT publisher_key FROM fraud_proofs")
                .fetch_all(self.pool())
                .await?;

        for revoked in revoked_keys {
            if gips_trust::vouch::keys_equal(&revoked, trimmed) {
                return Ok(true);
            }
        }

        Ok(false)
    }

    /// Fetches all recorded fraud proofs in descending order of verification time.
    pub async fn list_fraud_proofs(&self) -> Result<Vec<gips_trust::FraudProof>> {
        let rows: Vec<String> = sqlx::query_scalar(
            "SELECT proof_json FROM fraud_proofs ORDER BY verified_at DESC, id DESC",
        )
        .fetch_all(self.pool())
        .await?;

        let mut proofs = Vec::with_capacity(rows.len());
        for json_str in rows {
            if let Ok(proof) = gips_trust::FraudProof::from_json(&json_str) {
                proofs.push(proof);
            }
        }

        Ok(proofs)
    }

    /// Records a metrics snapshot with the given timestamp and prunes snapshots older than 7 days.
    pub async fn record_metrics_history(
        &self,
        recorded_at: i64,
        snapshot_json: &str,
    ) -> Result<()> {
        sqlx::query("INSERT INTO metrics_history (recorded_at, snapshot_json) VALUES (?1, ?2)")
            .bind(recorded_at)
            .bind(snapshot_json)
            .execute(self.pool())
            .await?;

        // Prune entries older than 7 days (7 * 86400 seconds)
        let prune_before = recorded_at.saturating_sub(7 * 86400);
        sqlx::query("DELETE FROM metrics_history WHERE recorded_at < ?1")
            .bind(prune_before)
            .execute(self.pool())
            .await?;

        Ok(())
    }

    /// Fetches the most recent metrics history entries in descending order of recording time.
    pub async fn get_metrics_history(&self, limit: i64) -> Result<Vec<MetricsHistoryRecord>> {
        let rows = sqlx::query_as::<_, (i64, i64, String)>(
            "SELECT id, recorded_at, snapshot_json FROM metrics_history ORDER BY recorded_at DESC LIMIT ?1",
        )
        .bind(limit.max(1))
        .fetch_all(self.pool())
        .await?;

        Ok(rows
            .into_iter()
            .map(|(id, recorded_at, snapshot_json)| MetricsHistoryRecord {
                id,
                recorded_at,
                snapshot_json,
            })
            .collect())
    }

    /// Records a verified capability delegation vouch chain in the database.
    pub async fn record_vouch_chain(
        &self,
        root_key: &str,
        subject_key: &str,
        chain: &[gips_trust::VouchToken],
    ) -> Result<()> {
        if chain.is_empty() {
            anyhow::bail!("Cannot record an empty vouch chain");
        }

        let expires_at = chain
            .iter()
            .map(|t| t.payload.expires_at)
            .min()
            .unwrap_or(0) as i64;
        let stake_score = chain.last().unwrap().payload.capabilities.stake_score as i64;
        let chain_json = gips_trust::vouch_chain_to_json(chain);

        sqlx::query(
            r#"
            INSERT INTO vouch_chains (subject_key, root_key, chain_json, expires_at, stake_score)
            VALUES (?1, ?2, ?3, ?4, ?5)
            "#,
        )
        .bind(subject_key.trim())
        .bind(root_key.trim())
        .bind(&chain_json)
        .bind(expires_at)
        .bind(stake_score)
        .execute(self.pool())
        .await?;

        Ok(())
    }

    /// Fetches all recorded vouch chains for a given subject public key.
    pub async fn get_vouch_chains_for_subject(
        &self,
        subject_key: &str,
    ) -> Result<Vec<Vec<gips_trust::VouchToken>>> {
        let trimmed = subject_key.trim();
        let rows: Vec<String> = sqlx::query_scalar(
            "SELECT chain_json FROM vouch_chains WHERE subject_key = ?1 ORDER BY stake_score DESC, id DESC",
        )
        .bind(trimmed)
        .fetch_all(self.pool())
        .await?;

        let mut chains = Vec::new();
        for json_str in rows {
            if let Ok(chain) = gips_trust::vouch_chain_from_json(&json_str) {
                chains.push(chain);
            }
        }

        if chains.is_empty() {
            let all_rows: Vec<(String, String)> = sqlx::query_as(
                "SELECT subject_key, chain_json FROM vouch_chains ORDER BY stake_score DESC, id DESC",
            )
            .fetch_all(self.pool())
            .await?;

            for (subj, json_str) in all_rows {
                if gips_trust::vouch::keys_equal(&subj, trimmed) {
                    if let Ok(chain) = gips_trust::vouch_chain_from_json(&json_str) {
                        chains.push(chain);
                    }
                }
            }
        }

        Ok(chains)
    }

    /// Prunes expired vouch chains whose expiration timestamp is strictly less than `now`.
    pub async fn prune_expired_vouches(&self, now: u64) -> Result<usize> {
        let res = sqlx::query("DELETE FROM vouch_chains WHERE expires_at < ?1")
            .bind(now as i64)
            .execute(self.pool())
            .await?;

        Ok(res.rows_affected() as usize)
    }

    /// Records an offline capability snapshot in the database.
    pub async fn record_snapshot(&self, snapshot: &SnapshotRecord) -> Result<()> {
        let store_paths_json = store_paths_to_json(&snapshot.store_paths);

        sqlx::query(
            r#"
            INSERT INTO snapshots (snapshot_cid, gns_name, store_paths_json, created_at)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(snapshot_cid) DO UPDATE SET
                gns_name = COALESCE(excluded.gns_name, snapshots.gns_name),
                store_paths_json = excluded.store_paths_json,
                created_at = excluded.created_at
            "#,
        )
        .bind(&snapshot.snapshot_cid)
        .bind(&snapshot.gns_name)
        .bind(&store_paths_json)
        .bind(snapshot.created_at)
        .execute(self.pool())
        .await
        .context("inserting snapshot record into database")?;

        Ok(())
    }

    /// Lists all recorded snapshots in descending order of creation time.
    pub async fn list_snapshots(&self) -> Result<Vec<SnapshotRecord>> {
        let rows = sqlx::query_as::<_, (String, Option<String>, String, i64)>(
            "SELECT snapshot_cid, gns_name, store_paths_json, created_at FROM snapshots ORDER BY created_at DESC, id DESC",
        )
        .fetch_all(self.pool())
        .await
        .context("fetching snapshots from database")?;

        let mut snapshots = Vec::with_capacity(rows.len());
        for (snapshot_cid, gns_name, store_paths_json, created_at) in rows {
            let store_paths = store_paths_from_json(&store_paths_json);
            snapshots.push(SnapshotRecord {
                snapshot_cid,
                gns_name,
                store_paths,
                created_at,
            });
        }

        Ok(snapshots)
    }

    /// Fetches a snapshot record by its IPFS CID.
    pub async fn get_snapshot(&self, cid: &str) -> Result<Option<SnapshotRecord>> {
        let row = sqlx::query_as::<_, (String, Option<String>, String, i64)>(
            "SELECT snapshot_cid, gns_name, store_paths_json, created_at FROM snapshots WHERE snapshot_cid = ?1",
        )
        .bind(cid)
        .fetch_optional(self.pool())
        .await
        .context("fetching snapshot by CID from database")?;

        Ok(
            row.map(|(snapshot_cid, gns_name, store_paths_json, created_at)| {
                let store_paths = store_paths_from_json(&store_paths_json);
                SnapshotRecord {
                    snapshot_cid,
                    gns_name,
                    store_paths,
                    created_at,
                }
            }),
        )
    }

    /// Finds substitutes matching a store path hash prefix (e.g. "4zi91dws").
    pub async fn find_by_hash_prefix(
        &self,
        prefix: &str,
        limit: i64,
    ) -> Result<Vec<SubstituteRecord>> {
        let pattern = if prefix.starts_with("/gnu/store/") {
            format!("{}%", prefix)
        } else {
            format!("/gnu/store/{}%", prefix)
        };

        let rows = sqlx::query_as::<
            _,
            (
                i64,
                String,
                String,
                Option<String>,
                String,
                Option<String>,
                Option<String>,
            ),
        >(
            "SELECT id, store_path, ipfs_cid, gns_name, narinfo_json, deriver, system \
             FROM substitutes WHERE store_path LIKE ?1 ORDER BY id DESC LIMIT ?2",
        )
        .bind(pattern)
        .bind(limit)
        .fetch_all(self.pool())
        .await
        .context("querying substitutes by hash prefix")?;

        Ok(rows
            .into_iter()
            .map(
                |(id, store_path, ipfs_cid, gns_name, narinfo_json, deriver, system)| {
                    SubstituteRecord {
                        id,
                        store_path,
                        ipfs_cid,
                        gns_name,
                        narinfo_json,
                        deriver,
                        system,
                    }
                },
            )
            .collect())
    }

    /// Builds a Bloom filter summarizing all indexed store paths.
    pub async fn build_store_bloom_filter(
        &self,
        false_positive_rate: f64,
    ) -> Result<gips_trust::BloomFilter> {
        let paths: Vec<String> = sqlx::query_scalar("SELECT store_path FROM substitutes")
            .fetch_all(self.pool())
            .await
            .context("fetching store paths for bloom filter")?;

        let mut filter = gips_trust::BloomFilter::new(paths.len(), false_positive_rate);
        for p in paths {
            let hash_part = p.strip_prefix("/gnu/store/").unwrap_or(&p);
            filter.insert(hash_part.as_bytes());
        }
        Ok(filter)
    }
}

fn store_paths_to_json(paths: &[String]) -> String {
    let mut s = String::from("[");
    for (i, p) in paths.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push('"');
        for c in p.chars() {
            match c {
                '"' => s.push_str("\\\""),
                '\\' => s.push_str("\\\\"),
                '\n' => s.push_str("\\n"),
                '\r' => s.push_str("\\r"),
                '\t' => s.push_str("\\t"),
                c => s.push(c),
            }
        }
        s.push('"');
    }
    s.push(']');
    s
}

fn store_paths_from_json(json: &str) -> Vec<String> {
    let json = json.trim();
    if !json.starts_with('[') || !json.ends_with(']') {
        return Vec::new();
    }
    let inner = &json[1..json.len() - 1];
    let mut result = Vec::new();
    let mut in_quotes = false;
    let mut escape = false;
    let mut current = String::new();
    for c in inner.chars() {
        if escape {
            match c {
                'n' => current.push('\n'),
                'r' => current.push('\r'),
                't' => current.push('\t'),
                '\\' => current.push('\\'),
                '"' => current.push('"'),
                _ => {
                    current.push('\\');
                    current.push(c);
                }
            }
            escape = false;
        } else if c == '\\' && in_quotes {
            escape = true;
        } else if c == '"' {
            if in_quotes {
                result.push(current.clone());
                current.clear();
                in_quotes = false;
            } else {
                in_quotes = true;
            }
        } else if in_quotes {
            current.push(c);
        }
    }
    result
}

impl Database {
    /// Applies additive schema migrations.
    ///
    /// Every migration here must be safe to run against a database created by
    /// an older GIPS: columns are added, never redefined, and rows written
    /// before a column existed keep `NULL` there. A `NULL` integrity column
    /// means "this row predates content verification" — callers must treat it
    /// as unknown and refuse to serve, never as a zero.
    async fn migrate(pool: &Pool<Sqlite>) -> Result<()> {
        // Stage 16: real content integrity. `nar_hash` is the Guix
        // `sha256:<nix-base32>` of the published nar, `nar_size` its exact
        // byte length, `nar_references` the scanned `References:` value (or
        // the literal `unknown`).
        Self::add_column_if_missing(pool, "substitutes", "nar_hash", "TEXT").await?;
        Self::add_column_if_missing(pool, "substitutes", "nar_size", "INTEGER").await?;
        Self::add_column_if_missing(pool, "substitutes", "nar_references", "TEXT").await?;
        // Stage 34: Deriver and System metadata for ecosystem tooling parity.
        Self::add_column_if_missing(pool, "substitutes", "deriver", "TEXT").await?;
        Self::add_column_if_missing(pool, "substitutes", "system", "TEXT").await?;
        Ok(())
    }

    /// Adds a column unless it already exists.
    ///
    /// SQLite has no `ADD COLUMN IF NOT EXISTS`, so existence is checked
    /// against `pragma_table_info`. `table`/`column`/`decl` are compile-time
    /// literals from [`Self::migrate`], never user input; the pragma query
    /// itself is parameterized.
    async fn add_column_if_missing(
        pool: &Pool<Sqlite>,
        table: &str,
        column: &str,
        decl: &str,
    ) -> Result<()> {
        let existing: Option<i64> =
            sqlx::query_scalar("SELECT 1 FROM pragma_table_info(?1) WHERE name = ?2")
                .bind(table)
                .bind(column)
                .fetch_optional(pool)
                .await
                .with_context(|| format!("inspect columns of {}", table))?;

        if existing.is_none() {
            sqlx::query(&format!(
                "ALTER TABLE {} ADD COLUMN {} {}",
                table, column, decl
            ))
            .execute(pool)
            .await
            .with_context(|| format!("add column {}.{}", table, column))?;
        }
        Ok(())
    }

    pub fn pool(&self) -> &Pool<Sqlite> {
        &self.pool
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn temp_db(dir: &tempfile::TempDir) -> Pool<Sqlite> {
        let config = GipsdConfig {
            db_path: dir.path().join("gipsd.sqlite"),
            ..Default::default()
        };
        let db = Database::connect(&config).await.unwrap();
        db.pool().clone()
    }

    #[tokio::test]
    async fn migration_adds_integrity_columns_and_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let config = GipsdConfig {
            db_path: dir.path().join("gipsd.sqlite"),
            ..Default::default()
        };

        // First connect creates the schema; second re-runs the migration.
        let _ = Database::connect(&config).await.unwrap();
        let db = Database::connect(&config).await.unwrap();

        let columns: Vec<String> =
            sqlx::query_scalar("SELECT name FROM pragma_table_info('substitutes')")
                .fetch_all(db.pool())
                .await
                .unwrap();

        for expected in [
            "nar_hash",
            "nar_size",
            "nar_references",
            "deriver",
            "system",
        ] {
            assert!(
                columns.contains(&expected.to_string()),
                "missing {}",
                expected
            );
        }
    }

    #[tokio::test]
    async fn legacy_rows_keep_null_integrity_rather_than_zeros() {
        let dir = tempfile::tempdir().unwrap();
        let pool = temp_db(&dir).await;

        // A row written the way pre-Stage-16 GIPS wrote them.
        sqlx::query(
            "INSERT INTO substitutes (store_path, ipfs_cid, gns_name, narinfo_json) VALUES (?1, ?2, NULL, ?3)",
        )
        .bind("/gnu/store/8009y4y5d4rhm796p02a7b8w6k2hvwq2-bash-5.1.16")
        .bind("QmLegacy")
        .bind("{}")
        .execute(&pool)
        .await
        .unwrap();

        let nar_hash: Option<String> =
            sqlx::query_scalar("SELECT nar_hash FROM substitutes WHERE ipfs_cid = 'QmLegacy'")
                .fetch_one(&pool)
                .await
                .unwrap();

        assert_eq!(nar_hash, None);
    }

    // -----------------------------------------------------------------------
    // Stage 20: no CWD-relative database, and no world-readable one.
    // -----------------------------------------------------------------------

    /// Enumerated test 1 (database half): a path that cannot be opened is a
    /// clean error naming that path. Nothing is created next to the working
    /// directory, and no second database is opened behind the caller's back.
    #[tokio::test]
    async fn an_unopenable_db_path_fails_instead_of_falling_back_to_the_cwd() {
        let cwd = std::env::current_dir().unwrap();
        let planted = cwd.join("gips").join("gipsd.sqlite");
        let planted_existed = planted.exists();

        // A directory only root can create: the open must fail.
        let config = GipsdConfig {
            db_path: PathBuf::from("/nonexistent-gips-stage20/gipsd.sqlite"),
            ..Default::default()
        };

        let message = match Database::connect(&config).await {
            Ok(_) => panic!("an unopenable database path must be fatal"),
            Err(e) => format!("{:#}", e),
        };
        assert!(
            message.contains("/nonexistent-gips-stage20"),
            "the error must name the configured path: {}",
            message
        );

        assert_eq!(
            planted.exists(),
            planted_existed,
            "gipsd must not create or open {} — the old CWD fallback",
            planted.display()
        );
    }

    /// A relative `db_path` is refused before SQLite is ever asked, because
    /// "relative" means "relative to whatever directory the daemon started in".
    #[tokio::test]
    async fn a_relative_db_path_is_refused_by_construction() {
        assert!(matches!(
            DbLocation::parse(Path::new("gips/gipsd.sqlite")),
            Err(DbLocationError::NotAbsolute { .. })
        ));
        assert!(matches!(
            DbLocation::parse(Path::new("")),
            Err(DbLocationError::NotAbsolute { .. })
        ));
        assert!(DbLocation::parse(Path::new("/var/lib/gips/gipsd.sqlite")).is_ok());

        let config = GipsdConfig {
            db_path: PathBuf::from("gips/gipsd.sqlite"),
            ..Default::default()
        };
        let err = match Database::connect(&config).await {
            Ok(_) => panic!("a relative db_path must be refused"),
            Err(e) => e.to_string(),
        };
        assert!(err.contains("must be an absolute path"), "{}", err);
    }

    /// Enumerated test 2: a freshly created database — and the directory it
    /// lives in — are owner-only.
    #[cfg(unix)]
    #[tokio::test]
    async fn a_new_database_is_mode_0600_in_a_0700_directory() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("gips");

        let config = GipsdConfig {
            db_path: home.join("gipsd.sqlite"),
            ..Default::default()
        };
        let _db = Database::connect(&config).await.unwrap();

        let db_mode = std::fs::metadata(&config.db_path)
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(db_mode, 0o600, "database file mode");

        let dir_mode = std::fs::metadata(&home).unwrap().permissions().mode() & 0o777;
        assert_eq!(dir_mode, 0o700, "database directory mode");
    }

    // -----------------------------------------------------------------------
    // Stage 26: WAL, synchronous=NORMAL, busy_timeout, foreign_keys.
    // -----------------------------------------------------------------------

    /// Enumerated test 1: the pragmas are readable back through the pool, so
    /// this asserts the connections callers actually get — not the builder.
    #[tokio::test]
    async fn connect_configures_the_durability_pragmas() {
        let dir = tempfile::tempdir().unwrap();
        let pool = temp_db(&dir).await;

        let journal_mode: String = sqlx::query_scalar("PRAGMA journal_mode")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(journal_mode.to_lowercase(), "wal", "journal_mode");

        let synchronous: i64 = sqlx::query_scalar("PRAGMA synchronous")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(synchronous, 1, "synchronous must be NORMAL (1)");

        let busy_timeout: i64 = sqlx::query_scalar("PRAGMA busy_timeout")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(busy_timeout, 5000, "busy_timeout in ms");

        let foreign_keys: i64 = sqlx::query_scalar("PRAGMA foreign_keys")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(foreign_keys, 1, "foreign_keys");
    }

    /// Enumerated test 2: two writers interleaving through the shared pool —
    /// the daemon's HTTP handlers against the mirror tick — finish without a
    /// `SQLITE_BUSY`. Before `busy_timeout`, whichever writer lost the race
    /// returned "database is locked" immediately instead of waiting.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn interleaved_writers_never_see_sqlite_busy() {
        const WRITERS: usize = 2;
        const INSERTS: usize = 50;

        let dir = tempfile::tempdir().unwrap();
        let pool = temp_db(&dir).await;

        let writers: Vec<_> = (0..WRITERS)
            .map(|writer| {
                let pool = pool.clone();
                tokio::spawn(async move {
                    for i in 0..INSERTS {
                        sqlx::query(
                            "INSERT INTO substitutes (store_path, ipfs_cid, gns_name, narinfo_json) \
                             VALUES (?1, ?2, NULL, '{}')",
                        )
                        .bind(format!("/gnu/store/stage26-{}-{}", writer, i))
                        .bind(format!("QmStage26{}{}", writer, i))
                        .execute(&pool)
                        .await
                        .map_err(|e| format!("writer {} insert {}: {}", writer, i, e))?;
                    }
                    Ok::<(), String>(())
                })
            })
            .collect();

        for writer in writers {
            // A locking failure arrives here as the Err payload, so the panic
            // names the offending statement rather than just "task failed".
            writer.await.unwrap().unwrap();
        }

        let written: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM substitutes")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(written, (WRITERS * INSERTS) as i64);
    }

    /// Enumerated test 3: WAL puts two more files next to the database, and
    /// they hold the same index of store-path-to-CID mappings. They must be as
    /// private as the database itself.
    #[cfg(unix)]
    #[tokio::test]
    async fn wal_sidecar_files_are_owner_only() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let config = GipsdConfig {
            db_path: dir.path().join("gips").join("gipsd.sqlite"),
            ..Default::default()
        };

        // The pool stays open for the whole test: SQLite removes the sidecars
        // when the last connection closes cleanly.
        let db = Database::connect(&config).await.unwrap();
        sqlx::query("INSERT INTO subscriptions (gns_name) VALUES ('stage26.gns')")
            .execute(db.pool())
            .await
            .unwrap();

        for suffix in ["-wal", "-shm"] {
            let mut sidecar = config.db_path.clone().into_os_string();
            sidecar.push(suffix);
            let sidecar = PathBuf::from(sidecar);

            assert!(
                sidecar.exists(),
                "{} must exist once the database is in WAL mode and written",
                sidecar.display()
            );
            let mode = std::fs::metadata(&sidecar).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600, "{} mode", sidecar.display());
        }
    }

    /// Enumerated test 4: a database left behind by an older gipsd is in
    /// rollback-journal mode. Opening it must switch it to WAL in place, with
    /// every row still there — WAL is a property of the file, not of the
    /// connection, so this happens exactly once and then sticks.
    #[tokio::test]
    async fn a_rollback_journal_database_is_upgraded_to_wal_in_place() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("gips").join("gipsd.sqlite");

        // Build it the way pre-Stage-26 gipsd did: same private staking, but
        // SQLite's default journal mode.
        fsintegrity::ensure_private_dir(db_path.parent().unwrap()).unwrap();
        fsintegrity::create_private_file_if_missing(&db_path).unwrap();
        let legacy = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(
                SqliteConnectOptions::new()
                    .filename(&db_path)
                    .create_if_missing(true)
                    .journal_mode(SqliteJournalMode::Delete),
            )
            .await
            .unwrap();
        sqlx::query(
            "CREATE TABLE substitutes (
                 id INTEGER PRIMARY KEY AUTOINCREMENT,
                 store_path TEXT NOT NULL,
                 ipfs_cid TEXT NOT NULL,
                 gns_name TEXT,
                 narinfo_json TEXT NOT NULL
             );",
        )
        .execute(&legacy)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO substitutes (store_path, ipfs_cid, gns_name, narinfo_json) \
             VALUES ('/gnu/store/stage26-legacy', 'QmLegacyJournal', NULL, '{}')",
        )
        .execute(&legacy)
        .await
        .unwrap();

        let legacy_mode: String = sqlx::query_scalar("PRAGMA journal_mode")
            .fetch_one(&legacy)
            .await
            .unwrap();
        assert_eq!(
            legacy_mode.to_lowercase(),
            "delete",
            "precondition: the old database must not already be in WAL"
        );
        legacy.close().await;

        let config = GipsdConfig {
            db_path: db_path.clone(),
            ..Default::default()
        };
        let db = Database::connect(&config).await.unwrap();

        let upgraded: String = sqlx::query_scalar("PRAGMA journal_mode")
            .fetch_one(db.pool())
            .await
            .unwrap();
        assert_eq!(upgraded.to_lowercase(), "wal", "journal_mode after upgrade");

        let cid: String = sqlx::query_scalar(
            "SELECT ipfs_cid FROM substitutes WHERE store_path = '/gnu/store/stage26-legacy'",
        )
        .fetch_one(db.pool())
        .await
        .unwrap();
        assert_eq!(
            cid, "QmLegacyJournal",
            "rows survive the journal-mode switch"
        );

        // The switch is durable: a later open finds WAL already in place.
        drop(db);
        let reopened = Database::connect(&config).await.unwrap();
        let still_wal: String = sqlx::query_scalar("PRAGMA journal_mode")
            .fetch_one(reopened.pool())
            .await
            .unwrap();
        assert_eq!(still_wal.to_lowercase(), "wal");
    }

    #[tokio::test]
    async fn metrics_history_records_and_prunes_correctly() {
        let dir = tempfile::tempdir().unwrap();
        let config = GipsdConfig {
            db_path: dir.path().join("gipsd.sqlite"),
            ..Default::default()
        };
        let db = Database::connect(&config).await.unwrap();

        let now = 1_000_000i64;
        let old = now - (8 * 86400); // 8 days ago (> 7 days)
        let recent = now - 86400; // 1 day ago

        // Insert old record
        db.record_metrics_history(old, "{\"uptime_seconds\":10.0}")
            .await
            .unwrap();
        // Insert recent record
        db.record_metrics_history(recent, "{\"uptime_seconds\":100.0}")
            .await
            .unwrap();
        // Insert now record (which triggers prune of > 7 days)
        db.record_metrics_history(now, "{\"uptime_seconds\":200.0}")
            .await
            .unwrap();

        let history = db.get_metrics_history(10).await.unwrap();
        assert_eq!(history.len(), 2, "old record must have been pruned");
        assert_eq!(history[0].recorded_at, now);
        assert_eq!(history[1].recorded_at, recent);
    }

    #[tokio::test]
    async fn fraud_proof_records_revokes_and_lists() {
        let dir = tempfile::tempdir().unwrap();
        let config = GipsdConfig {
            db_path: dir.path().join("gipsd.sqlite"),
            ..Default::default()
        };
        let db = Database::connect(&config).await.unwrap();

        let pubkey = "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEALYuuoFcBhcEsjd0AbarQDmxQ1vmLiL8E6M83zh7nFtI=\n-----END PUBLIC KEY-----\n";
        let other_key = "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAaTMDplxUZ7vkoLEg5o8hsRPbq5Yg7+INmPDGS9EF3VU=\n-----END PUBLIC KEY-----\n";

        assert!(!db.is_publisher_revoked(pubkey).await.unwrap());
        assert!(!db.is_publisher_revoked(other_key).await.unwrap());

        let proof = gips_trust::generate_hash_mismatch_proof(
            pubkey,
            "StorePath: /gnu/store/foo\nNarHash: sha256:abc\n",
            "1;alice;sig",
            b"tampered content",
        );

        db.record_fraud_proof(&proof).await.unwrap();

        assert!(db.is_publisher_revoked(pubkey).await.unwrap());
        assert!(!db.is_publisher_revoked(other_key).await.unwrap());

        let proofs = db.list_fraud_proofs().await.unwrap();
        assert_eq!(proofs.len(), 1);
        assert_eq!(proofs[0].publisher_key, pubkey.trim());
    }

    #[tokio::test]
    async fn vouch_chain_storage_and_pruning() {
        let dir = tempfile::tempdir().unwrap();
        let config = GipsdConfig {
            db_path: dir.path().join("gipsd.sqlite"),
            ..Default::default()
        };
        let db = Database::connect(&config).await.unwrap();

        let root_key = "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEALYuuoFcBhcEsjd0AbarQDmxQ1vmLiL8E6M83zh7nFtI=\n-----END PUBLIC KEY-----\n";
        let subject_key = "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAaTMDplxUZ7vkoLEg5o8hsRPbq5Yg7+INmPDGS9EF3VU=\n-----END PUBLIC KEY-----\n";

        let now = 1000u64;
        let token = gips_trust::VouchToken {
            payload: gips_trust::VouchPayload {
                issuer: root_key.to_string(),
                subject: subject_key.to_string(),
                parent_token: None,
                issued_at: now,
                expires_at: now + 500,
                capabilities: gips_trust::VouchCapabilities {
                    path_prefixes: vec!["/gnu/store/".to_string()],
                    max_depth: 1,
                    stake_score: 80,
                },
            },
            signature: "sig123".to_string(),
        };

        db.record_vouch_chain(root_key, subject_key, std::slice::from_ref(&token))
            .await
            .unwrap();

        let chains = db.get_vouch_chains_for_subject(subject_key).await.unwrap();
        assert_eq!(chains.len(), 1);
        assert_eq!(chains[0].len(), 1);
        assert_eq!(chains[0][0].payload.subject, subject_key);

        // Expire token and prune
        let pruned = db.prune_expired_vouches(now + 600).await.unwrap();
        assert_eq!(pruned, 1);

        let chains_after = db.get_vouch_chains_for_subject(subject_key).await.unwrap();
        assert_eq!(chains_after.len(), 0);
    }

    #[tokio::test]
    async fn snapshot_record_and_list_lifecycle() {
        let dir = tempfile::tempdir().unwrap();
        let config = GipsdConfig {
            db_path: dir.path().join("gipsd.sqlite"),
            ..Default::default()
        };
        let db = Database::connect(&config).await.unwrap();

        assert_eq!(db.list_snapshots().await.unwrap().len(), 0);
        assert_eq!(db.get_snapshot("QmSnap1").await.unwrap(), None);

        let snap1 = SnapshotRecord {
            snapshot_cid: "QmSnap1".to_string(),
            gns_name: Some("test.gnu".to_string()),
            store_paths: vec!["/gnu/store/1".to_string(), "/gnu/store/2".to_string()],
            created_at: 100,
        };
        let snap2 = SnapshotRecord {
            snapshot_cid: "QmSnap2".to_string(),
            gns_name: None,
            store_paths: vec!["/gnu/store/3".to_string()],
            created_at: 200,
        };

        db.record_snapshot(&snap1).await.unwrap();
        db.record_snapshot(&snap2).await.unwrap();

        let listed = db.list_snapshots().await.unwrap();
        assert_eq!(listed.len(), 2);
        // Reverse chronological order
        assert_eq!(listed[0].snapshot_cid, "QmSnap2");
        assert_eq!(listed[0].created_at, 200);
        assert_eq!(listed[1].snapshot_cid, "QmSnap1");
        assert_eq!(listed[1].created_at, 100);

        let retrieved = db.get_snapshot("QmSnap1").await.unwrap();
        assert_eq!(retrieved, Some(snap1));
    }
}
