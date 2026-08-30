use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use ed25519_dalek::pkcs8::{DecodePrivateKey, DecodePublicKey, EncodePublicKey};
use ed25519_dalek::{Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use std::fmt;

/// Attenuable capabilities for store path operations.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct VouchCapabilities {
    /// Allowed store path prefixes (e.g. `["/gnu/store/"]`)
    pub path_prefixes: Vec<String>,
    /// Maximum downstream delegation depth permitted (0 = leaf, cannot delegate further)
    pub max_depth: u32,
    /// Vouch weight / stake score (e.g. 1..100)
    pub stake_score: u32,
}

/// The inner payload of a delegation token.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct VouchPayload {
    pub issuer: String,
    pub subject: String,
    pub parent_token: Option<String>,
    pub issued_at: u64,
    pub expires_at: u64,
    pub capabilities: VouchCapabilities,
}

impl VouchPayload {
    /// Canonical UTF-8 byte serialization of the payload for signing and verification.
    pub fn canonical_bytes(&self) -> Vec<u8> {
        let mut sorted_prefixes = self.capabilities.path_prefixes.clone();
        sorted_prefixes.sort();
        let parent_str = self.parent_token.as_deref().unwrap_or("");
        format!(
            "issuer:{}\nsubject:{}\nparent_token:{}\nissued_at:{}\nexpires_at:{}\nmax_depth:{}\nstake_score:{}\npath_prefixes:{}\n",
            self.issuer.trim(),
            self.subject.trim(),
            parent_str.trim(),
            self.issued_at,
            self.expires_at,
            self.capabilities.max_depth,
            self.capabilities.stake_score,
            sorted_prefixes.join(",")
        )
        .into_bytes()
    }
}

/// A signed capability delegation token.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct VouchToken {
    pub payload: VouchPayload,
    pub signature: String,
}

/// Errors occurring during vouch token creation, inspection, or chain verification.
#[derive(Debug, PartialEq, Eq, Clone)]
pub enum VouchError {
    EmptyChain,
    RootMismatch {
        expected: String,
        actual: String,
    },
    SubjectMismatch {
        expected: String,
        actual: String,
    },
    BrokenLinkage {
        step: usize,
        expected_issuer: String,
        actual_issuer: String,
    },
    ParentTokenMismatch {
        step: usize,
    },
    DepthViolation {
        step: usize,
        parent_depth: u32,
        child_depth: u32,
    },
    StakeInflation {
        step: usize,
        parent_stake: u32,
        child_stake: u32,
    },
    ExpirationExtension {
        step: usize,
        parent_expires: u64,
        child_expires: u64,
    },
    PrefixExpansion {
        step: usize,
        prefix: String,
    },
    Expired {
        step: Option<usize>,
        expires_at: u64,
        now: u64,
    },
    BadSignature {
        step: Option<usize>,
    },
    KeyError(String),
    Malformed(String),
}

impl fmt::Display for VouchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyChain => write!(f, "Vouch chain is empty"),
            Self::RootMismatch { expected, actual } => {
                write!(
                    f,
                    "Root public key mismatch: expected {}, got {}",
                    expected, actual
                )
            }
            Self::SubjectMismatch { expected, actual } => {
                write!(
                    f,
                    "Target subject mismatch: expected {}, got {}",
                    expected, actual
                )
            }
            Self::BrokenLinkage {
                step,
                expected_issuer,
                actual_issuer,
            } => {
                write!(
                    f,
                    "Broken chain linkage at step {}: expected issuer {}, got {}",
                    step, expected_issuer, actual_issuer
                )
            }
            Self::ParentTokenMismatch { step } => {
                write!(f, "Parent token reference mismatch at step {}", step)
            }
            Self::DepthViolation {
                step,
                parent_depth,
                child_depth,
            } => {
                write!(
                    f,
                    "Depth attenuation violation at step {}: child depth ({}) must be strictly less than parent depth ({})",
                    step, child_depth, parent_depth
                )
            }
            Self::StakeInflation {
                step,
                parent_stake,
                child_stake,
            } => {
                write!(
                    f,
                    "Stake score inflation violation at step {}: child stake ({}) exceeds parent stake ({})",
                    step, child_stake, parent_stake
                )
            }
            Self::ExpirationExtension {
                step,
                parent_expires,
                child_expires,
            } => {
                write!(
                    f,
                    "Expiration extension violation at step {}: child expires at {} after parent {}",
                    step, child_expires, parent_expires
                )
            }
            Self::PrefixExpansion { step, prefix } => {
                write!(
                    f,
                    "Path prefix expansion violation at step {}: prefix '{}' is not permitted by parent",
                    step, prefix
                )
            }
            Self::Expired {
                step,
                expires_at,
                now,
            } => match step {
                Some(s) => write!(
                    f,
                    "Token expired at step {}: expires_at ({}) < now ({})",
                    s, expires_at, now
                ),
                None => write!(
                    f,
                    "Token expired: expires_at ({}) < now ({})",
                    expires_at, now
                ),
            },
            Self::BadSignature { step } => match step {
                Some(s) => write!(f, "Bad signature at step {}", s),
                None => write!(f, "Bad signature"),
            },
            Self::KeyError(msg) => write!(f, "Key error: {}", msg),
            Self::Malformed(msg) => write!(f, "Malformed vouch token: {}", msg),
        }
    }
}

impl std::error::Error for VouchError {}

fn hex_to_bytes(hex: &str) -> Result<Vec<u8>, ()> {
    if hex.len() % 2 != 0 {
        return Err(());
    }
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).map_err(|_| ()))
        .collect()
}

/// Parses an Ed25519 signing private key from PKCS#8 PEM, base64, or hex.
pub fn parse_signing_key(key_str: &str) -> Result<SigningKey, VouchError> {
    let trimmed = key_str.trim();
    if let Ok(key) = SigningKey::from_pkcs8_pem(trimmed) {
        return Ok(key);
    }
    if let Ok(bytes) = BASE64.decode(trimmed) {
        if bytes.len() == 32 {
            let mut arr = [0u8; 32];
            arr.copy_from_slice(&bytes);
            return Ok(SigningKey::from_bytes(&arr));
        }
        if let Ok(key) = SigningKey::from_pkcs8_der(&bytes) {
            return Ok(key);
        }
    }
    if trimmed.len() == 64 {
        if let Ok(bytes) = hex_to_bytes(trimmed) {
            let mut arr = [0u8; 32];
            arr.copy_from_slice(&bytes);
            return Ok(SigningKey::from_bytes(&arr));
        }
    }
    Err(VouchError::KeyError(
        "Failed to parse private key (expected Ed25519 PKCS#8 PEM)".to_string(),
    ))
}

/// Parses an Ed25519 public verifying key from SPKI PEM, raw base64, or hex.
pub fn parse_verifying_key(key_str: &str) -> Result<VerifyingKey, VouchError> {
    let trimmed = key_str.trim();
    if let Ok(key) = VerifyingKey::from_public_key_pem(trimmed) {
        return Ok(key);
    }
    if let Ok(bytes) = BASE64.decode(trimmed) {
        if bytes.len() == 32 {
            let mut arr = [0u8; 32];
            arr.copy_from_slice(&bytes);
            if let Ok(key) = VerifyingKey::from_bytes(&arr) {
                return Ok(key);
            }
        }
        if let Ok(key) = VerifyingKey::from_public_key_der(&bytes) {
            return Ok(key);
        }
    }
    if trimmed.len() == 64 {
        if let Ok(bytes) = hex_to_bytes(trimmed) {
            let mut arr = [0u8; 32];
            arr.copy_from_slice(&bytes);
            if let Ok(key) = VerifyingKey::from_bytes(&arr) {
                return Ok(key);
            }
        }
    }
    Err(VouchError::KeyError(
        "Failed to parse public key (expected Ed25519 SPKI PEM)".to_string(),
    ))
}

/// Checks whether two public key strings represent the same Ed25519 key.
pub fn keys_equal(k1: &str, k2: &str) -> bool {
    if k1.trim() == k2.trim() {
        return true;
    }
    match (parse_verifying_key(k1), parse_verifying_key(k2)) {
        (Ok(v1), Ok(v2)) => v1.as_bytes() == v2.as_bytes(),
        _ => false,
    }
}

/// Mints a signed `VouchToken` using the issuer's private key.
pub fn mint_vouch_token(
    issuer_private_key_pem: &str,
    subject_public_key: &str,
    parent_token: Option<String>,
    issued_at: u64,
    expires_at: u64,
    capabilities: VouchCapabilities,
) -> Result<VouchToken, VouchError> {
    let signing_key = parse_signing_key(issuer_private_key_pem)?;
    let issuer_pem = signing_key
        .verifying_key()
        .to_public_key_pem(ed25519_dalek::pkcs8::spki::der::pem::LineEnding::LF)
        .map_err(|e| VouchError::KeyError(format!("Failed to encode issuer public key: {}", e)))?;

    // Verify that subject parses as a valid public key
    let _ = parse_verifying_key(subject_public_key)?;

    let payload = VouchPayload {
        issuer: issuer_pem.trim().to_string(),
        subject: subject_public_key.trim().to_string(),
        parent_token,
        issued_at,
        expires_at,
        capabilities,
    };

    let canonical = payload.canonical_bytes();
    let signature = signing_key.sign(&canonical);
    let sig_base64 = BASE64.encode(signature.to_bytes());

    Ok(VouchToken {
        payload,
        signature: sig_base64,
    })
}

/// Signs an existing `VouchPayload` using the issuer's private key.
pub fn sign_vouch_payload(
    payload: VouchPayload,
    issuer_private_key_pem: &str,
) -> Result<VouchToken, VouchError> {
    let signing_key = parse_signing_key(issuer_private_key_pem)?;
    let canonical = payload.canonical_bytes();
    let signature = signing_key.sign(&canonical);
    let sig_base64 = BASE64.encode(signature.to_bytes());
    Ok(VouchToken {
        payload,
        signature: sig_base64,
    })
}

/// Verifies a single delegation token's signature and expiration against `now`.
pub fn verify_vouch_token(token: &VouchToken, now: u64) -> Result<(), VouchError> {
    if token.payload.expires_at < now {
        return Err(VouchError::Expired {
            step: None,
            expires_at: token.payload.expires_at,
            now,
        });
    }

    let verifying_key = parse_verifying_key(&token.payload.issuer)?;

    let sig_bytes = BASE64
        .decode(&token.signature)
        .map_err(|_| VouchError::Malformed("Invalid base64 in token signature".to_string()))?;

    if sig_bytes.len() != 64 {
        return Err(VouchError::Malformed(
            "Invalid signature length (must be 64 bytes)".to_string(),
        ));
    }

    let signature = ed25519_dalek::Signature::from_slice(&sig_bytes)
        .map_err(|_| VouchError::Malformed("Invalid ed25519 signature bytes".to_string()))?;

    let canonical = token.payload.canonical_bytes();
    verifying_key
        .verify(&canonical, &signature)
        .map_err(|_| VouchError::BadSignature { step: None })?;

    Ok(())
}

/// Verifies a delegation chain rooted at `root_pubkey` down to an optional `target_subject`,
/// enforcing strict cryptographic linkage and capability attenuation at every hop.
pub fn verify_vouch_chain(
    root_pubkey: &str,
    chain: &[VouchToken],
    target_subject: Option<&str>,
    now: u64,
) -> Result<VouchCapabilities, VouchError> {
    if chain.is_empty() {
        return Err(VouchError::EmptyChain);
    }

    // 1. Root key verification
    if !keys_equal(&chain[0].payload.issuer, root_pubkey) {
        return Err(VouchError::RootMismatch {
            expected: root_pubkey.to_string(),
            actual: chain[0].payload.issuer.clone(),
        });
    }

    // 2. Cryptographic signature and expiration checks for each token
    for (i, token) in chain.iter().enumerate() {
        if token.payload.expires_at < now {
            return Err(VouchError::Expired {
                step: Some(i),
                expires_at: token.payload.expires_at,
                now,
            });
        }
        let verifying_key = parse_verifying_key(&token.payload.issuer)?;
        let sig_bytes = BASE64.decode(&token.signature).map_err(|_| {
            VouchError::Malformed(format!("Invalid base64 in token signature at step {}", i))
        })?;
        if sig_bytes.len() != 64 {
            return Err(VouchError::Malformed(format!(
                "Invalid signature length at step {}",
                i
            )));
        }
        let signature = ed25519_dalek::Signature::from_slice(&sig_bytes).map_err(|_| {
            VouchError::Malformed(format!("Invalid ed25519 signature bytes at step {}", i))
        })?;
        let canonical = token.payload.canonical_bytes();
        verifying_key
            .verify(&canonical, &signature)
            .map_err(|_| VouchError::BadSignature { step: Some(i) })?;
    }

    // 3. Linkage and strict attenuation checks
    for i in 1..chain.len() {
        let parent = &chain[i - 1];
        let child = &chain[i];

        // Unbroken chain linkage
        if !keys_equal(&child.payload.issuer, &parent.payload.subject) {
            return Err(VouchError::BrokenLinkage {
                step: i,
                expected_issuer: parent.payload.subject.clone(),
                actual_issuer: child.payload.issuer.clone(),
            });
        }

        // Parent token reference linkage
        if let Some(ref parent_ref) = child.payload.parent_token {
            if parent_ref.trim() != parent.signature.trim() {
                return Err(VouchError::ParentTokenMismatch { step: i });
            }
        }

        // Strict attenuation: delegation depth
        if child.payload.capabilities.max_depth >= parent.payload.capabilities.max_depth {
            return Err(VouchError::DepthViolation {
                step: i,
                parent_depth: parent.payload.capabilities.max_depth,
                child_depth: child.payload.capabilities.max_depth,
            });
        }

        // Strict attenuation: stake score
        if child.payload.capabilities.stake_score > parent.payload.capabilities.stake_score {
            return Err(VouchError::StakeInflation {
                step: i,
                parent_stake: parent.payload.capabilities.stake_score,
                child_stake: child.payload.capabilities.stake_score,
            });
        }

        // Strict attenuation: expiration timestamp
        if child.payload.expires_at > parent.payload.expires_at {
            return Err(VouchError::ExpirationExtension {
                step: i,
                parent_expires: parent.payload.expires_at,
                child_expires: child.payload.expires_at,
            });
        }

        // Strict attenuation: path prefixes
        for child_prefix in &child.payload.capabilities.path_prefixes {
            let allowed = parent
                .payload
                .capabilities
                .path_prefixes
                .iter()
                .any(|p_prefix| child_prefix.starts_with(p_prefix));
            if !allowed {
                return Err(VouchError::PrefixExpansion {
                    step: i,
                    prefix: child_prefix.clone(),
                });
            }
        }
    }

    // 4. Target subject verification
    if let Some(target) = target_subject {
        let last_token = chain.last().unwrap();
        if !keys_equal(&last_token.payload.subject, target) {
            return Err(VouchError::SubjectMismatch {
                expected: target.to_string(),
                actual: last_token.payload.subject.clone(),
            });
        }
    }

    Ok(chain.last().unwrap().payload.capabilities.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::pkcs8::spki::der::pem::LineEnding;
    use ed25519_dalek::pkcs8::EncodePrivateKey;
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
    fn test_mint_and_verify_single_token() {
        let (root_sec, _root_pub) = generate_keypair();
        let (_sub_sec, sub_pub) = generate_keypair();

        let caps = VouchCapabilities {
            path_prefixes: vec!["/gnu/store/".to_string()],
            max_depth: 2,
            stake_score: 80,
        };

        let now = 1000;
        let token =
            mint_vouch_token(&root_sec, &sub_pub, None, now, now + 3600, caps.clone()).unwrap();

        assert_eq!(token.payload.subject, sub_pub.trim());
        assert!(verify_vouch_token(&token, now).is_ok());
        assert!(verify_vouch_token(&token, now + 3500).is_ok());

        // Expired check
        let err = verify_vouch_token(&token, now + 4000).unwrap_err();
        match err {
            VouchError::Expired {
                expires_at, now: n, ..
            } => {
                assert_eq!(expires_at, now + 3600);
                assert_eq!(n, now + 4000);
            }
            other => panic!("expected Expired, got {:?}", other),
        }
    }

    #[test]
    fn test_multi_hop_chain_linkage_and_target_subject() {
        let (root_sec, root_pub) = generate_keypair();
        let (a_sec, a_pub) = generate_keypair();
        let (b_sec, b_pub) = generate_keypair();
        let (_c_sec, c_pub) = generate_keypair();

        let now = 1000;

        // Root -> A
        let t1 = mint_vouch_token(
            &root_sec,
            &a_pub,
            None,
            now,
            now + 5000,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/".to_string()],
                max_depth: 3,
                stake_score: 100,
            },
        )
        .unwrap();

        // A -> B
        let t2 = mint_vouch_token(
            &a_sec,
            &b_pub,
            Some(t1.signature.clone()),
            now,
            now + 4000,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/".to_string()],
                max_depth: 2,
                stake_score: 80,
            },
        )
        .unwrap();

        // B -> C
        let t3 = mint_vouch_token(
            &b_sec,
            &c_pub,
            Some(t2.signature.clone()),
            now,
            now + 3000,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/abc-".to_string()],
                max_depth: 1,
                stake_score: 50,
            },
        )
        .unwrap();

        let chain = vec![t1, t2, t3];

        let effective = verify_vouch_chain(&root_pub, &chain, Some(&c_pub), now).unwrap();
        assert_eq!(effective.max_depth, 1);
        assert_eq!(effective.stake_score, 50);
        assert_eq!(effective.path_prefixes, vec!["/gnu/store/abc-".to_string()]);

        // Wrong root key
        let (_wrong_sec, wrong_pub) = generate_keypair();
        assert!(matches!(
            verify_vouch_chain(&wrong_pub, &chain, Some(&c_pub), now),
            Err(VouchError::RootMismatch { .. })
        ));

        // Wrong target subject
        assert!(matches!(
            verify_vouch_chain(&root_pub, &chain, Some(&b_pub), now),
            Err(VouchError::SubjectMismatch { .. })
        ));
    }

    #[test]
    fn test_attenuation_depth_violation() {
        let (root_sec, root_pub) = generate_keypair();
        let (a_sec, a_pub) = generate_keypair();
        let (_b_sec, b_pub) = generate_keypair();

        let now = 1000;
        let t1 = mint_vouch_token(
            &root_sec,
            &a_pub,
            None,
            now,
            now + 5000,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/".to_string()],
                max_depth: 1,
                stake_score: 100,
            },
        )
        .unwrap();

        // Child depth 2 >= parent depth 1
        let t2 = mint_vouch_token(
            &a_sec,
            &b_pub,
            Some(t1.signature.clone()),
            now,
            now + 4000,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/".to_string()],
                max_depth: 2,
                stake_score: 100,
            },
        )
        .unwrap();

        let err = verify_vouch_chain(&root_pub, &[t1, t2], None, now).unwrap_err();
        assert!(matches!(
            err,
            VouchError::DepthViolation {
                step: 1,
                parent_depth: 1,
                child_depth: 2
            }
        ));
    }

    #[test]
    fn test_attenuation_stake_inflation() {
        let (root_sec, root_pub) = generate_keypair();
        let (a_sec, a_pub) = generate_keypair();
        let (_b_sec, b_pub) = generate_keypair();

        let now = 1000;
        let t1 = mint_vouch_token(
            &root_sec,
            &a_pub,
            None,
            now,
            now + 5000,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/".to_string()],
                max_depth: 2,
                stake_score: 50,
            },
        )
        .unwrap();

        // Child stake 80 > parent stake 50
        let t2 = mint_vouch_token(
            &a_sec,
            &b_pub,
            Some(t1.signature.clone()),
            now,
            now + 4000,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/".to_string()],
                max_depth: 1,
                stake_score: 80,
            },
        )
        .unwrap();

        let err = verify_vouch_chain(&root_pub, &[t1, t2], None, now).unwrap_err();
        assert!(matches!(
            err,
            VouchError::StakeInflation {
                step: 1,
                parent_stake: 50,
                child_stake: 80
            }
        ));
    }

    #[test]
    fn test_attenuation_prefix_widening() {
        let (root_sec, root_pub) = generate_keypair();
        let (a_sec, a_pub) = generate_keypair();
        let (_b_sec, b_pub) = generate_keypair();

        let now = 1000;
        let t1 = mint_vouch_token(
            &root_sec,
            &a_pub,
            None,
            now,
            now + 5000,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/abc-".to_string()],
                max_depth: 2,
                stake_score: 100,
            },
        )
        .unwrap();

        // Child attempts to widen to "/gnu/store/"
        let t2 = mint_vouch_token(
            &a_sec,
            &b_pub,
            Some(t1.signature.clone()),
            now,
            now + 4000,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/".to_string()],
                max_depth: 1,
                stake_score: 100,
            },
        )
        .unwrap();

        let err = verify_vouch_chain(&root_pub, &[t1, t2], None, now).unwrap_err();
        assert!(matches!(err, VouchError::PrefixExpansion { step: 1, .. }));
    }

    #[test]
    fn test_attenuation_expiration_extension() {
        let (root_sec, root_pub) = generate_keypair();
        let (a_sec, a_pub) = generate_keypair();
        let (_b_sec, b_pub) = generate_keypair();

        let now = 1000;
        let t1 = mint_vouch_token(
            &root_sec,
            &a_pub,
            None,
            now,
            now + 2000,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/".to_string()],
                max_depth: 2,
                stake_score: 100,
            },
        )
        .unwrap();

        // Child extends expiration beyond parent (now + 3000 > now + 2000)
        let t2 = mint_vouch_token(
            &a_sec,
            &b_pub,
            Some(t1.signature.clone()),
            now,
            now + 3000,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/".to_string()],
                max_depth: 1,
                stake_score: 100,
            },
        )
        .unwrap();

        let err = verify_vouch_chain(&root_pub, &[t1, t2], None, now).unwrap_err();
        assert!(matches!(
            err,
            VouchError::ExpirationExtension {
                step: 1,
                parent_expires: 3000,
                child_expires: 4000
            }
        ));
    }

    #[test]
    fn test_tamper_resistance() {
        let (root_sec, root_pub) = generate_keypair();
        let (_a_sec, a_pub) = generate_keypair();

        let now = 1000;
        let mut t1 = mint_vouch_token(
            &root_sec,
            &a_pub,
            None,
            now,
            now + 5000,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/".to_string()],
                max_depth: 2,
                stake_score: 100,
            },
        )
        .unwrap();

        // Verify valid first
        assert!(verify_vouch_token(&t1, now).is_ok());

        // Tamper with stake score
        t1.payload.capabilities.stake_score = 99;
        assert!(matches!(
            verify_vouch_token(&t1, now),
            Err(VouchError::BadSignature { .. })
        ));
        assert!(matches!(
            verify_vouch_chain(&root_pub, &[t1.clone()], None, now),
            Err(VouchError::BadSignature { .. })
        ));

        // Tamper with subject
        t1.payload.capabilities.stake_score = 100;
        t1.payload.subject = "invalid-pubkey".to_string();
        assert!(verify_vouch_token(&t1, now).is_err());
    }

    #[test]
    fn test_parent_token_mismatch() {
        let (root_sec, root_pub) = generate_keypair();
        let (a_sec, a_pub) = generate_keypair();
        let (_b_sec, b_pub) = generate_keypair();

        let now = 1000;
        let t1 = mint_vouch_token(
            &root_sec,
            &a_pub,
            None,
            now,
            now + 5000,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/".to_string()],
                max_depth: 2,
                stake_score: 100,
            },
        )
        .unwrap();

        // Mismatched parent token reference
        let t2 = mint_vouch_token(
            &a_sec,
            &b_pub,
            Some("wrong-parent-signature".to_string()),
            now,
            now + 4000,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/".to_string()],
                max_depth: 1,
                stake_score: 100,
            },
        )
        .unwrap();

        let err = verify_vouch_chain(&root_pub, &[t1, t2], None, now).unwrap_err();
        assert!(matches!(err, VouchError::ParentTokenMismatch { step: 1 }));
    }
}
