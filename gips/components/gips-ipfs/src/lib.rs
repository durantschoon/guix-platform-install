use anyhow::{Context, Result};
use reqwest::Client;
use serde::Deserialize;
use sha2::{Digest, Sha256};

pub mod transport;
pub use transport::{
    CadetMessageEnvelope, CompositeGossipTransport, GnunetCadetTransport, GossipError,
    GossipStream, GossipTransport, GossipTransportStatus, IpfsPubsubTransport, MemoryMeshTransport,
};

/// Ceiling on a buffered [`IpfsClient::cat`] response.
///
/// This is a DoS bound on the paths that genuinely have to hold their answer
/// in memory — feeds, manifests, snapshot blobs — and it is deliberately *not*
/// applied to [`IpfsClient::cat_stream`], whose caller carries a signed
/// `NarSize` and enforces that instead.
pub const MAX_CAT_BYTES: u64 = 10 * 1024 * 1024;

/// How long a streaming transfer may stall before it is abandoned.
///
/// A *read* timeout, not a total one: a multi-gigabyte nar legitimately takes
/// longer than any fixed deadline, but a connection that has gone quiet for
/// this long is dead either way.
const STREAM_READ_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

#[derive(Clone)]
pub struct IpfsClient {
    client: Client,
    /// The client used for transfers whose size is bounded by a signed record
    /// rather than by a constant.
    ///
    /// A second client rather than a second config on the first one: the
    /// 30-second *total* timeout on `client` is the right bound for a feed
    /// fetch and a fatal one for a large nar, and the two policies cannot
    /// coexist on one `reqwest::Client`. Clients are `Arc`-backed, so this
    /// costs a pointer and one connection pool.
    stream_client: Client,
    api_base: String,
}

#[derive(Debug, Deserialize)]
struct AddResponse {
    #[serde(rename = "Hash")]
    pub hash: String,
}

/// The `Hash` of the last JSON object in an `/api/v0/add` response body.
///
/// `add` may answer with newline-delimited JSON; the last object is the root
/// entry, which is the one that names what was added.
fn last_add_hash(body: &str) -> Result<String> {
    let mut last: Option<AddResponse> = None;
    for line in body.lines().map(str::trim).filter(|l| !l.is_empty()) {
        let parsed: AddResponse = serde_json::from_str(line)?;
        last = Some(parsed);
    }
    match last {
        Some(add) => Ok(add.hash),
        None => anyhow::bail!("IPFS add returned no JSON objects"),
    }
}

impl IpfsClient {
    pub fn new(api_base: String) -> Self {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .connect_timeout(std::time::Duration::from_secs(10))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .unwrap_or_else(|_| Client::new());
        let stream_client = reqwest::Client::builder()
            .read_timeout(STREAM_READ_TIMEOUT)
            .connect_timeout(std::time::Duration::from_secs(10))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .unwrap_or_else(|_| Client::new());
        Self {
            client,
            stream_client,
            api_base,
        }
    }

    pub async fn add_path(&self, path: &str) -> Result<String> {
        let url = format!("{}/api/v0/add?recursive=true&pin=true", self.api_base);

        // For now we only support publishing single files (e.g. pre-built
        // nar archives), not whole directories. Attempting to read a Guix
        // store directory directly would fail with `tokio::fs::read`.
        let mut file = tokio::fs::File::open(path).await?;
        let meta = file.metadata().await?;
        if meta.is_dir() {
            anyhow::bail!("publishing directories is not supported; expected a file path");
        }

        use tokio::io::AsyncReadExt;
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes).await?;
        let part = reqwest::multipart::Part::bytes(bytes);
        let form = reqwest::multipart::Form::new().part("file", part.file_name("data"));

        let resp = self
            .client
            .post(&url)
            .multipart(form)
            .send()
            .await?
            .error_for_status()?;

        // `/api/v0/add` may return newline-delimited JSON when adding
        // directories or multiple files. We take the last JSON object,
        // which corresponds to the root entry containing the directory hash.
        let body = resp.text().await?;
        let mut last: Option<AddResponse> = None;
        for line in body.lines().map(str::trim).filter(|l| !l.is_empty()) {
            let parsed: AddResponse = serde_json::from_str(line)?;
            last = Some(parsed);
        }

        match last {
            Some(add) => Ok(add.hash),
            None => anyhow::bail!("IPFS add returned no JSON objects"),
        }
    }

    pub async fn add_bytes(&self, data: &[u8]) -> Result<String> {
        let url = format!("{}/api/v0/add?pin=true", self.api_base);
        let part = reqwest::multipart::Part::bytes(data.to_vec());
        let form = reqwest::multipart::Form::new().part("file", part.file_name("data"));

        let resp = self
            .client
            .post(&url)
            .multipart(form)
            .send()
            .await?
            .error_for_status()?;

        let body = resp.text().await?;
        let mut last: Option<AddResponse> = None;
        for line in body.lines().map(str::trim).filter(|l| !l.is_empty()) {
            let parsed: AddResponse = serde_json::from_str(line)?;
            last = Some(parsed);
        }

        match last {
            Some(add) => Ok(add.hash),
            None => anyhow::bail!("IPFS add returned no JSON objects"),
        }
    }

    /// Adds the file at `path` by streaming it, so publishing an object never
    /// requires holding it in memory.
    ///
    /// The multipart body is a `wrap_stream` over the open file with a declared
    /// length, so the request carries a real `Content-Length` and the daemon on
    /// the other end sees exactly the same bytes `add_bytes` would have sent.
    /// [`IpfsClient::add_bytes`] stays for the small callers — feeds,
    /// manifests, snapshots — where a `Vec` is already in hand.
    pub async fn add_file(&self, path: &std::path::Path) -> Result<String> {
        let url = format!("{}/api/v0/add?pin=true", self.api_base);

        let file = tokio::fs::File::open(path)
            .await
            .with_context(|| format!("opening {} to add to IPFS", path.display()))?;
        let meta = file.metadata().await?;
        if meta.is_dir() {
            anyhow::bail!("publishing directories is not supported; expected a file path");
        }
        let len = meta.len();

        let body = reqwest::Body::wrap_stream(tokio_util::io::ReaderStream::new(file));
        let part = reqwest::multipart::Part::stream_with_length(body, len).file_name("data");
        let form = reqwest::multipart::Form::new().part("file", part);

        let resp = self
            .stream_client
            .post(&url)
            .multipart(form)
            .send()
            .await?
            .error_for_status()?;

        let body = resp.text().await?;
        last_add_hash(&body)
    }

    /// Recursively adds a directory tree to IPFS as a native UnixFS DAG hierarchy.
    pub async fn add_directory_tree(&self, root_dir: &std::path::Path) -> Result<String> {
        let url = format!("{}/api/v0/add?recursive=true&pin=true", self.api_base);

        let mut form = reqwest::multipart::Form::new();
        let mut stack = vec![root_dir.to_path_buf()];
        let root_name = root_dir
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("root")
            .to_string();

        let mut part_index = 0usize;
        let mut added_any = false;
        while let Some(dir) = stack.pop() {
            let mut entries = tokio::fs::read_dir(&dir).await?;
            while let Some(entry) = entries.next_entry().await? {
                let file_type = entry.file_type().await?;
                let path = entry.path();
                if file_type.is_dir() {
                    stack.push(path);
                } else if file_type.is_file() || file_type.is_symlink() {
                    let rel_path = path.strip_prefix(root_dir).unwrap_or(&path);
                    let part_name = format!("{}/{}", root_name, rel_path.to_string_lossy());
                    let bytes = tokio::fs::read(&path).await?;
                    let part = reqwest::multipart::Part::bytes(bytes).file_name(part_name);
                    form = form.part(format!("file-{}", part_index), part);
                    part_index += 1;
                    added_any = true;
                }
            }
        }

        if !added_any {
            let part = reqwest::multipart::Part::bytes(vec![]).file_name(root_name);
            form = form.part("file-0", part);
        }

        let resp = self
            .client
            .post(&url)
            .multipart(form)
            .send()
            .await?
            .error_for_status()?;

        let body = resp.text().await?;
        last_add_hash(&body)
    }

    /// Fetches `cid` in full, refusing anything past [`MAX_CAT_BYTES`].
    ///
    /// The bound is the point of this method: every caller left on it — feed
    /// bodies, manifests, snapshot blobs — has no signed size to check against,
    /// so a constant ceiling is the only thing standing between a hostile
    /// endpoint and this process's memory. Nar payloads, which *do* carry a
    /// signed `NarSize`, go through [`IpfsClient::cat_stream`] instead.
    pub async fn cat(&self, cid: &str) -> Result<bytes::Bytes> {
        let url = format!("{}/api/v0/cat", self.api_base);
        let resp = self
            .client
            .post(&url)
            .query(&[("arg", cid)])
            .send()
            .await?
            .error_for_status()?;

        if let Some(len) = resp.content_length() {
            if len > MAX_CAT_BYTES {
                anyhow::bail!("IPFS cat response too large: {} > 10MB", len);
            }
        }

        // Also limit while streaming in case Content-Length is missing/spoofed
        use futures_util::StreamExt;
        let mut bytes = bytes::BytesMut::new();
        let mut stream = resp.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk?;
            if bytes.len() as u64 + chunk.len() as u64 > MAX_CAT_BYTES {
                anyhow::bail!("IPFS cat response exceeded 10MB limit during stream");
            }
            bytes.extend_from_slice(&chunk);
        }

        Ok(bytes.freeze())
    }

    /// Fetches `cid` as a stream of chunks, accumulating nothing.
    ///
    /// Returns the endpoint's declared `Content-Length` (if it declared one)
    /// alongside the body stream. **There is no size ceiling here**: this
    /// method is only sound for a caller that already knows how many bytes it
    /// is owed and stops the stream itself. In this codebase that caller is the
    /// nar serving path, whose bound is the signed `NarSize`. Anything without
    /// such a record must use [`IpfsClient::cat`].
    /// The transport error is flattened to [`std::io::Error`] so that callers
    /// do not have to name `reqwest` in their own signatures — the HTTP client
    /// this component happens to use is not part of its interface.
    pub async fn cat_stream(
        &self,
        cid: &str,
    ) -> Result<(
        Option<u64>,
        impl futures_util::Stream<Item = std::io::Result<bytes::Bytes>> + Send,
    )> {
        use futures_util::TryStreamExt;

        let url = format!("{}/api/v0/cat", self.api_base);
        let resp = self
            .stream_client
            .post(&url)
            .query(&[("arg", cid)])
            .send()
            .await?
            .error_for_status()?;

        let declared = resp.content_length();
        let stream = resp.bytes_stream().map_err(std::io::Error::other);
        Ok((declared, stream))
    }

    /// Compares `sha256(bytes)` against the multihash inside `cid_str`.
    ///
    /// # This is only sound for single-block objects
    ///
    /// A CID's multihash is the hash of the *encoded DAG node*, not of the file
    /// content. For a small add, kubo produces one raw/dag-pb leaf whose digest
    /// happens to equal the content digest, and this check works. Past the
    /// chunker's block size (256 KiB by default) an add becomes a tree of
    /// blocks under a root node listing its children, and the root's digest is
    /// a hash of that listing — so `sha256(content)` cannot match it, and this
    /// function would reject the object's own honest bytes.
    ///
    /// It is therefore *not* applied to the streamed nar path, where the signed
    /// `NarHash`/`NarSize` record is the authoritative gate and does not have
    /// this ceiling. Kept here, unchanged, for callers holding a single-block
    /// object in memory.
    pub fn verify_bytes_against_cid(bytes: &[u8], cid_str: &str) -> Result<()> {
        let (_, cid_bytes) = multibase::decode(cid_str).context("invalid multibase CID")?;
        // Basic CIDv0 / CIDv1 parse. We just need to find the multihash.
        // CIDv0 is exactly 34 bytes, starts with 0x12 0x20.
        // CIDv1 starts with version (0x01), codec, then multihash.
        let multihash_bytes =
            if cid_bytes.len() == 34 && cid_bytes[0] == 0x12 && cid_bytes[1] == 0x20 {
                &cid_bytes[2..]
            } else {
                // simplified for v1: skip version and codec.
                // In a real impl we'd use a cid crate. Since we only use sha256 via IPFS default,
                // we'll just check if it ends with the 32-byte hash.
                // IPFS add uses sha2-256 (0x12 0x20).
                let pos = cid_bytes.windows(2).position(|w| w == [0x12, 0x20]);
                if let Some(p) = pos {
                    &cid_bytes[p + 2..p + 34]
                } else {
                    anyhow::bail!("Unsupported CID format or non-sha256 multihash");
                }
            };

        let mut hasher = Sha256::new();
        hasher.update(bytes);
        let hash = hasher.finalize();

        if hash.as_slice() != multihash_bytes {
            anyhow::bail!("Content does not match CID");
        }
        Ok(())
    }
    pub async fn pin_add(&self, cid: &str) -> Result<()> {
        let url = format!("{}/api/v0/pin/add", self.api_base);
        self.client
            .post(&url)
            .query(&[("arg", cid)])
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }

    pub async fn pin_rm(&self, cid: &str) -> Result<()> {
        let url = format!("{}/api/v0/pin/rm", self.api_base);
        self.client
            .post(&url)
            .query(&[("arg", cid)])
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }

    /// Publishes raw bytes to an IPFS PubSub topic.
    pub async fn pubsub_pub(&self, topic: &str, data: &[u8]) -> Result<()> {
        let url = format!("{}/api/v0/pubsub/pub", self.api_base);
        let part = reqwest::multipart::Part::bytes(data.to_vec());
        let form = reqwest::multipart::Form::new().part("file", part.file_name("data"));
        self.client
            .post(&url)
            .query(&[("arg", topic)])
            .multipart(form)
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }

    /// Subscribes to an IPFS PubSub topic, returning a streaming HTTP response.
    pub async fn pubsub_sub(&self, topic: &str) -> Result<reqwest::Response> {
        let url = format!("{}/api/v0/pubsub/sub", self.api_base);
        let resp = self
            .stream_client
            .post(&url)
            .query(&[("arg", topic)])
            .send()
            .await?
            .error_for_status()?;
        Ok(resp)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_verify_bytes_against_cid_success() {
        let data = b"hello";
        let mut hasher = Sha256::new();
        hasher.update(data);
        let hash = hasher.finalize();
        let mut raw = vec![0x12, 0x20];
        raw.extend_from_slice(&hash);
        let cid_str = multibase::encode(multibase::Base::Base58Btc, &raw);
        assert!(IpfsClient::verify_bytes_against_cid(data, &cid_str).is_ok());
    }

    #[tokio::test]
    async fn test_pubsub_pub_and_sub() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else {
                    break;
                };
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 4096];
                    let n = socket.read(&mut buf).await.unwrap_or(0);
                    let req = String::from_utf8_lossy(&buf[..n]);

                    if req.contains("POST /api/v0/pubsub/pub?arg=test.topic") {
                        let resp = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
                        let _ = socket.write_all(resp.as_bytes()).await;
                    } else if req.contains("POST /api/v0/pubsub/sub?arg=test.topic") {
                        let body = "{\"data\":\"aGVsbG8=\"}\n";
                        let resp = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
                            body.len(),
                            body
                        );
                        let _ = socket.write_all(resp.as_bytes()).await;
                    } else {
                        let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
                        let _ = socket.write_all(resp.as_bytes()).await;
                    }
                });
            }
        });

        let client = IpfsClient::new(format!("http://{}", addr));
        let pub_res = client.pubsub_pub("test.topic", b"hello").await;
        assert!(pub_res.is_ok(), "pubsub_pub should succeed: {:?}", pub_res);

        let sub_res = client.pubsub_sub("test.topic").await;
        assert!(sub_res.is_ok(), "pubsub_sub should succeed: {:?}", sub_res);
        let text = sub_res.unwrap().text().await.unwrap();
        assert!(text.contains("\"data\":\"aGVsbG8=\""));
    }
}
