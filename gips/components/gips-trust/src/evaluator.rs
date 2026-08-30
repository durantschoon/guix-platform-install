use crate::vouch::{keys_equal, verify_vouch_chain, VouchToken};
use serde::{Deserialize, Serialize};

/// The outcome of evaluating a publisher's effective trust against root anchors and vouch chains.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrustEvaluationResult {
    /// Effective stake/trust score (0..100)
    pub score: u32,
    /// Whether the publisher meets the minimum trust threshold and valid capabilities
    pub trusted: bool,
    /// Human-readable explanation of the trust evaluation decision
    pub reason: String,
}

/// Evaluator that determines the trustworthiness of arbitrary publishers by verifying
/// multi-hop capability delegation chains, applying reputation decay over delegation depth,
/// severing revoked vouchers via fraud proofs, and enforcing path prefix capability bounds.
#[derive(Clone, Debug)]
pub struct TrustEvaluator {
    /// Configured root trust anchors (PEM public keys)
    pub root_anchors: Vec<String>,
    /// Revocation blacklist from verified fraud proofs (PEM public keys or GNS names)
    pub revoked_keys: Vec<String>,
    /// Minimum trust score required to accept substitutes (default 50)
    pub min_trust_score: u32,
    /// Multiplicative decay factor per delegation hop (default 0.85)
    pub decay_factor: f64,
}

impl Default for TrustEvaluator {
    fn default() -> Self {
        Self::new()
    }
}

impl TrustEvaluator {
    pub fn new() -> Self {
        Self {
            root_anchors: Vec::new(),
            revoked_keys: Vec::new(),
            min_trust_score: 50,
            decay_factor: 0.85,
        }
    }

    pub fn with_roots(mut self, roots: Vec<String>) -> Self {
        self.root_anchors = roots;
        self
    }

    pub fn with_revocations(mut self, revocations: Vec<String>) -> Self {
        self.revoked_keys = revocations;
        self
    }

    pub fn with_min_score(mut self, min_score: u32) -> Self {
        self.min_trust_score = min_score;
        self
    }

    pub fn with_decay_factor(mut self, decay_factor: f64) -> Self {
        self.decay_factor = decay_factor;
        self
    }

    /// Checks whether a given key is present in the revocation blacklist.
    pub fn is_revoked(&self, key: &str) -> bool {
        let trimmed = key.trim();
        self.revoked_keys
            .iter()
            .any(|revoked| keys_equal(revoked, trimmed) || revoked.trim() == trimmed)
    }

    /// Checks whether a given key is a configured root anchor.
    pub fn is_root(&self, key: &str) -> bool {
        let trimmed = key.trim();
        self.root_anchors
            .iter()
            .any(|root| keys_equal(root, trimmed) || root.trim() == trimmed)
    }

    /// Evaluates a publisher against root anchors, fraud proof revocations, and an optional delegation chain.
    pub fn evaluate_publisher(
        &self,
        publisher_key: &str,
        store_path: &str,
        chain: &[VouchToken],
        now: u64,
    ) -> TrustEvaluationResult {
        let trimmed_pub = publisher_key.trim();

        // 1. Direct revocation check on target publisher
        if self.is_revoked(trimmed_pub) {
            return TrustEvaluationResult {
                score: 0,
                trusted: false,
                reason: format!("Publisher {} is revoked by active fraud proof", trimmed_pub),
            };
        }

        // 2. Direct root anchor check (when no chain is supplied or publisher is itself root)
        if chain.is_empty() {
            if self.is_root(trimmed_pub) {
                return TrustEvaluationResult {
                    score: 100,
                    trusted: true,
                    reason: "Publisher is a configured root trust anchor".to_string(),
                };
            }
            return TrustEvaluationResult {
                score: 0,
                trusted: false,
                reason: format!(
                    "Publisher {} is not a root trust anchor and no vouch chain was provided",
                    trimmed_pub
                ),
            };
        }

        // 3. Multi-hop vouch chain evaluation
        let root_issuer = &chain[0].payload.issuer;

        // Verify root anchor
        if !self.is_root(root_issuer) {
            return TrustEvaluationResult {
                score: 0,
                trusted: false,
                reason: format!(
                    "Root of vouch chain ({}) is not a configured root trust anchor",
                    root_issuer
                ),
            };
        }

        // Verify cryptographic validity & attenuation of the chain
        let effective_caps = match verify_vouch_chain(root_issuer, chain, Some(trimmed_pub), now) {
            Ok(caps) => caps,
            Err(e) => {
                return TrustEvaluationResult {
                    score: 0,
                    trusted: false,
                    reason: format!("Vouch chain verification failed: {}", e),
                };
            }
        };

        // 4. Fraud proof severing: verify NO voucher in the chain is revoked
        for (i, token) in chain.iter().enumerate() {
            if self.is_revoked(&token.payload.issuer) {
                return TrustEvaluationResult {
                    score: 0,
                    trusted: false,
                    reason: format!(
                        "Intermediary voucher (step {} issuer {}) is revoked by fraud proof; chain severed",
                        i, token.payload.issuer
                    ),
                };
            }
            if self.is_revoked(&token.payload.subject) {
                return TrustEvaluationResult {
                    score: 0,
                    trusted: false,
                    reason: format!(
                        "Vouch subject (step {} subject {}) is revoked by fraud proof; chain severed",
                        i, token.payload.subject
                    ),
                };
            }
        }

        // 5. Prefix capability enforcement
        let trimmed_path = store_path.trim();
        if !trimmed_path.is_empty() {
            let allowed = effective_caps
                .path_prefixes
                .iter()
                .any(|p| trimmed_path.starts_with(p));
            if !allowed {
                return TrustEvaluationResult {
                    score: 0,
                    trusted: false,
                    reason: format!(
                        "Store path '{}' is not authorized by vouch path prefixes {:?}",
                        trimmed_path, effective_caps.path_prefixes
                    ),
                };
            }
        }

        // 6. Decaying reputation score computation
        let mut current_score = 100u32;
        for token in chain {
            let decayed = ((current_score as f64) * self.decay_factor).floor() as u32;
            current_score = std::cmp::min(token.payload.capabilities.stake_score, decayed);
        }

        let trusted = current_score >= self.min_trust_score;
        let reason = format!(
            "Publisher evaluated via {}-hop vouch chain with effective score {} (threshold {})",
            chain.len(),
            current_score,
            self.min_trust_score
        );

        TrustEvaluationResult {
            score: current_score,
            trusted,
            reason,
        }
    }

    /// Evaluates a publisher against multiple candidate vouch chains, selecting the optimal result.
    pub fn evaluate_publisher_with_chains(
        &self,
        publisher_key: &str,
        store_path: &str,
        chains: &[Vec<VouchToken>],
        now: u64,
    ) -> TrustEvaluationResult {
        if chains.is_empty() {
            return self.evaluate_publisher(publisher_key, store_path, &[], now);
        }

        let mut best_result = TrustEvaluationResult {
            score: 0,
            trusted: false,
            reason: "No valid vouch chains found".to_string(),
        };

        for chain in chains {
            let res = self.evaluate_publisher(publisher_key, store_path, chain, now);
            if (res.trusted && !best_result.trusted)
                || (res.trusted == best_result.trusted && res.score > best_result.score)
            {
                best_result = res;
            }
        }

        best_result
    }
}

/// Serializes a slice of `VouchToken`s to a compact JSON array string.
pub fn vouch_chain_to_json(chain: &[VouchToken]) -> String {
    let tokens: Vec<String> = chain.iter().map(vouch_token_to_json).collect();
    format!("[{}]", tokens.join(","))
}

/// Deserializes a JSON string (either array of tokens or single token object) into `Vec<VouchToken>`.
pub fn vouch_chain_from_json(json_str: &str) -> Result<Vec<VouchToken>, String> {
    let trimmed = json_str.trim();
    if trimmed.starts_with('[') {
        let mut tokens = Vec::new();
        let mut depth = 0;
        let mut start_idx = None;
        let mut in_string = false;
        let mut escape = false;

        for (i, c) in trimmed.char_indices() {
            if escape {
                escape = false;
                continue;
            }
            if c == '\\' && in_string {
                escape = true;
                continue;
            }
            if c == '"' {
                in_string = !in_string;
                continue;
            }
            if in_string {
                continue;
            }

            if c == '{' {
                if depth == 0 {
                    start_idx = Some(i);
                }
                depth += 1;
            } else if c == '}' {
                depth -= 1;
                if depth == 0 {
                    if let Some(start) = start_idx {
                        let obj_str = &trimmed[start..=i];
                        let token = parse_vouch_token_json(obj_str)?;
                        tokens.push(token);
                        start_idx = None;
                    }
                }
            }
        }
        Ok(tokens)
    } else if trimmed.starts_with('{') {
        let token = parse_vouch_token_json(trimmed)?;
        Ok(vec![token])
    } else {
        Err("Expected JSON array or object for vouch chain".to_string())
    }
}

fn escape_json(s: &str) -> String {
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

fn vouch_token_to_json(token: &VouchToken) -> String {
    let prefixes: Vec<String> = token
        .payload
        .capabilities
        .path_prefixes
        .iter()
        .map(|p| format!("\"{}\"", escape_json(p)))
        .collect();

    let parent_json = match &token.payload.parent_token {
        Some(p) => format!("\"{}\"", escape_json(p)),
        None => "null".to_string(),
    };

    let payload_json = format!(
        "{{\"issuer\":\"{}\",\"subject\":\"{}\",\"parent_token\":{},\"issued_at\":{},\"expires_at\":{},\"capabilities\":{{\"path_prefixes\":[{}],\"max_depth\":{},\"stake_score\":{}}}}}",
        escape_json(&token.payload.issuer),
        escape_json(&token.payload.subject),
        parent_json,
        token.payload.issued_at,
        token.payload.expires_at,
        prefixes.join(","),
        token.payload.capabilities.max_depth,
        token.payload.capabilities.stake_score
    );

    format!(
        "{{\"payload\":{},\"signature\":\"{}\"}}",
        payload_json,
        escape_json(&token.signature)
    )
}

fn parse_vouch_token_json(json_str: &str) -> Result<VouchToken, String> {
    let trimmed = json_str.trim();
    let signature = extract_json_field(trimmed, "signature")
        .ok_or_else(|| "Missing signature in VouchToken JSON".to_string())?;

    let payload_pos = trimmed
        .find("\"payload\"")
        .ok_or_else(|| "Missing payload in VouchToken JSON".to_string())?;
    let after_payload = &trimmed[payload_pos + "\"payload\"".len()..];
    let colon_pos = after_payload
        .find(':')
        .ok_or_else(|| "Invalid payload structure".to_string())?;
    let payload_str = after_payload[colon_pos + 1..].trim_start();

    let issuer = extract_json_field(payload_str, "issuer")
        .ok_or_else(|| "Missing issuer in VouchPayload".to_string())?;
    let subject = extract_json_field(payload_str, "subject")
        .ok_or_else(|| "Missing subject in VouchPayload".to_string())?;
    let parent_token = extract_json_field(payload_str, "parent_token");
    let issued_at = extract_json_number(payload_str, "issued_at")
        .ok_or_else(|| "Missing issued_at in VouchPayload".to_string())?;
    let expires_at = extract_json_number(payload_str, "expires_at")
        .ok_or_else(|| "Missing expires_at in VouchPayload".to_string())?;

    let caps_pos = payload_str
        .find("\"capabilities\"")
        .ok_or_else(|| "Missing capabilities in VouchPayload".to_string())?;
    let after_caps = &payload_str[caps_pos + "\"capabilities\"".len()..];
    let caps_colon_pos = after_caps
        .find(':')
        .ok_or_else(|| "Invalid capabilities structure".to_string())?;
    let caps_str = after_caps[caps_colon_pos + 1..].trim_start();

    let path_prefixes = extract_json_string_array(caps_str, "path_prefixes")
        .ok_or_else(|| "Missing path_prefixes in capabilities".to_string())?;
    let max_depth = extract_json_number(caps_str, "max_depth")
        .ok_or_else(|| "Missing max_depth in capabilities".to_string())? as u32;
    let stake_score = extract_json_number(caps_str, "stake_score")
        .ok_or_else(|| "Missing stake_score in capabilities".to_string())?
        as u32;

    Ok(VouchToken {
        payload: crate::vouch::VouchPayload {
            issuer,
            subject,
            parent_token,
            issued_at,
            expires_at,
            capabilities: crate::vouch::VouchCapabilities {
                path_prefixes,
                max_depth,
                stake_score,
            },
        },
        signature,
    })
}

fn extract_json_field(json_str: &str, field_name: &str) -> Option<String> {
    let key = format!("\"{}\"", field_name);
    let key_pos = json_str.find(&key)?;
    let after_key = &json_str[key_pos + key.len()..];
    let colon_pos = after_key.find(':')?;
    let after_colon = after_key[colon_pos + 1..].trim_start();
    if after_colon.starts_with("null") {
        return None;
    }
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

fn extract_json_number(json_str: &str, field_name: &str) -> Option<u64> {
    let key = format!("\"{}\"", field_name);
    let key_pos = json_str.find(&key)?;
    let after_key = &json_str[key_pos + key.len()..];
    let colon_pos = after_key.find(':')?;
    let num_str = after_key[colon_pos + 1..].trim_start();
    let end_pos = num_str
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(num_str.len());
    num_str[..end_pos].parse::<u64>().ok()
}

fn extract_json_string_array(json_str: &str, field_name: &str) -> Option<Vec<String>> {
    let key = format!("\"{}\"", field_name);
    let key_pos = json_str.find(&key)?;
    let after_key = &json_str[key_pos + key.len()..];
    let colon_pos = after_key.find(':')?;
    let after_colon = after_key[colon_pos + 1..].trim_start();
    if !after_colon.starts_with('[') {
        return None;
    }
    let bracket_end = after_colon.find(']')?;
    let array_inner = &after_colon[1..bracket_end];

    let mut result = Vec::new();
    let mut in_str = false;
    let mut escape = false;
    let mut curr = String::new();

    for c in array_inner.chars() {
        if escape {
            match c {
                '"' => curr.push('"'),
                '\\' => curr.push('\\'),
                '/' => curr.push('/'),
                'n' => curr.push('\n'),
                'r' => curr.push('\r'),
                't' => curr.push('\t'),
                other => curr.push(other),
            }
            escape = false;
        } else if c == '\\' {
            escape = true;
        } else if c == '"' {
            if in_str {
                result.push(curr.clone());
                curr.clear();
                in_str = false;
            } else {
                in_str = true;
            }
        } else if in_str {
            curr.push(c);
        }
    }

    Some(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vouch::{mint_vouch_token, VouchCapabilities};
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
    fn test_scoring_and_decay_1hop_and_2hop() {
        let (root_sec, root_pub) = generate_keypair();
        let (a_sec, a_pub) = generate_keypair();
        let (_b_sec, b_pub) = generate_keypair();

        let now = 1000;
        let evaluator = TrustEvaluator::new()
            .with_roots(vec![root_pub.clone()])
            .with_decay_factor(0.85)
            .with_min_score(50);

        // Root is direct anchor -> score 100, trusted
        let root_res = evaluator.evaluate_publisher(&root_pub, "/gnu/store/foo", &[], now);
        assert_eq!(root_res.score, 100);
        assert!(root_res.trusted);

        // 1-hop chain: Root -> A (stake 100)
        // 100 * 0.85 = 85
        let t1 = mint_vouch_token(
            &root_sec,
            &a_pub,
            None,
            now,
            now + 3600,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/".to_string()],
                max_depth: 2,
                stake_score: 100,
            },
        )
        .unwrap();

        let res_1hop =
            evaluator.evaluate_publisher(&a_pub, "/gnu/store/foo", std::slice::from_ref(&t1), now);
        assert_eq!(res_1hop.score, 85);
        assert!(res_1hop.trusted);

        // 2-hop chain: Root -> A -> B (stake 90)
        // 85 * 0.85 = 72. min(90, 72) = 72
        let t2 = mint_vouch_token(
            &a_sec,
            &b_pub,
            Some(t1.signature.clone()),
            now,
            now + 3600,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/".to_string()],
                max_depth: 1,
                stake_score: 90,
            },
        )
        .unwrap();

        let res_2hop =
            evaluator.evaluate_publisher(&b_pub, "/gnu/store/foo", &[t1.clone(), t2.clone()], now);
        assert_eq!(res_2hop.score, 72);
        assert!(res_2hop.trusted);
    }

    #[test]
    fn test_fraud_severing_drops_downstream_to_zero() {
        let (root_sec, root_pub) = generate_keypair();
        let (a_sec, a_pub) = generate_keypair();
        let (_b_sec, b_pub) = generate_keypair();

        let now = 1000;
        let t1 = mint_vouch_token(
            &root_sec,
            &a_pub,
            None,
            now,
            now + 3600,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/".to_string()],
                max_depth: 2,
                stake_score: 100,
            },
        )
        .unwrap();

        let t2 = mint_vouch_token(
            &a_sec,
            &b_pub,
            Some(t1.signature.clone()),
            now,
            now + 3600,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/".to_string()],
                max_depth: 1,
                stake_score: 90,
            },
        )
        .unwrap();

        let chain = vec![t1, t2];

        // Case 1: Intermediary A is revoked by fraud proof
        let evaluator_a_revoked = TrustEvaluator::new()
            .with_roots(vec![root_pub.clone()])
            .with_revocations(vec![a_pub.clone()]);

        let res_b = evaluator_a_revoked.evaluate_publisher(&b_pub, "/gnu/store/foo", &chain, now);
        assert_eq!(res_b.score, 0);
        assert!(!res_b.trusted);
        assert!(res_b.reason.contains("revoked by fraud proof"));

        // Case 2: Subject B is directly revoked
        let evaluator_b_revoked = TrustEvaluator::new()
            .with_roots(vec![root_pub.clone()])
            .with_revocations(vec![b_pub.clone()]);

        let res_b2 = evaluator_b_revoked.evaluate_publisher(&b_pub, "/gnu/store/foo", &chain, now);
        assert_eq!(res_b2.score, 0);
        assert!(!res_b2.trusted);
    }

    #[test]
    fn test_prefix_filtering_enforcement() {
        let (root_sec, root_pub) = generate_keypair();
        let (_a_sec, a_pub) = generate_keypair();

        let now = 1000;
        let t1 = mint_vouch_token(
            &root_sec,
            &a_pub,
            None,
            now,
            now + 3600,
            VouchCapabilities {
                path_prefixes: vec!["/gnu/store/aaa".to_string()],
                max_depth: 1,
                stake_score: 100,
            },
        )
        .unwrap();

        let evaluator = TrustEvaluator::new().with_roots(vec![root_pub.clone()]);

        // Valid prefix -> accepted
        let res_valid = evaluator.evaluate_publisher(
            &a_pub,
            "/gnu/store/aaa-1.0",
            std::slice::from_ref(&t1),
            now,
        );
        assert_eq!(res_valid.score, 85);
        assert!(res_valid.trusted);

        // Mismatched prefix -> score 0, rejected
        let res_invalid = evaluator.evaluate_publisher(
            &a_pub,
            "/gnu/store/bbb-2.0",
            std::slice::from_ref(&t1),
            now,
        );
        assert_eq!(res_invalid.score, 0);
        assert!(!res_invalid.trusted);
        assert!(res_invalid
            .reason
            .contains("not authorized by vouch path prefixes"));
    }
}
