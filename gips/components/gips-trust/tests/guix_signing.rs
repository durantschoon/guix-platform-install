//! Stage 29 enumerated tests 1 and 2: the key ceremony, and the oracle
//! round-trip.
//!
//! The oracle (`tests/guix-oracle.scm`) is deliberately a *separate* Guile
//! program from the signer. If both halves were the same code, "our signature
//! verifies" would only say that a function agrees with itself. Instead the
//! oracle re-derives the hashed region from the served text the way
//! `guix/narinfo.scm` does, re-checks the signature the way `guix/pki.scm`
//! does, and compares the embedded key against an authorized `.pub` the way an
//! ACL does. A flipped byte in the signed text has to flip its verdict, which
//! is what makes a passing run mean something.

use gips_trust::guix::{self, GuixKeyError, GuixSigner, GuixSigningConfig};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// A narinfo body of the shape `gips-http` serves: the mandatory fields Guix
/// insists on, in the order the daemon emits them, ending in a newline.
const BODY: &str = "StorePath: /gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-hello-2.12\n\
                    URL: nar/bafkreiabcdefghijklmnopqrstuvwxyz234567\n\
                    Compression: none\n\
                    NarHash: sha256:0mdqa9w1p6cmli6976v4wi0sw9r4p5prkj7lzfd1877wk11c9c73\n\
                    NarSize: 4096\n\
                    References: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-glibc-2.39\n";

/// Skips loudly rather than passing vacuously. On the machine this stage was
/// written for, both are present and the report shows the oracle ran.
fn guile_with_gcrypt() -> bool {
    let available = Command::new("/usr/bin/env")
        .args([
            "guile",
            "-q",
            "--no-auto-compile",
            "-c",
            "(use-modules (gcrypt pk-crypto) (gcrypt hash) (gcrypt base64) (gcrypt base16))",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false);
    if !available {
        eprintln!(
            "SKIPPING: guile with (gcrypt pk-crypto) is not installed, so the Guix signature \
             path cannot be exercised here. This test is not passing, it is not running."
        );
    }
    available
}

fn oracle_script() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("guix-oracle.scm")
}

struct Verdict {
    status: String,
    findings: Vec<String>,
    accepted: bool,
}

impl Verdict {
    fn finding(&self, key: &str) -> Option<&str> {
        self.findings
            .iter()
            .find_map(|line| line.strip_prefix(&format!("{}: ", key)))
    }
}

/// Runs the oracle over `narinfo`, authorizing `public_key`.
fn ask_the_oracle(narinfo: &str, public_key: &Path) -> Verdict {
    use std::io::Write;

    let mut child = Command::new("/usr/bin/env")
        .args(["guile", "-q", "--no-auto-compile", "-s"])
        .arg(oracle_script())
        .arg("--")
        .arg(public_key)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("the oracle must be runnable");
    child
        .stdin
        .take()
        .expect("stdin was piped")
        .write_all(narinfo.as_bytes())
        .expect("the oracle must accept the narinfo");
    let output = child.wait_with_output().expect("the oracle must finish");

    let findings: Vec<String> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::to_string)
        .collect();
    let status = findings
        .iter()
        .find_map(|line| line.strip_prefix("verdict: "))
        .unwrap_or("<no verdict>")
        .to_string();
    eprintln!(
        "oracle: {}\nstderr: {}",
        findings.join(" | "),
        String::from_utf8_lossy(&output.stderr)
    );
    Verdict {
        status,
        findings,
        accepted: output.status.success(),
    }
}

fn mode_of(path: &Path) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

/// The `q` value of a key sexp, which is the public point both halves must
/// agree on.
fn q_of(sexp: &str) -> String {
    let after = sexp.split("(q #").nth(1).expect("a key sexp carries a q");
    after
        .split('#')
        .next()
        .expect("the q value is hash-delimited")
        .to_string()
}

/// Enumerated test 1: the ceremony writes an owner-only pair whose halves
/// match, and a second run refuses rather than destroying the first key.
#[test]
fn generate_guix_writes_a_matching_owner_only_pair_and_never_overwrites() {
    if !guile_with_gcrypt() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    // A subdirectory that does not exist yet, so the 0700 staking is exercised
    // and not merely inherited from the temp dir.
    let keys = dir.path().join("keys");
    let secret = keys.join("signing-key.sec");

    let pair = guix::generate_key_pair(&secret, None).expect("key generation must succeed");
    assert_eq!(pair.secret_key, secret);
    assert_eq!(pair.public_key, keys.join("signing-key.pub"));

    assert_eq!(mode_of(&keys), 0o700, "the key directory must be 0700");
    assert_eq!(mode_of(&pair.secret_key), 0o600);
    assert_eq!(mode_of(&pair.public_key), 0o600);

    let secret_sexp = std::fs::read_to_string(&pair.secret_key).unwrap();
    let public_sexp = std::fs::read_to_string(&pair.public_key).unwrap();
    assert!(secret_sexp.starts_with("(private-key"), "{}", secret_sexp);
    assert!(public_sexp.starts_with("(public-key"), "{}", public_sexp);
    assert!(
        public_sexp.contains("(curve Ed25519)"),
        "the public half names the curve Guix authorizes: {}",
        public_sexp
    );
    assert_eq!(
        q_of(&secret_sexp),
        q_of(&public_sexp),
        "the two halves must describe the same public point"
    );
    assert_eq!(
        guix::export_public_key(&secret).unwrap(),
        public_sexp,
        "`gips key export-guix` prints the stored bytes, not a re-rendering"
    );

    // A second ceremony must not destroy the first key: the only thing that
    // can verify signatures already on the wire is the key that made them.
    match guix::generate_key_pair(&secret, None) {
        Err(GuixKeyError::AlreadyExists { path }) => assert_eq!(path, secret),
        other => panic!("expected a refusal to overwrite, got {:?}", other),
    }
    assert_eq!(
        std::fs::read_to_string(&pair.secret_key).unwrap(),
        secret_sexp,
        "the refused run must leave the existing key byte-identical"
    );
}

/// Enumerated test 2: a signature made by the real pipeline is accepted by an
/// independent Guile oracle that mirrors `narinfo-sha256` and
/// `%signature-status` — and rejected once a byte of the signed text moves.
#[test]
fn a_signed_narinfo_satisfies_the_guix_oracle_and_a_flipped_byte_does_not() {
    if !guile_with_gcrypt() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let secret = dir.path().join("keys").join("signing-key.sec");
    let pair = guix::generate_key_pair(&secret, None).unwrap();

    let signer = GuixSigner::new(&GuixSigningConfig {
        secret_key: secret.clone(),
        host: Some("gips-test.local".to_string()),
        guile: None,
    });
    assert!(
        signer.startup_warnings().is_empty(),
        "a freshly generated key must be above reproach: {:?}",
        signer.startup_warnings()
    );

    let served = signer.signed_narinfo(BODY).expect("signing must succeed");
    assert!(
        served.starts_with(BODY),
        "signing appends; it must not touch the bytes it signs"
    );
    let signature_line = served
        .strip_prefix(BODY)
        .unwrap()
        .strip_suffix('\n')
        .expect("the served narinfo ends in a newline");
    assert!(
        signature_line.starts_with("Signature: 1;gips-test.local;"),
        "{}",
        signature_line
    );

    // The digest Guix will recompute, derived here without touching any of the
    // code under test.
    let expected_hash = hex(&Sha256::digest(BODY.as_bytes()));

    let verdict = ask_the_oracle(&served, &pair.public_key);
    assert_eq!(verdict.status, "valid-signature");
    assert!(
        verdict.accepted,
        "the oracle must exit 0 on a good signature"
    );
    assert_eq!(verdict.finding("recomputed-hash"), Some(&expected_hash[..]));
    assert_eq!(
        verdict.finding("embedded-hash"),
        Some(&expected_hash[..]),
        "the sexp must carry the digest of exactly the text served above the signature"
    );
    assert_eq!(verdict.finding("is-ecdsa"), Some("yes"));
    assert_eq!(verdict.finding("key-matches-authorized"), Some("yes"));
    assert_eq!(verdict.finding("sig-host"), Some("gips-test.local"));

    // Non-vacuity: move one byte of the signed region and the same oracle,
    // the same signature and the same key must now refuse.
    let mut tampered = served.into_bytes();
    let victim = BODY.find("NarSize: 4096").unwrap() + "NarSize: ".len();
    tampered[victim] = b'5';
    let tampered = String::from_utf8(tampered).unwrap();
    let verdict = ask_the_oracle(&tampered, &pair.public_key);
    assert_eq!(verdict.status, "hash-mismatch");
    assert!(!verdict.accepted);

    // And a signature by a key the ACL does not carry is unauthorized, even
    // though it is a perfectly valid signature.
    let other = dir.path().join("other").join("signing-key.sec");
    let other = guix::generate_key_pair(&other, None).unwrap();
    let served = signer.signed_narinfo(BODY).unwrap();
    let verdict = ask_the_oracle(&served, &other.public_key);
    assert_eq!(verdict.status, "unauthorized-key");
}

/// rfc6979 is deterministic: the same key over the same digest yields the same
/// bytes every time. Serve-time caching is only sound because of this.
#[test]
fn signing_is_deterministic() {
    if !guile_with_gcrypt() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let secret = dir.path().join("signing-key.sec");
    guix::generate_key_pair(&secret, None).unwrap();
    let signer = GuixSigner::new(&GuixSigningConfig {
        secret_key: secret,
        host: Some("gips-test.local".to_string()),
        guile: None,
    });

    assert_eq!(
        signer.sign_body(BODY).unwrap(),
        signer.sign_body(BODY).unwrap()
    );
    assert_ne!(
        signer.sign_body(BODY).unwrap(),
        signer.sign_body(&BODY.replace("4096", "8192")).unwrap()
    );
    assert_eq!(signer.invocations(), 4, "one subprocess per sign_body call");
}

/// A body Guix would treat as unsigned is refused at signing time rather than
/// served with a decorative signature nobody checks.
#[test]
fn a_body_missing_a_mandatory_field_is_refused() {
    if !guile_with_gcrypt() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let secret = dir.path().join("signing-key.sec");
    guix::generate_key_pair(&secret, None).unwrap();
    let signer = GuixSigner::new(&GuixSigningConfig {
        secret_key: secret,
        host: Some("gips-test.local".to_string()),
        guile: None,
    });

    let without_references = BODY
        .lines()
        .filter(|line| !line.starts_with("References:"))
        .collect::<Vec<_>>()
        .join("\n");
    let error = signer
        .sign_body(&format!("{}\n", without_references))
        .expect_err("Guix would call this unsigned, so we must not sign it");
    assert!(
        error.to_string().contains("References:"),
        "the refusal must name the missing field: {}",
        error
    );
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{:02x}", byte)).collect()
}
