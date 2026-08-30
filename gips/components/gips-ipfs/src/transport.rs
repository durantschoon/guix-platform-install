use crate::IpfsClient;
use async_trait::async_trait;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::pin::Pin;
use std::sync::Arc;
use tokio::sync::{broadcast, RwLock};

#[derive(thiserror::Error, Debug)]
pub enum GossipError {
    #[error("transport error: {0}")]
    Transport(String),
    #[error("serialization error: {0}")]
    Serialization(String),
    #[error("channel closed")]
    Closed,
    #[error("subscription error: {0}")]
    Subscription(String),
}

impl From<anyhow::Error> for GossipError {
    fn from(err: anyhow::Error) -> Self {
        GossipError::Transport(err.to_string())
    }
}

impl From<serde_json::Error> for GossipError {
    fn from(err: serde_json::Error) -> Self {
        GossipError::Serialization(err.to_string())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct GossipTransportStatus {
    pub transport_type: String,
    pub topics: Vec<String>,
    pub peer_count: usize,
}

pub type GossipStream =
    Pin<Box<dyn futures_util::Stream<Item = Result<Vec<u8>, GossipError>> + Send>>;

/// Core pluggable transport interface for gossip network communications.
#[async_trait]
pub trait GossipTransport: Send + Sync {
    /// Publish a message payload to the specified topic.
    async fn publish(&self, topic: &str, payload: &[u8]) -> Result<(), GossipError>;

    /// Subscribe to incoming messages on the specified topic.
    async fn subscribe(&self, topic: &str) -> Result<GossipStream, GossipError>;

    /// Inspect the health and connectivity status of this transport.
    async fn status(&self) -> Result<GossipTransportStatus, GossipError>;

    /// Return a human-readable transport identifier.
    fn transport_type(&self) -> &'static str;
}

// ---------------------------------------------------------------------------
// IPFS PubSub Transport
// ---------------------------------------------------------------------------

#[derive(Clone)]
pub struct IpfsPubsubTransport {
    client: IpfsClient,
}

impl IpfsPubsubTransport {
    pub fn new(client: IpfsClient) -> Self {
        Self { client }
    }
}

#[derive(Deserialize)]
struct IpfsPubSubEnvelope {
    #[serde(default)]
    pub data: Option<String>,
}

fn base64_decode_pubsub(input: &str) -> Option<Vec<u8>> {
    let input = input.trim().as_bytes();
    let mut table = [255u8; 256];
    for (i, &c) in b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        .iter()
        .enumerate()
    {
        table[c as usize] = i as u8;
    }
    let mut out = Vec::with_capacity((input.len() * 3) / 4);
    let mut buf = 0u32;
    let mut bits = 0;
    for &b in input {
        if b == b'=' {
            break;
        }
        let val = table[b as usize];
        if val == 255 {
            continue;
        }
        buf = (buf << 6) | (val as u32);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
        }
    }
    Some(out)
}

#[async_trait]
impl GossipTransport for IpfsPubsubTransport {
    async fn publish(&self, topic: &str, payload: &[u8]) -> Result<(), GossipError> {
        self.client
            .pubsub_pub(topic, payload)
            .await
            .map_err(|e| GossipError::Transport(e.to_string()))
    }

    async fn subscribe(&self, topic: &str) -> Result<GossipStream, GossipError> {
        let resp = self
            .client
            .pubsub_sub(topic)
            .await
            .map_err(|e| GossipError::Subscription(e.to_string()))?;

        let (tx, mut rx) = tokio::sync::mpsc::channel(128);

        tokio::spawn(async move {
            let mut byte_stream = resp.bytes_stream();
            let mut buffer = Vec::new();

            while let Some(chunk_res) = byte_stream.next().await {
                match chunk_res {
                    Ok(chunk) => {
                        buffer.extend_from_slice(&chunk);
                        while let Some(pos) = buffer.iter().position(|&b| b == b'\n') {
                            let line_bytes: Vec<u8> = buffer.drain(..=pos).collect();
                            let line = String::from_utf8_lossy(&line_bytes);
                            let trimmed = line.trim();
                            if !trimmed.is_empty() {
                                let payload = if let Ok(envelope) =
                                    serde_json::from_str::<IpfsPubSubEnvelope>(trimmed)
                                {
                                    if let Some(ref d) = envelope.data {
                                        base64_decode_pubsub(d)
                                            .unwrap_or_else(|| d.as_bytes().to_vec())
                                    } else {
                                        trimmed.as_bytes().to_vec()
                                    }
                                } else {
                                    trimmed.as_bytes().to_vec()
                                };
                                if tx.send(Ok(payload)).await.is_err() {
                                    return;
                                }
                            }
                        }
                    }
                    Err(e) => {
                        let _ = tx.send(Err(GossipError::Transport(e.to_string()))).await;
                        break;
                    }
                }
            }
        });

        let stream = futures_util::stream::poll_fn(move |cx| rx.poll_recv(cx));
        Ok(Box::pin(stream))
    }

    async fn status(&self) -> Result<GossipTransportStatus, GossipError> {
        Ok(GossipTransportStatus {
            transport_type: "ipfs_pubsub".to_string(),
            topics: vec!["gips.vouch.v1".to_string(), "gips.fraud.v1".to_string()],
            peer_count: 1,
        })
    }

    fn transport_type(&self) -> &'static str {
        "ipfs_pubsub"
    }
}

// ---------------------------------------------------------------------------
// In-Memory Mesh Transport (Multi-Node Test Fabric)
// ---------------------------------------------------------------------------

#[derive(Clone, Default)]
pub struct MemoryMeshTransport {
    channels: Arc<RwLock<HashMap<String, broadcast::Sender<Vec<u8>>>>>,
}

impl MemoryMeshTransport {
    pub fn new() -> Self {
        Self::default()
    }

    async fn get_or_create_sender(&self, topic: &str) -> broadcast::Sender<Vec<u8>> {
        let mut map = self.channels.write().await;
        if let Some(sender) = map.get(topic) {
            sender.clone()
        } else {
            let (sender, _) = broadcast::channel(1024);
            map.insert(topic.to_string(), sender.clone());
            sender
        }
    }
}

#[async_trait]
impl GossipTransport for MemoryMeshTransport {
    async fn publish(&self, topic: &str, payload: &[u8]) -> Result<(), GossipError> {
        let sender = self.get_or_create_sender(topic).await;
        let _ = sender.send(payload.to_vec());
        Ok(())
    }

    async fn subscribe(&self, topic: &str) -> Result<GossipStream, GossipError> {
        let sender = self.get_or_create_sender(topic).await;
        let mut rx = sender.subscribe();

        let (tx, mut output_rx) = tokio::sync::mpsc::channel(128);
        tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(msg) => {
                        if tx.send(Ok(msg)).await.is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        tracing::warn!("Memory mesh subscriber lagged by {} messages", skipped);
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        break;
                    }
                }
            }
        });

        let stream = futures_util::stream::poll_fn(move |cx| output_rx.poll_recv(cx));
        Ok(Box::pin(stream))
    }

    async fn status(&self) -> Result<GossipTransportStatus, GossipError> {
        let map = self.channels.read().await;
        let topics = map.keys().cloned().collect();
        let total_subscribers: usize = map.values().map(|s| s.receiver_count()).sum();
        Ok(GossipTransportStatus {
            transport_type: "in_memory_mesh".to_string(),
            topics,
            peer_count: total_subscribers,
        })
    }

    fn transport_type(&self) -> &'static str {
        "in_memory_mesh"
    }
}

// ---------------------------------------------------------------------------
// GNUnet CADET Message Framing & Transport
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CadetMessageEnvelope {
    pub topic: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sender: Option<String>,
    pub timestamp: u64,
    pub payload_base64: String,
}

impl CadetMessageEnvelope {
    pub fn new(topic: impl Into<String>, payload: &[u8]) -> Self {
        use base64::engine::general_purpose::STANDARD as BASE64;
        use base64::Engine;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        Self {
            topic: topic.into(),
            sender: None,
            timestamp: now,
            payload_base64: BASE64.encode(payload),
        }
    }

    pub fn decode_payload(&self) -> Result<Vec<u8>, GossipError> {
        use base64::engine::general_purpose::STANDARD as BASE64;
        use base64::Engine;
        BASE64.decode(&self.payload_base64).map_err(|e| {
            GossipError::Serialization(format!("invalid base64 in cadet envelope: {}", e))
        })
    }
}

#[derive(Clone)]
pub struct GnunetCadetTransport {
    cadet_port: String,
    cadet_command: String,
    connected_peers: Arc<std::sync::atomic::AtomicUsize>,
    topics: Arc<RwLock<HashMap<String, broadcast::Sender<Vec<u8>>>>>,
    outbound_tx: Arc<RwLock<Option<tokio::sync::mpsc::Sender<CadetMessageEnvelope>>>>,
}

impl GnunetCadetTransport {
    pub fn new(cadet_port: impl Into<String>) -> Self {
        Self::with_command(cadet_port, "gnunet-cadet")
    }

    pub fn with_command(cadet_port: impl Into<String>, cadet_command: impl Into<String>) -> Self {
        Self {
            cadet_port: cadet_port.into(),
            cadet_command: cadet_command.into(),
            connected_peers: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
            topics: Arc::new(RwLock::new(HashMap::new())),
            outbound_tx: Arc::new(RwLock::new(None)),
        }
    }

    pub fn cadet_port(&self) -> &str {
        &self.cadet_port
    }

    pub fn cadet_command(&self) -> &str {
        &self.cadet_command
    }

    /// Set an explicit outbound pipeline channel (e.g. connected to a mock or active cadet subprocess)
    pub async fn set_outbound_sender(&self, tx: tokio::sync::mpsc::Sender<CadetMessageEnvelope>) {
        let mut out = self.outbound_tx.write().await;
        *out = Some(tx);
    }

    /// Feed an incoming framed envelope into the local transport subscribers
    pub async fn ingest_envelope(&self, env: CadetMessageEnvelope) -> Result<(), GossipError> {
        let payload = env.decode_payload()?;
        let topics = self.topics.read().await;
        if let Some(sender) = topics.get(&env.topic) {
            let _ = sender.send(payload);
        }
        Ok(())
    }

    /// Feed a raw JSON line (e.g. from gnunet-cadet stdout or pipe) into transport
    pub async fn ingest_raw_line(&self, line: &str) -> Result<(), GossipError> {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            return Ok(());
        }
        let env: CadetMessageEnvelope = serde_json::from_str(trimmed)?;
        self.ingest_envelope(env).await
    }
}

#[async_trait]
impl GossipTransport for GnunetCadetTransport {
    async fn publish(&self, topic: &str, payload: &[u8]) -> Result<(), GossipError> {
        let envelope = CadetMessageEnvelope::new(topic, payload);

        // 1. Deliver to local subscribers on this node
        {
            let topics = self.topics.read().await;
            if let Some(sender) = topics.get(topic) {
                let _ = sender.send(payload.to_vec());
            }
        }

        // 2. Transmit to outbound CADET pipeline if configured
        {
            let out = self.outbound_tx.read().await;
            if let Some(ref tx) = *out {
                let _ = tx.send(envelope).await;
            }
        }

        Ok(())
    }

    async fn subscribe(&self, topic: &str) -> Result<GossipStream, GossipError> {
        let mut topics = self.topics.write().await;
        let rx = match topics.get(topic) {
            Some(sender) => sender.subscribe(),
            None => {
                let (sender, rx) = broadcast::channel(100);
                topics.insert(topic.to_string(), sender);
                rx
            }
        };

        self.connected_peers
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);

        let stream = futures_util::stream::unfold(rx, |mut rx| async move {
            loop {
                match rx.recv().await {
                    Ok(msg) => return Some((Ok(msg), rx)),
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => return None,
                }
            }
        });

        Ok(Box::pin(stream))
    }

    async fn status(&self) -> Result<GossipTransportStatus, GossipError> {
        let topics = self.topics.read().await;
        let mut topic_list: Vec<String> = topics.keys().cloned().collect();
        if topic_list.is_empty() {
            topic_list = vec!["gips.vouch.v1".to_string(), "gips.fraud.v1".to_string()];
        }
        topic_list.sort();

        Ok(GossipTransportStatus {
            transport_type: format!("gnunet_cadet:{}", self.cadet_port),
            topics: topic_list,
            peer_count: self
                .connected_peers
                .load(std::sync::atomic::Ordering::Relaxed),
        })
    }

    fn transport_type(&self) -> &'static str {
        "gnunet_cadet"
    }
}

// ---------------------------------------------------------------------------
// Multi-Transport Composite Gossip Aggregator
// ---------------------------------------------------------------------------

#[derive(Clone)]
pub struct CompositeGossipTransport {
    transports: Vec<Arc<dyn GossipTransport>>,
}

impl CompositeGossipTransport {
    pub fn new(transports: Vec<Arc<dyn GossipTransport>>) -> Self {
        Self { transports }
    }
}

#[async_trait]
impl GossipTransport for CompositeGossipTransport {
    async fn publish(&self, topic: &str, payload: &[u8]) -> Result<(), GossipError> {
        let mut last_err = None;
        let mut success = false;
        for t in &self.transports {
            match t.publish(topic, payload).await {
                Ok(()) => success = true,
                Err(e) => last_err = Some(e),
            }
        }
        if success || self.transports.is_empty() {
            Ok(())
        } else {
            Err(last_err
                .unwrap_or_else(|| GossipError::Transport("no active transports".to_string())))
        }
    }

    async fn subscribe(&self, topic: &str) -> Result<GossipStream, GossipError> {
        if self.transports.is_empty() {
            let (_tx, mut rx) = tokio::sync::mpsc::channel(1);
            let stream = futures_util::stream::poll_fn(move |cx| rx.poll_recv(cx));
            return Ok(Box::pin(stream));
        }

        let mut streams = Vec::new();
        for t in &self.transports {
            if let Ok(stream) = t.subscribe(topic).await {
                streams.push(stream);
            }
        }

        let merged = futures_util::stream::select_all(streams);
        Ok(Box::pin(merged))
    }

    async fn status(&self) -> Result<GossipTransportStatus, GossipError> {
        let mut topics = std::collections::BTreeSet::new();
        let mut peer_count = 0;
        let mut types = Vec::new();

        for t in &self.transports {
            if let Ok(st) = t.status().await {
                types.push(st.transport_type);
                peer_count += st.peer_count;
                for top in st.topics {
                    topics.insert(top);
                }
            } else {
                types.push(t.transport_type().to_string());
            }
        }

        Ok(GossipTransportStatus {
            transport_type: format!("composite:[{}]", types.join(", ")),
            topics: topics.into_iter().collect(),
            peer_count,
        })
    }

    fn transport_type(&self) -> &'static str {
        "composite"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_memory_mesh_publish_and_subscribe_fanout() {
        let mesh = MemoryMeshTransport::new();
        let mut sub1 = mesh.subscribe("test.topic").await.unwrap();
        let mut sub2 = mesh.subscribe("test.topic").await.unwrap();

        mesh.publish("test.topic", b"hello mesh").await.unwrap();

        let msg1 = sub1.next().await.unwrap().unwrap();
        let msg2 = sub2.next().await.unwrap().unwrap();

        assert_eq!(msg1, b"hello mesh");
        assert_eq!(msg2, b"hello mesh");

        let status = mesh.status().await.unwrap();
        assert_eq!(status.transport_type, "in_memory_mesh");
        assert!(status.topics.contains(&"test.topic".to_string()));
        assert_eq!(status.peer_count, 2);
    }

    #[tokio::test]
    async fn test_cadet_envelope_roundtrip() {
        let env = CadetMessageEnvelope::new("gips.vouch.v1", b"vouch-payload-data");
        assert_eq!(env.topic, "gips.vouch.v1");
        let decoded = env.decode_payload().unwrap();
        assert_eq!(decoded, b"vouch-payload-data");

        let json = serde_json::to_string(&env).unwrap();
        let parsed: CadetMessageEnvelope = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, env);
    }

    #[tokio::test]
    async fn test_cadet_transport_publish_and_subscribe() {
        let cadet = GnunetCadetTransport::new("gips-gossip");
        let (out_tx, mut out_rx) = tokio::sync::mpsc::channel(10);
        cadet.set_outbound_sender(out_tx).await;

        let mut sub = cadet.subscribe("gips.vouch.v1").await.unwrap();

        // 1. Test publish sends both to local subscriber and outbound pipeline
        cadet
            .publish("gips.vouch.v1", b"local-and-remote-data")
            .await
            .unwrap();

        let received = sub.next().await.unwrap().unwrap();
        assert_eq!(received, b"local-and-remote-data");

        let outbound = out_rx.recv().await.unwrap();
        assert_eq!(outbound.topic, "gips.vouch.v1");
        assert_eq!(outbound.decode_payload().unwrap(), b"local-and-remote-data");

        // 2. Test ingestion from incoming remote line
        let incoming_env = CadetMessageEnvelope::new("gips.vouch.v1", b"remote-incoming-data");
        let raw_line = serde_json::to_string(&incoming_env).unwrap();
        cadet.ingest_raw_line(&raw_line).await.unwrap();

        let from_remote = sub.next().await.unwrap().unwrap();
        assert_eq!(from_remote, b"remote-incoming-data");
    }

    #[tokio::test]
    async fn test_composite_gossip_transport_aggregation() {
        let mesh = Arc::new(MemoryMeshTransport::new());
        let cadet = Arc::new(GnunetCadetTransport::new("gips-composite-port"));

        let composite = CompositeGossipTransport::new(vec![mesh.clone(), cadet.clone()]);
        let mut sub = composite.subscribe("gips.fraud.v1").await.unwrap();

        // Publish to composite broadcasts to underlying mesh and cadet
        composite
            .publish("gips.fraud.v1", b"fraud-alert-payload")
            .await
            .unwrap();

        let received = sub.next().await.unwrap().unwrap();
        assert_eq!(received, b"fraud-alert-payload");

        let status = composite.status().await.unwrap();
        assert_eq!(
            status.transport_type,
            "composite:[in_memory_mesh, gnunet_cadet:gips-composite-port]"
        );
        assert!(status.topics.contains(&"gips.fraud.v1".to_string()));
    }
}
