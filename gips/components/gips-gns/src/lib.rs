use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GnsRecord {
    pub name: String,
    pub value: String,
}

#[derive(Clone)]
pub struct GnsClient {
    pub command: String,
}

fn is_valid_gns_name(name: &str) -> bool {
    if name.starts_with('-') || name.is_empty() || name.len() > 255 {
        return false;
    }
    name.chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_')
}

fn is_valid_cid(cid: &str) -> bool {
    if cid.starts_with('-') || cid.len() < 46 || cid.len() > 64 {
        return false;
    }
    cid.chars().all(|c| c.is_ascii_alphanumeric())
}

impl GnsClient {
    pub fn new(command: String) -> Self {
        Self { command }
    }

    pub async fn publish(&self, name: &str, value: &str, record_type: u32) -> Result<()> {
        if !is_valid_gns_name(name) {
            anyhow::bail!("invalid GNS name");
        }
        if !is_valid_cid(value) {
            anyhow::bail!("invalid CID value");
        }

        let mut child = Command::new(&self.command)
            .arg("record")
            .arg("-n")
            .arg("--")
            .arg(name)
            .arg("-t")
            .arg(record_type.to_string())
            .arg("-a")
            .arg("--")
            .arg(value)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;

        let status = tokio::time::timeout(Duration::from_secs(10), child.wait())
            .await
            .context("gnunet-gns publish timed out")??;

        if !status.success() {
            anyhow::bail!("failed to publish GNS record for {}", name);
        }

        Ok(())
    }

    pub async fn resolve(&self, name: &str, record_type: u32) -> Result<String> {
        if !is_valid_gns_name(name) {
            anyhow::bail!("invalid GNS name");
        }

        let child = Command::new(&self.command)
            .arg("-t")
            .arg(record_type.to_string())
            .arg("-u")
            .arg("--")
            .arg(name)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;

        let output = tokio::time::timeout(Duration::from_secs(10), child.wait_with_output())
            .await
            .context("gnunet-gns resolve timed out")??;

        if !output.status.success() {
            let stderr_str = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!("failed to resolve GNS record for {}: {}", name, stderr_str);
        }

        let stdout_str = String::from_utf8_lossy(&output.stdout);

        // Output from `gnunet-gns -u <name>` might contain multiple lines or formatting.
        // For the MVP, assume the primary text is the IPFS CID or manifest.
        // Often, it prints something like: `publisher.gnu: ...`
        // We will just return the trimmed output for now.
        // A robust parser would parse GNUnet's specific output format.
        let value = stdout_str.trim().to_string();
        if !is_valid_cid(&value) {
            anyhow::bail!("resolved invalid CID from GNS name {}: {}", name, value);
        }

        Ok(value)
    }

    /// Publishes an arbitrary text value (such as a public key) as a GNS TXT record (type 16).
    pub async fn publish_txt(&self, name: &str, value: &str) -> Result<()> {
        if !is_valid_gns_name(name) {
            anyhow::bail!("invalid GNS name");
        }
        if value.is_empty() {
            anyhow::bail!("empty TXT value");
        }

        let mut child = Command::new(&self.command)
            .arg("record")
            .arg("-n")
            .arg("--")
            .arg(name)
            .arg("-t")
            .arg("16")
            .arg("-a")
            .arg("--")
            .arg(value)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;

        let status = tokio::time::timeout(Duration::from_secs(10), child.wait())
            .await
            .context("gnunet-gns publish TXT timed out")??;

        if !status.success() {
            anyhow::bail!("failed to publish GNS TXT record for {}", name);
        }

        Ok(())
    }

    /// Resolves a GNS TXT record (type 16) returning its trimmed textual content.
    pub async fn resolve_txt(&self, name: &str) -> Result<String> {
        if !is_valid_gns_name(name) {
            anyhow::bail!("invalid GNS name");
        }

        let child = Command::new(&self.command)
            .arg("-t")
            .arg("16")
            .arg("-u")
            .arg("--")
            .arg(name)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;

        let output = tokio::time::timeout(Duration::from_secs(10), child.wait_with_output())
            .await
            .context("gnunet-gns resolve TXT timed out")??;

        if !output.status.success() {
            let stderr_str = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!(
                "failed to resolve GNS TXT record for {}: {}",
                name,
                stderr_str
            );
        }

        let stdout_str = String::from_utf8_lossy(&output.stdout);
        let value = stdout_str.trim().to_string();
        if value.is_empty() {
            anyhow::bail!("resolved empty TXT record from GNS name {}", name);
        }

        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gns_name_and_cid_validation() {
        assert!(is_valid_gns_name("alice.gnu"));
        assert!(is_valid_gns_name("alice-sub_1.gnu"));
        assert!(!is_valid_gns_name("-alice.gnu"));
        assert!(!is_valid_gns_name(""));

        assert!(is_valid_cid(
            "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"
        ));
        assert!(!is_valid_cid("-short"));
        assert!(!is_valid_cid(""));
    }
}
