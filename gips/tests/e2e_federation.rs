use axum::body::Body;
use axum::extract::{DefaultBodyLimit, Query, State};
use axum::http::{header, StatusCode};
use axum::response::Response;
use axum::routing::post;
use axum::Router;
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use gips_config::{AuthToken, GipsdConfig};
use gips_db::Database;
use gips_http::{
    build_router, CreateSnapshotRequest, CreateSnapshotResponse, ImportSnapshotRequest,
    ManifestEntry, StoredNarinfo, TrustEvaluateRequest, TrustEvaluateResponse, VouchIngestRequest,
    VouchIngestResponse, TOPIC_FRAUD,
};
use gips_nar::{NarIntegrity, GUIX_STORE_DIR};
use gips_trust::fraud::{FraudProof, FraudProofType};
use gips_trust::guix::GeneratedKeyPair;
use gips_trust::vouch::{VouchCapabilities, VouchToken};
use gips_trust::TrustedPublisher;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;
use tokio::net::TcpListener;

/// Generates a CIDv0 string for the given raw bytes.
fn cid_for_bytes(bytes: &[u8]) -> String {
    let mut multihash = vec![0x12u8, 0x20u8];
    multihash.extend_from_slice(&Sha256::digest(bytes));
    multibase::encode(multibase::Base::Base58Btc, multihash)
}

/// Extracts payload from multipart/form-data.
fn multipart_payload(body: &[u8]) -> Option<&[u8]> {
    let header_end = body
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|i| i + 4)?;
    let rest = &body[header_end..];
    let payload_end = rest.windows(4).rposition(|w| w == b"\r\n--")?;
    Some(&rest[..payload_end])
}

// -----------------------------------------------------------------------------
// Mock IPFS Service
// -----------------------------------------------------------------------------

type PublishedMessages = Arc<Mutex<Vec<(String, Vec<u8>)>>>;
type ChannelMap = Arc<Mutex<HashMap<String, tokio::sync::broadcast::Sender<String>>>>;

#[derive(Clone, Default)]
pub struct MockIpfs {
    pub objects: Arc<RwLock<HashMap<String, Vec<u8>>>>,
    pub uploads: Arc<Mutex<Vec<Vec<u8>>>>,
    pub pins: Arc<RwLock<HashSet<String>>>,
    pub pubsub_published: PublishedMessages,
    pub pubsub_channels: ChannelMap,
}

impl MockIpfs {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn insert_object(&self, cid: String, bytes: Vec<u8>) {
        self.objects.write().unwrap().insert(cid, bytes);
    }

    pub fn get_object(&self, cid: &str) -> Option<Vec<u8>> {
        self.objects.read().unwrap().get(cid).cloned()
    }

    pub fn send_pubsub_message(&self, topic: &str, payload_bytes: &[u8]) {
        let b64 = BASE64.encode(payload_bytes);
        let line = format!("{{\"data\":\"{}\"}}\n", b64);
        let mut channels = self.pubsub_channels.lock().unwrap();
        let tx = channels
            .entry(topic.to_string())
            .or_insert_with(|| tokio::sync::broadcast::channel(128).0);
        let _ = tx.send(line);
    }

    pub async fn wait_for_subscriber(&self, topic: &str) {
        for _ in 0..200 {
            {
                let channels = self.pubsub_channels.lock().unwrap();
                if let Some(tx) = channels.get(topic) {
                    if tx.receiver_count() > 0 {
                        return;
                    }
                }
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
}

async fn fake_ipfs_cat(
    State(mock): State<MockIpfs>,
    Query(params): Query<HashMap<String, String>>,
) -> Result<Vec<u8>, StatusCode> {
    let cid = params.get("arg").ok_or(StatusCode::BAD_REQUEST)?;
    mock.objects
        .read()
        .unwrap()
        .get(cid)
        .cloned()
        .ok_or(StatusCode::NOT_FOUND)
}

async fn fake_ipfs_add(State(mock): State<MockIpfs>, body: bytes::Bytes) -> String {
    let payload = multipart_payload(&body).unwrap_or(&body);
    let cid = cid_for_bytes(payload);
    mock.objects
        .write()
        .unwrap()
        .insert(cid.clone(), payload.to_vec());
    mock.uploads.lock().unwrap().push(payload.to_vec());
    format!("{{\"Hash\":\"{}\"}}", cid)
}

async fn fake_ipfs_pin_add(
    State(mock): State<MockIpfs>,
    Query(params): Query<HashMap<String, String>>,
) -> (StatusCode, String) {
    if let Some(cid) = params.get("arg") {
        mock.pins.write().unwrap().insert(cid.clone());
        (StatusCode::OK, format!("{{\"Pins\":[\"{}\"]}}", cid))
    } else {
        (StatusCode::BAD_REQUEST, "{\"Pins\":[]}".to_string())
    }
}

async fn fake_ipfs_pubsub_pub(
    State(mock): State<MockIpfs>,
    Query(params): Query<HashMap<String, String>>,
    body: bytes::Bytes,
) -> StatusCode {
    let topic = params.get("arg").cloned().unwrap_or_default();
    let payload = multipart_payload(&body).unwrap_or(&body).to_vec();
    mock.pubsub_published
        .lock()
        .unwrap()
        .push((topic.clone(), payload.clone()));

    let b64 = BASE64.encode(&payload);
    let json_line = format!("{{\"data\":\"{}\"}}\n", b64);
    let mut channels = mock.pubsub_channels.lock().unwrap();
    let tx = channels
        .entry(topic)
        .or_insert_with(|| tokio::sync::broadcast::channel(128).0);
    let _ = tx.send(json_line);

    StatusCode::OK
}

async fn fake_ipfs_pubsub_sub(
    State(mock): State<MockIpfs>,
    Query(params): Query<HashMap<String, String>>,
) -> Response {
    let topic = params.get("arg").cloned().unwrap_or_default();
    let rx = {
        let mut channels = mock.pubsub_channels.lock().unwrap();
        channels
            .entry(topic)
            .or_insert_with(|| tokio::sync::broadcast::channel(128).0)
            .subscribe()
    };

    let stream = futures_util::stream::unfold(rx, |mut rx| async move {
        match rx.recv().await {
            Ok(msg) => Some((Ok::<_, std::io::Error>(bytes::Bytes::from(msg)), rx)),
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                Some((Ok(bytes::Bytes::new()), rx))
            }
            Err(tokio::sync::broadcast::error::RecvError::Closed) => None,
        }
    });

    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from_stream(stream))
        .unwrap()
}

async fn spawn_mock_ipfs_server(mock: MockIpfs) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let app = Router::new()
        .route("/api/v0/cat", post(fake_ipfs_cat))
        .route("/api/v0/add", post(fake_ipfs_add))
        .route("/api/v0/pin/add", post(fake_ipfs_pin_add))
        .route("/api/v0/pin/rm", post(|| async { "{\"Pins\":[]}" }))
        .route("/api/v0/pubsub/pub", post(fake_ipfs_pubsub_pub))
        .route("/api/v0/pubsub/sub", post(fake_ipfs_pubsub_sub))
        .layer(DefaultBodyLimit::max(256 * 1024 * 1024))
        .with_state(mock);
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    format!("http://{}", addr)
}

// -----------------------------------------------------------------------------
// Mock GNS Stand-in
// -----------------------------------------------------------------------------

fn create_mock_gns_script(dir: &Path, gns_db_file: &Path) -> (String, PathBuf) {
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    let script_path = dir.join("mock-gnunet-gns");
    let script_content = format!(
        r#"#!/bin/sh
DB="{}"
touch "$DB"
if [ "$1" = "record" ]; then
    NAME=""
    TYPE=""
    VAL=""
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            -n) shift; if [ "$1" = "--" ]; then shift; fi; NAME="$1"; shift ;;
            -t) shift; TYPE="$1"; shift ;;
            -a) shift; if [ "$1" = "--" ]; then shift; fi; VAL="$1"; shift ;;
            *) shift ;;
        esac
    done
    echo "$NAME|$TYPE|$VAL" >> "$DB"
    exit 0
else
    TYPE=""
    NAME=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -t) shift; TYPE="$1"; shift ;;
            -u) shift; if [ "$1" = "--" ]; then shift; fi; NAME="$1"; shift ;;
            *) shift ;;
        esac
    done
    VAL=$(grep "^$NAME|$TYPE|" "$DB" | tail -n 1 | cut -d'|' -f3)
    if [ -n "$VAL" ]; then
        echo "$VAL"
        exit 0
    else
        echo "GNS record not found for $NAME type $TYPE" >&2
        exit 1
    fi
fi
"#,
        gns_db_file.display()
    );
    std::fs::write(&script_path, script_content).unwrap();
    #[cfg(unix)]
    std::fs::set_permissions(&script_path, std::fs::Permissions::from_mode(0o755)).unwrap();
    (
        script_path.to_string_lossy().into_owned(),
        gns_db_file.to_path_buf(),
    )
}

// -----------------------------------------------------------------------------
// TestNode Harness
// -----------------------------------------------------------------------------

pub struct TestNode {
    pub name: String,
    pub temp_dir: tempfile::TempDir,
    pub config: GipsdConfig,
    pub db: Database,
    pub auth_token: AuthToken,
    pub feed_pair: gips_trust::feed::GeneratedKeyPair,
    pub feed_priv_pem: String,
    pub feed_pub_pem: String,
    pub guix_pair: Option<GeneratedKeyPair>,
    pub base_url: String,
    pub ipfs_mock: MockIpfs,
    pub ipfs_api: String,
    pub client: reqwest::Client,
}

impl TestNode {
    pub async fn spawn(
        name: &str,
        mock_ipfs: Option<MockIpfs>,
        trusted_publishers: Vec<TrustedPublisher>,
        allow_unsigned: bool,
        shared_gns_db: Option<PathBuf>,
    ) -> Self {
        let temp_dir = tempfile::tempdir().unwrap();

        // 1. Key pairs
        let feed_key_path = temp_dir.path().join("feed_key.pem");
        let feed_pair = gips_trust::feed::generate_key_pair(&feed_key_path).unwrap();
        let feed_priv_pem = std::fs::read_to_string(&feed_pair.secret_key).unwrap();
        let feed_pub_pem = std::fs::read_to_string(&feed_pair.public_key).unwrap();

        let guix_key_path = temp_dir.path().join("guix_key.sec");
        let guix_pair = gips_trust::guix::generate_key_pair(&guix_key_path, None).ok();

        // 2. IPFS
        let ipfs_mock = mock_ipfs.unwrap_or_default();
        let ipfs_api = spawn_mock_ipfs_server(ipfs_mock.clone()).await;

        // 3. GNS
        let gns_db = shared_gns_db.unwrap_or_else(|| temp_dir.path().join("gns_records.db"));
        let (gns_command, _) = create_mock_gns_script(temp_dir.path(), &gns_db);

        // 4. Configuration
        let db_path = temp_dir.path().join("gipsd.sqlite");
        let auth_token = AuthToken::generate().unwrap();

        let config = GipsdConfig {
            listen: "127.0.0.1:0".to_string(),
            db_path,
            ipfs_api: ipfs_api.clone(),
            gns_command,
            guile_config: None,
            snapshot_cid: None,
            insecure_bind: false,
            auth_token_path: None,
            trust: gips_trust::TrustConfig {
                trusted_publishers,
                allow_unsigned,
                signing: Some(gips_trust::SigningConfig {
                    publisher_gns_name: Some(format!("{}.gnu", name)),
                    narinfo_private_key: feed_pair.secret_key.clone(),
                    narinfo_public_key: feed_pair.public_key.clone(),
                }),
            },
            guix_signing: guix_pair
                .as_ref()
                .map(|p| gips_trust::guix::GuixSigningConfig {
                    secret_key: p.secret_key.clone(),
                    host: Some(name.to_string()),
                    guile: None,
                }),
            cadet_command: "gnunet-cadet".to_string(),
            cadet_port: "gips-gossip".to_string(),
            gossip_transport: "ipfs".to_string(),
        };

        let db = Database::connect(&config).await.unwrap();

        // 5. Ephemeral TCP binding
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let local_addr = listener.local_addr().unwrap();
        let base_url = format!("http://{}", local_addr);

        let auth_holder = Arc::new(std::sync::RwLock::new(auth_token.clone()));
        let router = build_router(db.clone(), config.clone(), None, auth_holder);

        tokio::spawn(async move {
            let _ = axum::serve(listener, router).await;
        });

        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .unwrap();

        // Wait a tick for router & gossip workers to initialize
        tokio::time::sleep(Duration::from_millis(50)).await;

        Self {
            name: name.to_string(),
            temp_dir,
            config,
            db,
            auth_token,
            feed_pair,
            feed_priv_pem,
            feed_pub_pem,
            guix_pair,
            base_url,
            ipfs_mock,
            ipfs_api,
            client,
        }
    }

    /// Publishes a substitute object into IPFS and database, and optionally creates GNS feed.
    pub async fn publish_substitute(
        &self,
        store_path: &str,
        contents: &[u8],
        gns_name: Option<&str>,
    ) -> (String, NarIntegrity) {
        let obj_path = self.temp_dir.path().join(format!("obj-{}", self.name));
        std::fs::write(&obj_path, contents).unwrap();
        let (nar_bytes, integrity) =
            gips_nar::nar_and_integrity(&obj_path, GUIX_STORE_DIR, gips_nar::DEFAULT_MAX_NAR_BYTES)
                .unwrap();

        let cid = cid_for_bytes(&nar_bytes);
        self.ipfs_mock.insert_object(cid.clone(), nar_bytes.clone());

        let stored = StoredNarinfo {
            store_path: store_path.to_string(),
            ipfs_cid: cid.clone(),
            nar_hash: integrity.nar_hash.to_string(),
            nar_size: integrity.nar_size,
            references: integrity.references.to_narinfo_value(),
            deriver: None,
            system: None,
        };
        let narinfo_json = serde_json::to_string(&stored).unwrap();

        sqlx::query(
            r#"
            INSERT INTO substitutes (store_path, ipfs_cid, gns_name, narinfo_json, nar_hash, nar_size, nar_references)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
        )
        .bind(store_path)
        .bind(&cid)
        .bind(gns_name)
        .bind(&narinfo_json)
        .bind(&stored.nar_hash)
        .bind(stored.nar_size as i64)
        .bind(&stored.references)
        .execute(self.db.pool())
        .await
        .unwrap();

        if let Some(name) = gns_name {
            let narinfo_body = format!(
                "StorePath: {}\nURL: nar/{}\nCompression: none\nNarHash: {}\nNarSize: {}\nReferences: {}\n",
                store_path,
                cid,
                integrity.nar_hash,
                integrity.nar_size,
                integrity.references.to_narinfo_value()
            );
            // Sign with feed key naming the GNS name as publisher identity
            let sig = gips_trust::sign_narinfo(&narinfo_body, &self.feed_priv_pem, name).unwrap();
            let signed_narinfo = format!("{}Signature: {}\n", narinfo_body, sig);

            let mut manifest_map = HashMap::new();
            manifest_map.insert(
                store_path.to_string(),
                ManifestEntry {
                    artifact_cid: cid.clone(),
                    narinfo: signed_narinfo,
                },
            );

            let manifest_bytes = serde_json::to_vec(&manifest_map).unwrap();
            let manifest_cid = cid_for_bytes(&manifest_bytes);
            self.ipfs_mock
                .insert_object(manifest_cid.clone(), manifest_bytes);

            let gns = gips_gns::GnsClient::new(self.config.gns_command.clone());
            gns.publish(name, &manifest_cid, 65536).await.unwrap();
        }

        (cid, integrity)
    }

    /// Mints a signed vouch token delegating capabilities from this node to subject.
    pub fn mint_vouch_token(
        &self,
        subject_pub: &str,
        parent_token: Option<&VouchToken>,
        path_prefixes: Vec<String>,
        max_depth: u32,
        stake_score: u32,
        duration_secs: u64,
    ) -> VouchToken {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();

        gips_trust::mint_vouch_token(
            &self.feed_priv_pem,
            subject_pub,
            parent_token.map(|p| p.signature.clone()),
            now,
            now + duration_secs,
            VouchCapabilities {
                path_prefixes,
                max_depth,
                stake_score,
            },
        )
        .unwrap()
    }

    /// Ingests a vouch chain via authenticated POST /vouch/ingest.
    pub async fn ingest_vouch_chain(
        &self,
        chain: &[VouchToken],
    ) -> Result<VouchIngestResponse, (StatusCode, String)> {
        let url = format!("{}/vouch/ingest", self.base_url);
        let req = VouchIngestRequest {
            chain: chain.to_vec(),
        };

        let resp = self
            .client
            .post(&url)
            .header(
                "Authorization",
                format!("Bearer {}", self.auth_token.as_str()),
            )
            .json(&req)
            .send()
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

        let status = resp.status();
        let body = resp
            .text()
            .await
            .unwrap_or_else(|_| "cannot read response".to_string());

        if status.is_success() {
            serde_json::from_str::<VouchIngestResponse>(&body)
                .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
        } else {
            Err((status, body))
        }
    }

    /// Subscribes to a publisher's GNS name via authenticated POST /subscribe.
    pub async fn subscribe_publisher(&self, gns_name: &str) -> Result<(), (StatusCode, String)> {
        let url = format!("{}/subscribe", self.base_url);
        let req_json = serde_json::json!({ "gns_name": gns_name });

        let resp = self
            .client
            .post(&url)
            .header(
                "Authorization",
                format!("Bearer {}", self.auth_token.as_str()),
            )
            .json(&req_json)
            .send()
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

        let status = resp.status();
        if status.is_success() {
            Ok(())
        } else {
            let body = resp.text().await.unwrap_or_default();
            Err((status, body))
        }
    }

    /// Evaluates trust score and validity for a publisher via POST /trust/evaluate.
    pub async fn evaluate_trust(
        &self,
        publisher_key: &str,
        store_path: Option<&str>,
        chain: Option<Vec<VouchToken>>,
    ) -> Result<TrustEvaluateResponse, (StatusCode, String)> {
        let url = format!("{}/trust/evaluate", self.base_url);
        let req = TrustEvaluateRequest {
            publisher_key: publisher_key.to_string(),
            store_path: store_path.map(|s| s.to_string()),
            chain,
        };

        let resp = self
            .client
            .post(&url)
            .json(&req)
            .send()
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

        let status = resp.status();
        let body = resp
            .text()
            .await
            .unwrap_or_else(|_| "cannot read response".to_string());

        if status.is_success() {
            serde_json::from_str::<TrustEvaluateResponse>(&body)
                .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
        } else {
            Err((status, body))
        }
    }

    /// Submits a fraud proof via POST /fraud-proof/submit.
    pub async fn submit_fraud_proof(&self, proof: &FraudProof) -> Result<(), (StatusCode, String)> {
        let url = format!("{}/fraud-proof/submit", self.base_url);
        let resp = self
            .client
            .post(&url)
            .json(proof)
            .send()
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

        let status = resp.status();
        let body = resp
            .text()
            .await
            .unwrap_or_else(|_| "cannot read response".to_string());

        if status.is_success() {
            Ok(())
        } else {
            Err((status, body))
        }
    }

    /// Creates a snapshot over the specified store paths via authenticated POST /snapshot/create.
    pub async fn create_snapshot(
        &self,
        store_paths: Vec<String>,
        gns_name: Option<&str>,
    ) -> Result<String, (StatusCode, String)> {
        let url = format!("{}/snapshot/create", self.base_url);
        let req = CreateSnapshotRequest {
            store_paths,
            gns_name: gns_name.map(|s| s.to_string()),
        };

        let resp = self
            .client
            .post(&url)
            .header(
                "Authorization",
                format!("Bearer {}", self.auth_token.as_str()),
            )
            .json(&req)
            .send()
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

        let status = resp.status();
        let body = resp
            .text()
            .await
            .unwrap_or_else(|_| "cannot read response".to_string());

        if status.is_success() {
            let res: CreateSnapshotResponse = serde_json::from_str(&body)
                .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
            Ok(res.snapshot_cid)
        } else {
            Err((status, body))
        }
    }

    /// Exports snapshot archive tarball via GET /snapshot/export/:cid.
    pub async fn export_snapshot_tar(&self, cid: &str) -> Result<Vec<u8>, (StatusCode, String)> {
        let url = format!("{}/snapshot/export/{}", self.base_url, cid);
        let resp = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

        let status = resp.status();
        if status.is_success() {
            let bytes = resp
                .bytes()
                .await
                .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
            Ok(bytes.to_vec())
        } else {
            let body = resp.text().await.unwrap_or_default();
            Err((status, body))
        }
    }

    /// Unpacks a tarball into local IPFS storage and imports snapshot via authenticated POST /snapshot/import.
    pub async fn import_snapshot_tar(
        &self,
        tar_bytes: &[u8],
    ) -> Result<String, (StatusCode, String)> {
        let mut archive = tar::Archive::new(tar_bytes);
        let mut manifest_bytes = Vec::new();

        for entry in archive
            .entries()
            .map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?
        {
            let mut file = entry.map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;
            let path = file
                .path()
                .map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?
                .to_string_lossy()
                .into_owned();

            let mut contents = Vec::new();
            file.read_to_end(&mut contents)
                .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

            if path == "manifest.json" {
                manifest_bytes = contents;
            } else if let Some(cid) = path.strip_prefix("nar/") {
                self.ipfs_mock.insert_object(cid.to_string(), contents);
            }
        }

        if manifest_bytes.is_empty() {
            return Err((
                StatusCode::BAD_REQUEST,
                "Tar archive missing manifest.json".to_string(),
            ));
        }

        let manifest_cid = cid_for_bytes(&manifest_bytes);
        self.ipfs_mock
            .insert_object(manifest_cid.clone(), manifest_bytes);

        let url = format!("{}/snapshot/import", self.base_url);
        let req = ImportSnapshotRequest {
            cid: manifest_cid.clone(),
        };

        let resp = self
            .client
            .post(&url)
            .header(
                "Authorization",
                format!("Bearer {}", self.auth_token.as_str()),
            )
            .json(&req)
            .send()
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

        let status = resp.status();
        let body = resp
            .text()
            .await
            .unwrap_or_else(|_| "cannot read response".to_string());

        if status.is_success() {
            Ok(manifest_cid)
        } else {
            Err((status, body))
        }
    }

    /// Fetches a substitute via standard /narinfo and /nar endpoints.
    pub async fn fetch_substitute(
        &self,
        store_path: &str,
    ) -> Result<(String, Vec<u8>), (StatusCode, String)> {
        // 1. GET /narinfo?store_path=...
        let narinfo_url = format!("{}/narinfo?store_path={}", self.base_url, store_path);
        let resp = self
            .client
            .get(&narinfo_url)
            .send()
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err((status, body));
        }

        let narinfo_val: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

        let narinfo_json = narinfo_val
            .get("narinfo_json")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();

        // 2. GET /nar?store_path=...
        let nar_url = format!("{}/nar?store_path={}", self.base_url, store_path);
        let nar_resp = self
            .client
            .get(&nar_url)
            .send()
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

        let nar_status = nar_resp.status();
        if !nar_status.is_success() {
            let body = nar_resp.text().await.unwrap_or_default();
            return Err((nar_status, body));
        }

        let nar_bytes = nar_resp
            .bytes()
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
            .to_vec();

        Ok((narinfo_json, nar_bytes))
    }

    /// Fetches native Guix narinfo and nar via /<hash>.narinfo and /nar/<cid>.
    pub async fn fetch_native_substitute(
        &self,
        store_hash: &str,
        cid: &str,
    ) -> Result<(String, Vec<u8>), (StatusCode, String)> {
        // 1. GET /<hash>.narinfo
        let narinfo_url = format!("{}/{}.narinfo", self.base_url, store_hash);
        let resp = self
            .client
            .get(&narinfo_url)
            .send()
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err((status, body));
        }

        let narinfo_body = resp
            .text()
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

        // 2. GET /nar/<cid>
        let nar_url = format!("{}/nar/{}", self.base_url, cid);
        let nar_resp = self
            .client
            .get(&nar_url)
            .send()
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

        let nar_status = nar_resp.status();
        if !nar_status.is_success() {
            let body = nar_resp.text().await.unwrap_or_default();
            return Err((nar_status, body));
        }

        let nar_bytes = nar_resp
            .bytes()
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
            .to_vec();

        Ok((narinfo_body, nar_bytes))
    }
}

// -----------------------------------------------------------------------------
// Scenario 1: Multi-Hop Vouch Delegation & Dynamic Substitute Serving
// -----------------------------------------------------------------------------

#[tokio::test]
async fn scenario_multi_hop_vouch_and_substitute_serving() {
    let mock_ipfs = MockIpfs::new();
    let gns_temp = tempfile::tempdir().unwrap();
    let shared_gns_db = gns_temp.path().join("gns.db");

    // 1. Node A (Root Authority)
    let node_a = TestNode::spawn(
        "node-a",
        Some(mock_ipfs.clone()),
        vec![],
        false,
        Some(shared_gns_db.clone()),
    )
    .await;

    // 2. Node B (Intermediate Voucher)
    let node_b = TestNode::spawn(
        "node-b",
        Some(mock_ipfs.clone()),
        vec![],
        false,
        Some(shared_gns_db.clone()),
    )
    .await;

    // 3. Node C (Leaf Publisher)
    let node_c = TestNode::spawn(
        "node-c",
        Some(mock_ipfs.clone()),
        vec![],
        false,
        Some(shared_gns_db.clone()),
    )
    .await;

    // 4. Node D (Consumer configured with Node A as trusted root)
    let node_d = TestNode::spawn(
        "node-d",
        Some(mock_ipfs.clone()),
        vec![TrustedPublisher {
            gns_name: "node-a.gnu".to_string(),
            public_key: node_a.feed_pair.public_key.clone(),
        }],
        false,
        Some(shared_gns_db.clone()),
    )
    .await;

    // Step A: Node A mints vouch token for Node B (depth 2)
    let tok_a_b = node_a.mint_vouch_token(
        &node_b.feed_pub_pem,
        None,
        vec!["/gnu/store/".to_string()],
        2,
        100,
        3600,
    );

    // Step B: Node B mints child vouch token for Node C (depth 1)
    let tok_b_c = node_b.mint_vouch_token(
        &node_c.feed_pub_pem,
        Some(&tok_a_b),
        vec!["/gnu/store/".to_string()],
        1,
        100,
        3600,
    );

    let chain = vec![tok_a_b.clone(), tok_b_c.clone()];

    // Step C: Node C publishes substitute /gnu/store/aaa-hello-1.0
    let store_path = "/gnu/store/00000000000000000000000000000000-aaa-hello-1.0";
    let payload_bytes = b"Hello from GIPS distributed federation!\n";
    let (cid, integrity) = node_c
        .publish_substitute(store_path, payload_bytes, Some("node-c.gnu"))
        .await;

    // Step D: Node D subscribes to node-c.gnu and ingests vouch chain [A -> B -> C]
    node_d.subscribe_publisher("node-c.gnu").await.unwrap();
    let ingest_res = node_d.ingest_vouch_chain(&chain).await.unwrap();
    assert!(ingest_res.ok);
    node_d
        .db
        .record_vouch_chain(&node_a.feed_pub_pem, "node-c.gnu", &chain)
        .await
        .unwrap();

    // Step E: Node D evaluates trust for Node C (score decayed: 100 * 0.85 * 0.85 = 72 >= 50)
    let eval_res = node_d
        .evaluate_trust(&node_c.feed_pub_pem, Some(store_path), Some(chain.clone()))
        .await
        .unwrap();
    assert!(eval_res.trusted, "Node C must be trusted via vouch chain");
    assert!(
        eval_res.score >= 50,
        "Decayed trust score ({}) must be >= 50",
        eval_res.score
    );

    // Step F: Node D fetches substitute and verifies content integrity
    let (narinfo_body, nar_bytes) = node_d.fetch_substitute(store_path).await.unwrap();
    assert!(narinfo_body.contains(&format!("StorePath: {}\n", store_path)));
    assert!(narinfo_body.contains(&format!("URL: nar/{}\n", cid)));
    assert!(narinfo_body.contains(&format!("NarHash: {}\n", integrity.nar_hash)));
    assert!(narinfo_body.contains(&format!("NarSize: {}\n", integrity.nar_size)));
    assert!(narinfo_body.contains("Signature: "));

    // Verify raw nar contents
    let (expected_nar, _) = gips_nar::nar_and_integrity(
        &node_c.temp_dir.path().join("obj-node-c"),
        GUIX_STORE_DIR,
        gips_nar::DEFAULT_MAX_NAR_BYTES,
    )
    .unwrap();
    assert_eq!(nar_bytes, expected_nar);

    // Also verify native Guix endpoint on Node C
    let store_hash = "00000000000000000000000000000000";
    let (native_narinfo, native_nar) = node_c
        .fetch_native_substitute(store_hash, &cid)
        .await
        .unwrap();
    assert!(native_narinfo.contains(&format!("NarHash: {}\n", integrity.nar_hash)));
    assert!(native_narinfo.contains(&format!("URL: nar/{}\n", cid)));
    assert_eq!(native_nar, expected_nar);
}

// -----------------------------------------------------------------------------
// Scenario 2: Objective Fraud Proof Generation, Gossip, & Peer Blacklisting
// -----------------------------------------------------------------------------

#[tokio::test]
async fn scenario_fraud_proof_generation_and_peer_revocation() {
    let mock_ipfs = MockIpfs::new();
    let gns_temp = tempfile::tempdir().unwrap();
    let shared_gns_db = gns_temp.path().join("gns.db");

    // 1. Rogue Node X
    let node_x = TestNode::spawn(
        "node-x",
        Some(mock_ipfs.clone()),
        vec![],
        false,
        Some(shared_gns_db.clone()),
    )
    .await;

    // 2. Consumer Node D (Trusted publishers includes Node X)
    let node_d = TestNode::spawn(
        "node-d",
        Some(mock_ipfs.clone()),
        vec![TrustedPublisher {
            gns_name: "node-x.gnu".to_string(),
            public_key: node_x.feed_pair.public_key.clone(),
        }],
        false,
        Some(shared_gns_db.clone()),
    )
    .await;

    // 3. Peering Node E (Also has Node X in trusted publishers)
    let node_e = TestNode::spawn(
        "node-e",
        Some(mock_ipfs.clone()),
        vec![TrustedPublisher {
            gns_name: "node-x.gnu".to_string(),
            public_key: node_x.feed_pair.public_key.clone(),
        }],
        false,
        Some(shared_gns_db.clone()),
    )
    .await;

    // Subscribe both consumer nodes to node-x.gnu
    node_d.subscribe_publisher("node-x.gnu").await.unwrap();
    node_e.subscribe_publisher("node-x.gnu").await.unwrap();

    // Wait for gossip workers on Node D and Node E to connect to pubsub
    mock_ipfs.wait_for_subscriber(TOPIC_FRAUD).await;

    // Step A: Node X prepares a tampered substitute (genuine NarHash signed, but forged bytes in IPFS)
    let store_path = "/gnu/store/8009y4y5d4rhm796p02a7b8w6k2hvwq2-bash-5.1.16";
    let narinfo_body = format!(
        "StorePath: {}\nURL: nar/QmTamperedArtifact\nCompression: none\nNarHash: sha256:0mdqa9w1p6cmli6976v4wi0sw9r4p5prkj7lzfd1877wk11c9c73\nNarSize: 22\nReferences: \n",
        store_path
    );
    let signature =
        gips_trust::sign_narinfo(&narinfo_body, &node_x.feed_priv_pem, "node-x.gnu").unwrap();

    let tampered_bytes = b"injected malicious malware payload that mismatches narhash";

    // Step B: Node D detects HashMismatch fraud and generates objective FraudProof
    let fraud_proof = gips_trust::generate_hash_mismatch_proof(
        &node_x.feed_pub_pem,
        &narinfo_body,
        &signature,
        tampered_bytes,
    );

    // Verify fraud proof structure locally
    assert_eq!(
        fraud_proof.proof_type,
        FraudProofType::HashMismatch {
            narinfo_body: narinfo_body.clone(),
            signature: signature.clone(),
            artifact_bytes_base64: BASE64.encode(tampered_bytes),
        }
    );

    // Step C: Node D submits FraudProof via POST /fraud-proof/submit
    node_d.submit_fraud_proof(&fraud_proof).await.unwrap();

    // Node D immediately blacklists Node X
    let d_revoked = node_d
        .db
        .is_publisher_revoked(&node_x.feed_pub_pem)
        .await
        .unwrap();
    assert!(d_revoked, "Node D must immediately blacklist Node X");

    // Step D: Node E receives the gossiped fraud proof over gips.fraud.v1
    let mut e_revoked = false;
    for _ in 0..50 {
        tokio::time::sleep(Duration::from_millis(30)).await;
        if node_e
            .db
            .is_publisher_revoked(&node_x.feed_pub_pem)
            .await
            .unwrap()
        {
            e_revoked = true;
            break;
        }
    }
    assert!(
        e_revoked,
        "Node E must receive gossiped fraud proof and blacklist Node X"
    );

    // Step E: Subsequent substitute requests to Node D and Node E for Node X's packages return 404
    // Publish a substitute under node-x
    let (_cid_x, _integrity_x) = node_x
        .publish_substitute(store_path, b"test-content", Some("node-x.gnu"))
        .await;

    // Node D fetch fails
    let fetch_d = node_d.fetch_substitute(store_path).await;
    assert!(
        fetch_d.is_err(),
        "Node D must refuse substitute from blacklisted publisher"
    );

    // Node E fetch fails
    let fetch_e = node_e.fetch_substitute(store_path).await;
    assert!(
        fetch_e.is_err(),
        "Node E must refuse substitute from blacklisted publisher"
    );
}

// -----------------------------------------------------------------------------
// Scenario 3: Offline Air-Gapped Snapshot Export & Import
// -----------------------------------------------------------------------------

#[tokio::test]
async fn scenario_offline_snapshot_export_and_import() {
    // 1. Connected Node C
    let node_c = TestNode::spawn("node-c", None, vec![], true, None).await;

    // Publish multiple store paths on Node C
    let path_py = "/gnu/store/11111111111111111111111111111111-python-3.11";
    let path_np = "/gnu/store/22222222222222222222222222222222-numpy-1.26";
    let path_sci = "/gnu/store/33333333333333333333333333333333-scipy-1.12";

    let (cid_py, int_py) = node_c
        .publish_substitute(path_py, b"Python 3.11 runtime binaries", None)
        .await;
    let (cid_np, int_np) = node_c
        .publish_substitute(path_np, b"NumPy 1.26 numeric arrays", None)
        .await;
    let (cid_sci, int_sci) = node_c
        .publish_substitute(path_sci, b"SciPy 1.12 scientific algorithms", None)
        .await;

    // Step A: Node C creates snapshot "data-science-2026"
    let store_paths = vec![
        path_py.to_string(),
        path_np.to_string(),
        path_sci.to_string(),
    ];
    let snapshot_cid = node_c
        .create_snapshot(store_paths.clone(), Some("data-science-2026.gnu"))
        .await
        .unwrap();
    assert!(!snapshot_cid.is_empty());

    // Step B: Node C exports .tar snapshot archive
    let tar_bytes = node_c.export_snapshot_tar(&snapshot_cid).await.unwrap();
    assert!(!tar_bytes.is_empty());

    // Verify tar structure contains manifest and all constituent NARs
    let mut archive = tar::Archive::new(tar_bytes.as_slice());
    let mut found_manifest = false;
    let mut found_py = false;
    let mut found_np = false;
    let mut found_sci = false;

    for entry in archive.entries().unwrap() {
        let file = entry.unwrap();
        let path = file.path().unwrap().to_string_lossy().into_owned();
        if path == "manifest.json" {
            found_manifest = true;
        } else if path == format!("nar/{}", cid_py) {
            found_py = true;
        } else if path == format!("nar/{}", cid_np) {
            found_np = true;
        } else if path == format!("nar/{}", cid_sci) {
            found_sci = true;
        }
    }

    assert!(found_manifest, "Tarball must contain manifest.json");
    assert!(found_py, "Tarball must contain Python NAR");
    assert!(found_np, "Tarball must contain NumPy NAR");
    assert!(found_sci, "Tarball must contain SciPy NAR");

    // Step C: Isolated Node F (completely air-gapped / separate fresh IPFS)
    let isolated_ipfs = MockIpfs::new();
    let node_f = TestNode::spawn("node-f", Some(isolated_ipfs), vec![], true, None).await;

    // Step D: Node F imports the .tar snapshot
    let imported_cid = node_f.import_snapshot_tar(&tar_bytes).await.unwrap();
    assert_eq!(imported_cid, snapshot_cid);

    // Step E: Node F successfully serves /narinfo and /nar for all snapshot store paths without network
    // 1. Python
    let (py_narinfo, py_nar) = node_f.fetch_substitute(path_py).await.unwrap();
    let py_stored: StoredNarinfo = serde_json::from_str(&py_narinfo).unwrap();
    assert_eq!(py_stored.store_path, path_py);
    assert_eq!(py_stored.ipfs_cid, cid_py);
    assert_eq!(py_stored.nar_hash, int_py.nar_hash.to_string());
    assert!(!py_nar.is_empty());

    // 2. NumPy
    let (np_narinfo, np_nar) = node_f.fetch_substitute(path_np).await.unwrap();
    let np_stored: StoredNarinfo = serde_json::from_str(&np_narinfo).unwrap();
    assert_eq!(np_stored.store_path, path_np);
    assert_eq!(np_stored.ipfs_cid, cid_np);
    assert_eq!(np_stored.nar_hash, int_np.nar_hash.to_string());
    assert!(!np_nar.is_empty());

    // 3. SciPy
    let (sci_narinfo, sci_nar) = node_f.fetch_substitute(path_sci).await.unwrap();
    let sci_stored: StoredNarinfo = serde_json::from_str(&sci_narinfo).unwrap();
    assert_eq!(sci_stored.store_path, path_sci);
    assert_eq!(sci_stored.ipfs_cid, cid_sci);
    assert_eq!(sci_stored.nar_hash, int_sci.nar_hash.to_string());
    assert!(!sci_nar.is_empty());

    // Also verify native Guix endpoints on Node F
    let py_hash = &path_py[11..43];
    let (py_native_narinfo, py_native_nar) = node_f
        .fetch_native_substitute(py_hash, &cid_py)
        .await
        .unwrap();
    assert!(py_native_narinfo.contains(&format!("NarHash: {}\n", int_py.nar_hash)));
    assert_eq!(py_native_nar, py_nar);
}
