use crate::vouch::parse_verifying_key;
use crate::{canonicalize_body, extract_signature};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use ed25519_dalek::{Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use std::fmt;

/// Type of objective cryptographic fraud proof.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum FraudProofType {
    HashMismatch {
        narinfo_body: String,
        signature: String,
        artifact_bytes_base64: String,
    },
    Equivocation {
        feed_entry_a: String,
        feed_entry_b: String,
    },
}

/// A self-contained, portable, objective cryptographic fraud proof.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct FraudProof {
    pub publisher_key: String,
    pub proof_type: FraudProofType,
    pub created_at: u64,
}

impl FraudProof {
    pub fn to_json(&self) -> String {
        match &self.proof_type {
            FraudProofType::HashMismatch {
                narinfo_body,
                signature,
                artifact_bytes_base64,
            } => {
                format!(
                    "{{\"publisher_key\":\"{}\",\"proof_type\":{{\"HashMismatch\":{{\"narinfo_body\":\"{}\",\"signature\":\"{}\",\"artifact_bytes_base64\":\"{}\"}}}},\"created_at\":{}}}",
                    escape_json(&self.publisher_key),
                    escape_json(narinfo_body),
                    escape_json(signature),
                    escape_json(artifact_bytes_base64),
                    self.created_at
                )
            }
            FraudProofType::Equivocation {
                feed_entry_a,
                feed_entry_b,
            } => {
                format!(
                    "{{\"publisher_key\":\"{}\",\"proof_type\":{{\"Equivocation\":{{\"feed_entry_a\":\"{}\",\"feed_entry_b\":\"{}\"}}}},\"created_at\":{}}}",
                    escape_json(&self.publisher_key),
                    escape_json(feed_entry_a),
                    escape_json(feed_entry_b),
                    self.created_at
                )
            }
        }
    }

    pub fn from_json(json_str: &str) -> Result<Self, String> {
        let pubkey = extract_json_field(json_str, "publisher_key")
            .ok_or_else(|| "Missing publisher_key in FraudProof JSON".to_string())?;

        let created_at = {
            let key = "\"created_at\"";
            let key_pos = json_str
                .find(key)
                .ok_or_else(|| "Missing created_at in FraudProof JSON".to_string())?;
            let after_key = &json_str[key_pos + key.len()..];
            let colon_pos = after_key
                .find(':')
                .ok_or_else(|| "Invalid JSON structure around created_at".to_string())?;
            let num_str = after_key[colon_pos + 1..].trim_start();
            let end_pos = num_str
                .find(|c: char| !c.is_ascii_digit())
                .unwrap_or(num_str.len());
            num_str[..end_pos]
                .parse::<u64>()
                .map_err(|e| format!("Invalid created_at: {}", e))?
        };

        if json_str.contains("\"HashMismatch\"") {
            let narinfo_body = extract_json_field(json_str, "narinfo_body")
                .ok_or_else(|| "Missing narinfo_body in HashMismatch JSON".to_string())?;
            let signature = extract_json_field(json_str, "signature")
                .ok_or_else(|| "Missing signature in HashMismatch JSON".to_string())?;
            let artifact_bytes_base64 = extract_json_field(json_str, "artifact_bytes_base64")
                .ok_or_else(|| "Missing artifact_bytes_base64 in HashMismatch JSON".to_string())?;

            Ok(FraudProof {
                publisher_key: pubkey,
                proof_type: FraudProofType::HashMismatch {
                    narinfo_body,
                    signature,
                    artifact_bytes_base64,
                },
                created_at,
            })
        } else if json_str.contains("\"Equivocation\"") {
            let feed_entry_a = extract_json_field(json_str, "feed_entry_a")
                .ok_or_else(|| "Missing feed_entry_a in Equivocation JSON".to_string())?;
            let feed_entry_b = extract_json_field(json_str, "feed_entry_b")
                .ok_or_else(|| "Missing feed_entry_b in Equivocation JSON".to_string())?;

            Ok(FraudProof {
                publisher_key: pubkey,
                proof_type: FraudProofType::Equivocation {
                    feed_entry_a,
                    feed_entry_b,
                },
                created_at,
            })
        } else {
            Err("Unknown proof_type in FraudProof JSON".to_string())
        }
    }
}

pub fn escape_json(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 16);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            other => out.push(other),
        }
    }
    out
}

/// Errors arising during fraud proof verification.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FraudError {
    NoFraudDetected,
    BadSignature(String),
    Malformed(String),
    KeyError(String),
}

impl fmt::Display for FraudError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoFraudDetected => {
                write!(
                    f,
                    "No fraud detected: artifact bytes or feed entries match signed assertions"
                )
            }
            Self::BadSignature(msg) => write!(f, "Bad signature: {}", msg),
            Self::Malformed(msg) => write!(f, "Malformed fraud proof: {}", msg),
            Self::KeyError(msg) => write!(f, "Key error: {}", msg),
        }
    }
}

impl std::error::Error for FraudError {}

/// Nix/Guix base32 alphabet (RFC 4648 without e, o, u, t).
const NIX_BASE32_ALPHABET: &[u8; 32] = b"0123456789abcdfghijklmnpqrsvwxyz";

/// Encodes bytes in the Nix/Guix base32 alphabet.
pub fn nix_base32_encode(bytes: &[u8]) -> String {
    if bytes.is_empty() {
        return String::new();
    }
    let len = (bytes.len() * 8 - 1) / 5 + 1;
    let mut out = String::with_capacity(len);
    for n in (0..len).rev() {
        let bit = n * 5;
        let byte_index = bit / 8;
        let bit_offset = bit % 8;
        let mut chunk = u16::from(bytes[byte_index]) >> bit_offset;
        if byte_index + 1 < bytes.len() {
            chunk |= u16::from(bytes[byte_index + 1]) << (8 - bit_offset);
        }
        out.push(NIX_BASE32_ALPHABET[(chunk & 0x1f) as usize] as char);
    }
    out
}

/// Computes SHA-256 digest of input bytes (FIPS 180-4 standard).
pub fn sha256_digest(data: &[u8]) -> [u8; 32] {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];

    let mut h0: u32 = 0x6a09e667;
    let mut h1: u32 = 0xbb67ae85;
    let mut h2: u32 = 0x3c6ef372;
    let mut h3: u32 = 0xa54ff53a;
    let mut h4: u32 = 0x510e527f;
    let mut h5: u32 = 0x9b05688c;
    let mut h6: u32 = 0x1f83d9ab;
    let mut h7: u32 = 0x5be0cd19;

    let bit_len = (data.len() as u64) * 8;
    let mut msg = data.to_vec();
    msg.push(0x80);
    while (msg.len() % 64) != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bit_len.to_be_bytes());

    for chunk in msg.chunks_exact(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                chunk[i * 4],
                chunk[i * 4 + 1],
                chunk[i * 4 + 2],
                chunk[i * 4 + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }

        let mut a = h0;
        let mut b = h1;
        let mut c = h2;
        let mut d = h3;
        let mut e = h4;
        let mut f = h5;
        let mut g = h6;
        let mut h = h7;

        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = h
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);

            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }

        h0 = h0.wrapping_add(a);
        h1 = h1.wrapping_add(b);
        h2 = h2.wrapping_add(c);
        h3 = h3.wrapping_add(d);
        h4 = h4.wrapping_add(e);
        h5 = h5.wrapping_add(f);
        h6 = h6.wrapping_add(g);
        h7 = h7.wrapping_add(h);
    }

    let mut out = [0u8; 32];
    out[0..4].copy_from_slice(&h0.to_be_bytes());
    out[4..8].copy_from_slice(&h1.to_be_bytes());
    out[8..12].copy_from_slice(&h2.to_be_bytes());
    out[12..16].copy_from_slice(&h3.to_be_bytes());
    out[16..20].copy_from_slice(&h4.to_be_bytes());
    out[20..24].copy_from_slice(&h5.to_be_bytes());
    out[24..28].copy_from_slice(&h6.to_be_bytes());
    out[28..32].copy_from_slice(&h7.to_be_bytes());
    out
}

/// Computes the Nix-base32 NarHash string (`sha256:<52-chars>`) for a byte slice.
pub fn compute_nar_hash(data: &[u8]) -> String {
    let digest = sha256_digest(data);
    format!("sha256:{}", nix_base32_encode(&digest))
}

fn parse_and_verify_signature(
    body: &str,
    sig_str: &str,
    verifying_key: &VerifyingKey,
) -> Result<(), FraudError> {
    let canonical = canonicalize_body(body).map_err(|e| FraudError::Malformed(e.to_string()))?;

    let sig_base64 = if sig_str.contains(';') {
        let parts: Vec<&str> = sig_str.split(';').collect();
        if parts.len() != 3 || parts[0] != "1" {
            return Err(FraudError::Malformed(
                "Invalid signature line format".to_string(),
            ));
        }
        parts[2]
    } else {
        sig_str.trim()
    };

    let sig_bytes = BASE64
        .decode(sig_base64)
        .map_err(|_| FraudError::Malformed("Invalid base64 in signature".to_string()))?;

    if sig_bytes.len() != 64 {
        return Err(FraudError::Malformed(format!(
            "Invalid signature length (expected 64 bytes, got {})",
            sig_bytes.len()
        )));
    }

    let signature = ed25519_dalek::Signature::from_slice(&sig_bytes)
        .map_err(|e| FraudError::Malformed(format!("Invalid ed25519 signature: {}", e)))?;

    verifying_key
        .verify(canonical.as_bytes(), &signature)
        .map_err(|_| {
            FraudError::BadSignature(
                "Signature verification failed against publisher key".to_string(),
            )
        })?;

    Ok(())
}

fn extract_json_field(json_str: &str, field_name: &str) -> Option<String> {
    let key = format!("\"{}\"", field_name);
    let key_pos = json_str.find(&key)?;
    let after_key = &json_str[key_pos + key.len()..];
    let colon_pos = after_key.find(':')?;
    let after_colon = after_key[colon_pos + 1..].trim_start();
    if !after_colon.starts_with('"') {
        return None;
    }
    let chars = after_colon[1..].chars();
    let mut out = String::new();
    let mut escape = false;
    for c in chars {
        if escape {
            match c {
                '"' => out.push('"'),
                '\\' => out.push('\\'),
                '/' => out.push('/'),
                'b' => out.push('\x08'),
                'f' => out.push('\x0c'),
                'n' => out.push('\n'),
                'r' => out.push('\r'),
                't' => out.push('\t'),
                other => out.push(other),
            }
            escape = false;
        } else if c == '\\' {
            escape = true;
        } else if c == '"' {
            return Some(out);
        } else {
            out.push(c);
        }
    }
    None
}

fn parse_and_verify_feed_entry(
    entry_str: &str,
    verifying_key: &VerifyingKey,
) -> Result<(String, u64, String), FraudError> {
    let trimmed = entry_str.trim();

    let (narinfo_text, explicit_cid) = if trimmed.starts_with('{') {
        let narinfo = extract_json_field(trimmed, "narinfo").unwrap_or_else(|| trimmed.to_string());
        let cid = extract_json_field(trimmed, "artifact_cid");
        (narinfo, cid)
    } else {
        (trimmed.to_string(), None)
    };

    let (body, sig) = extract_signature(&narinfo_text).map_err(|e| {
        FraudError::Malformed(format!(
            "Failed to extract signature from feed entry: {}",
            e
        ))
    })?;

    parse_and_verify_signature(&body, &sig, verifying_key)?;

    let mut store_path = None;
    let mut timestamp = None;
    let mut cid_from_body = None;

    for line in body.lines() {
        if let Some(rest) = line.strip_prefix("StorePath:") {
            store_path = Some(rest.trim().to_string());
        } else if let Some(rest) = line.strip_prefix("Timestamp:") {
            timestamp = rest.trim().parse::<u64>().ok();
        } else if let Some(rest) = line.strip_prefix("IpfsCid:") {
            cid_from_body = Some(rest.trim().to_string());
        } else if let Some(rest) = line.strip_prefix("URL:") {
            let url = rest.trim();
            if let Some(cid) = url.strip_prefix("nar/") {
                cid_from_body = Some(cid.trim().to_string());
            } else {
                cid_from_body = Some(url.to_string());
            }
        }
    }

    let store_path = store_path
        .ok_or_else(|| FraudError::Malformed("Missing StorePath in feed entry".to_string()))?;

    let timestamp = timestamp
        .ok_or_else(|| FraudError::Malformed("Missing Timestamp in feed entry".to_string()))?;

    let cid = explicit_cid
        .or(cid_from_body)
        .ok_or_else(|| FraudError::Malformed("Missing artifact CID in feed entry".to_string()))?;

    Ok((store_path, timestamp, cid))
}

/// Verifies a self-contained objective cryptographic fraud proof.
///
/// Returns `Ok(())` if true fraud is proven beyond mathematical doubt.
/// Returns `Err(FraudError::NoFraudDetected)` if the signed evidence is benign / non-fraudulent.
/// Returns `Err(FraudError::BadSignature)` or `Err(FraudError::Malformed)` if the evidence is invalid.
pub fn verify_fraud_proof(proof: &FraudProof) -> Result<(), FraudError> {
    let verifying_key = parse_verifying_key(&proof.publisher_key)
        .map_err(|e| FraudError::KeyError(e.to_string()))?;

    match &proof.proof_type {
        FraudProofType::HashMismatch {
            narinfo_body,
            signature,
            artifact_bytes_base64,
        } => {
            let (body, sig) =
                if narinfo_body.contains("Signature:") || narinfo_body.contains("Sig:") {
                    let (b, s) = extract_signature(narinfo_body)
                        .map_err(|e| FraudError::Malformed(e.to_string()))?;
                    let chosen_sig = if signature.trim().is_empty() {
                        s
                    } else {
                        signature.clone()
                    };
                    (b, chosen_sig)
                } else {
                    (narinfo_body.clone(), signature.clone())
                };

            parse_and_verify_signature(&body, &sig, &verifying_key)?;

            let mut signed_hash = None;
            for line in body.lines() {
                if let Some(rest) = line.strip_prefix("NarHash:") {
                    signed_hash = Some(rest.trim().to_string());
                    break;
                }
            }
            let signed_hash = signed_hash.ok_or_else(|| {
                FraudError::Malformed("Missing NarHash field in narinfo_body".to_string())
            })?;

            let artifact_bytes = BASE64.decode(artifact_bytes_base64.trim()).map_err(|_| {
                FraudError::Malformed("Invalid base64 in artifact_bytes".to_string())
            })?;

            let computed_hash = compute_nar_hash(&artifact_bytes);

            let norm_signed = if signed_hash.starts_with("sha256:") {
                signed_hash
            } else {
                format!("sha256:{}", signed_hash)
            };

            if computed_hash == norm_signed {
                return Err(FraudError::NoFraudDetected);
            }

            Ok(())
        }
        FraudProofType::Equivocation {
            feed_entry_a,
            feed_entry_b,
        } => {
            let (path_a, time_a, cid_a) =
                parse_and_verify_feed_entry(feed_entry_a, &verifying_key)?;
            let (path_b, time_b, cid_b) =
                parse_and_verify_feed_entry(feed_entry_b, &verifying_key)?;

            if path_a == path_b && time_a == time_b && cid_a != cid_b {
                Ok(())
            } else {
                Err(FraudError::NoFraudDetected)
            }
        }
    }
}

/// Helper to generate a `HashMismatch` fraud proof.
pub fn generate_hash_mismatch_proof(
    publisher_key: &str,
    narinfo_body: &str,
    signature: &str,
    artifact_bytes: &[u8],
) -> FraudProof {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    FraudProof {
        publisher_key: publisher_key.trim().to_string(),
        proof_type: FraudProofType::HashMismatch {
            narinfo_body: narinfo_body.to_string(),
            signature: signature.to_string(),
            artifact_bytes_base64: BASE64.encode(artifact_bytes),
        },
        created_at: now,
    }
}

/// Helper to generate an `Equivocation` fraud proof.
pub fn generate_equivocation_proof(
    publisher_key: &str,
    feed_entry_a: &str,
    feed_entry_b: &str,
) -> FraudProof {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    FraudProof {
        publisher_key: publisher_key.trim().to_string(),
        proof_type: FraudProofType::Equivocation {
            feed_entry_a: feed_entry_a.to_string(),
            feed_entry_b: feed_entry_b.to_string(),
        },
        created_at: now,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sign_narinfo;
    use ed25519_dalek::pkcs8::spki::der::pem::LineEnding;
    use ed25519_dalek::pkcs8::{EncodePrivateKey, EncodePublicKey};
    use ed25519_dalek::SigningKey;
    use rand::rngs::OsRng;
    use rand::RngCore;

    fn generate_keypair() -> (String, String) {
        let mut seed = [0u8; 32];
        OsRng.fill_bytes(&mut seed);
        let signing_key = SigningKey::from_bytes(&seed);
        let priv_pem = signing_key.to_pkcs8_pem(LineEnding::LF).unwrap();
        let pub_pem = signing_key
            .verifying_key()
            .to_public_key_pem(LineEnding::LF)
            .unwrap();
        (priv_pem.to_string(), pub_pem)
    }

    #[test]
    fn test_sha256_known_vectors() {
        assert_eq!(
            compute_nar_hash(b""),
            "sha256:0mdqa9w1p6cmli6976v4wi0sw9r4p5prkj7lzfd1877wk11c9c73"
        );
        let digest_abc = sha256_digest(b"abc");
        let hex_abc = digest_abc
            .iter()
            .map(|b| format!("{:02x}", b))
            .collect::<String>();
        assert_eq!(
            hex_abc,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn test_hash_mismatch_fraud_positive_and_negative() {
        let (priv_pem, pub_pem) = generate_keypair();
        let honest_bytes = b"honest package binary contents";
        let tampered_bytes = b"trojaned/corrupted binary contents";

        let honest_nar_hash = compute_nar_hash(honest_bytes);

        let narinfo_body = format!(
            "StorePath: /gnu/store/8009y4y5d4rhm796p02a7b8w6k2hvwq2-bash-5.1.16\n\
             NarHash: {}\n\
             NarSize: {}\n\
             References: \n",
            honest_nar_hash,
            honest_bytes.len()
        );

        let signature = sign_narinfo(&narinfo_body, &priv_pem, "alice.gnu").unwrap();

        // 1. Positive fraud vector: tampered bytes assert honest narinfo signature -> Fraud Verified!
        let fraud_proof =
            generate_hash_mismatch_proof(&pub_pem, &narinfo_body, &signature, tampered_bytes);
        assert_eq!(verify_fraud_proof(&fraud_proof), Ok(()));

        // 2. Negative vector: honest bytes matching signed hash -> NoFraudDetected
        let non_fraud_proof =
            generate_hash_mismatch_proof(&pub_pem, &narinfo_body, &signature, honest_bytes);
        assert_eq!(
            verify_fraud_proof(&non_fraud_proof),
            Err(FraudError::NoFraudDetected)
        );

        // 3. Negative vector: forged signature or wrong publisher key -> BadSignature
        let (_other_priv, other_pub) = generate_keypair();
        let forged_proof =
            generate_hash_mismatch_proof(&other_pub, &narinfo_body, &signature, tampered_bytes);
        assert!(matches!(
            verify_fraud_proof(&forged_proof),
            Err(FraudError::BadSignature(_))
        ));
    }

    #[test]
    fn test_equivocation_fraud_positive_and_negative() {
        let (priv_pem, pub_pem) = generate_keypair();
        let store_path = "/gnu/store/8009y4y5d4rhm796p02a7b8w6k2hvwq2-bash-5.1.16";
        let timestamp = 1700000000;

        let body_a = format!(
            "StorePath: {}\nIpfsCid: QmArtifactA111\nTimestamp: {}\nNarHash: sha256:1111\n",
            store_path, timestamp
        );
        let sig_a = sign_narinfo(&body_a, &priv_pem, "alice.gnu").unwrap();
        let feed_entry_a = format!("{}\nSignature: {}\n", body_a, sig_a);

        // Conflicting feed entry with different CID at the same store_path and timestamp
        let body_b = format!(
            "StorePath: {}\nIpfsCid: QmArtifactB222\nTimestamp: {}\nNarHash: sha256:2222\n",
            store_path, timestamp
        );
        let sig_b = sign_narinfo(&body_b, &priv_pem, "alice.gnu").unwrap();
        let feed_entry_b = format!("{}\nSignature: {}\n", body_b, sig_b);

        // 1. Positive fraud vector: two conflicting feeds -> Fraud Verified!
        let fraud_proof = generate_equivocation_proof(&pub_pem, &feed_entry_a, &feed_entry_b);
        assert_eq!(verify_fraud_proof(&fraud_proof), Ok(()));

        // Also test JSON wrapped feed entries
        fn escape_json(s: &str) -> String {
            s.replace('\\', "\\\\")
                .replace('"', "\\\"")
                .replace('\n', "\\n")
        }
        let json_entry_a = format!(
            "{{\"artifact_cid\":\"QmArtifactA111\",\"narinfo\":\"{}\"}}",
            escape_json(&feed_entry_a)
        );
        let json_entry_b = format!(
            "{{\"artifact_cid\":\"QmArtifactB222\",\"narinfo\":\"{}\"}}",
            escape_json(&feed_entry_b)
        );
        let json_fraud_proof = generate_equivocation_proof(&pub_pem, &json_entry_a, &json_entry_b);
        assert_eq!(verify_fraud_proof(&json_fraud_proof), Ok(()));

        // 2. Negative vector: identical feed entries -> NoFraudDetected
        let non_fraud_proof = generate_equivocation_proof(&pub_pem, &feed_entry_a, &feed_entry_a);
        assert_eq!(
            verify_fraud_proof(&non_fraud_proof),
            Err(FraudError::NoFraudDetected)
        );

        // 3. Negative vector: different timestamps (sequential versions, not equivocation) -> NoFraudDetected
        let body_c = format!(
            "StorePath: {}\nIpfsCid: QmArtifactB222\nTimestamp: {}\nNarHash: sha256:2222\n",
            store_path,
            timestamp + 100
        );
        let sig_c = sign_narinfo(&body_c, &priv_pem, "alice.gnu").unwrap();
        let feed_entry_c = format!("{}\nSignature: {}\n", body_c, sig_c);
        let non_equiv_proof = generate_equivocation_proof(&pub_pem, &feed_entry_a, &feed_entry_c);
        assert_eq!(
            verify_fraud_proof(&non_equiv_proof),
            Err(FraudError::NoFraudDetected)
        );

        // 4. Negative vector: bad signature -> BadSignature
        let (_other_priv, other_pub) = generate_keypair();
        let forged_proof = generate_equivocation_proof(&other_pub, &feed_entry_a, &feed_entry_b);
        assert!(matches!(
            verify_fraud_proof(&forged_proof),
            Err(FraudError::BadSignature(_))
        ));
    }
}
