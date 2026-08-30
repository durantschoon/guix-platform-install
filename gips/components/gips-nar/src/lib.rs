//! Nix archive (NAR) serialization and Guix-format `NarHash` computation.
//!
//! Guix (like Nix) identifies the *content* of a store object by the SHA-256
//! hash of its NAR serialization, rendered in the "nix base32" alphabet:
//!
//! ```text
//! NarHash: sha256:1xmr8jicvzszfzpz46g37mlpvbzjl2wpwvl2b05psipssyp1sm8h
//! NarSize: 96
//! ```
//!
//! This component owns three things and nothing else:
//!
//! 1. serializing a filesystem path into NAR bytes ([`serialize_nar`]),
//! 2. computing the integrity triple (`NarHash`, `NarSize`, `References`) over
//!    those bytes ([`NarIntegrity::of_nar_bytes`]),
//! 3. verifying *delivered* bytes against a previously published triple
//!    ([`NarIntegrity::verify`]) so a fetch can be refused before anything is
//!    served.
//!
//! Everything here is total and explicit: no fallbacks, no "unknown means
//! zero". A caller that cannot produce a real hash gets an error, never a
//! placeholder.
//!
//! # Grammar
//!
//! The serializer implements the NAR grammar as specified by the Nix manual
//! (`doc/manual/source/protocols/nix-archive/index.md`):
//!
//! ```text
//! nar             = str("nix-archive-1"), nar-obj;
//! nar-obj         = str("("), nar-obj-inner, str(")");
//! nar-obj-inner   = str("type"), str("regular"), regular
//!                 | str("type"), str("symlink"), symlink
//!                 | str("type"), str("directory"), directory;
//! regular         = [ str("executable"), str("") ], str("contents"), str(contents);
//! symlink         = str("target"), str(target);
//! directory       = { directory-entry };                 (* ordered by name *)
//! directory-entry = str("entry"), str("("), str("name"), str(name),
//!                   str("node"), nar-obj, str(")");
//! str(s)          = int(|s|), pad(s);                    (* int = u64 little endian *)
//! ```

use sha2::{Digest, Sha256};
use std::fmt;
use std::fs;
use std::io::{BufWriter, Read, Write};
use std::path::{Path, PathBuf};

/// Alphabet used by Nix/Guix base32 (RFC 4648 minus `e`, `o`, `u`, `t`).
const NIX_BASE32_ALPHABET: &[u8; 32] = b"0123456789abcdfghijklmnpqrsvwxyz";

/// Length in characters of a base32-rendered SHA-256 digest: ceil(256 / 5).
const NIX_BASE32_SHA256_LEN: usize = 52;

/// The Guix store directory. Store paths look like
/// `/gnu/store/<32-char-base32-hash>-<name>`.
pub const GUIX_STORE_DIR: &str = "/gnu/store";

/// Default ceiling for the *buffered* helpers, in bytes.
///
/// [`serialize_nar`] and [`nar_and_integrity`] materialize the whole archive in
/// memory, so a caller of theirs needs some bound; 10 MB is the conservative one
/// they default to, and today only the test fixtures take it. It is no longer a
/// serving or publishing limit: `/publish` spools to disk under its own, much
/// larger sanity bound, and `/nar` streams under the signed `NarSize` rather
/// than under any constant. Callers that cannot bound an object in RAM should
/// use [`nar_and_integrity_to_file`] and pass a bound of their own.
pub const DEFAULT_MAX_NAR_BYTES: u64 = 10 * 1024 * 1024;

/// Maximum directory nesting the serializer will descend.
const MAX_NAR_DEPTH: usize = 512;

/// Failure to serialize a filesystem path into a NAR.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NarError {
    /// A filesystem operation failed. `message` is the OS error rendered.
    Io { path: PathBuf, message: String },
    /// The path is neither a regular file, a symlink, nor a directory
    /// (sockets, fifos, devices have no NAR representation).
    UnsupportedFileType { path: PathBuf },
    /// A file or symlink-target name is not valid UTF-8, so it cannot be
    /// serialized deterministically.
    NonUtf8Name { path: PathBuf },
    /// The serialization exceeded the caller's byte ceiling.
    TooLarge { limit: u64, at_least: u64 },
    /// The directory tree is nested deeper than [`MAX_NAR_DEPTH`].
    TooDeep { path: PathBuf, limit: usize },
}

impl fmt::Display for NarError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io { path, message } => {
                write!(f, "nar io error at {}: {}", path.display(), message)
            }
            Self::UnsupportedFileType { path } => {
                write!(
                    f,
                    "unsupported file type for nar serialization: {}",
                    path.display()
                )
            }
            Self::NonUtf8Name { path } => {
                write!(f, "non-UTF-8 name in nar input: {}", path.display())
            }
            Self::TooLarge { limit, at_least } => {
                write!(
                    f,
                    "nar exceeds {} byte limit (at least {} bytes)",
                    limit, at_least
                )
            }
            Self::TooDeep { path, limit } => {
                write!(
                    f,
                    "nar input nested deeper than {} at {}",
                    limit,
                    path.display()
                )
            }
        }
    }
}

impl std::error::Error for NarError {}

/// Failure to accept a `NarHash` string, or to match delivered bytes against a
/// published integrity triple.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IntegrityError {
    /// The `NarHash` field is not `sha256:<52 nix-base32 chars>`.
    MalformedNarHash { value: String },
    /// Delivered byte count differs from the published `NarSize`.
    SizeMismatch { expected: u64, actual: u64 },
    /// Delivered bytes hash to something other than the published `NarHash`.
    HashMismatch { expected: String, actual: String },
}

impl fmt::Display for IntegrityError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MalformedNarHash { value } => write!(f, "malformed NarHash: {}", value),
            Self::SizeMismatch { expected, actual } => {
                write!(f, "NarSize mismatch: expected {}, got {}", expected, actual)
            }
            Self::HashMismatch { expected, actual } => {
                write!(f, "NarHash mismatch: expected {}, got {}", expected, actual)
            }
        }
    }
}

impl std::error::Error for IntegrityError {}

/// A validated Guix `NarHash` value: `sha256:` followed by 52 nix-base32
/// characters. Constructing one is the only way to get one, so a `NarHash` in
/// hand is always well-formed (parse, don't validate).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NarHash(String);

impl NarHash {
    /// Hashes already-serialized NAR bytes.
    pub fn of_nar_bytes(nar_bytes: &[u8]) -> Self {
        let digest = Sha256::digest(nar_bytes);
        Self(format!("sha256:{}", nix_base32_encode(&digest)))
    }

    /// Parses a `NarHash` field value, rejecting anything that is not a real
    /// SHA-256 nix-base32 hash. Notably this rejects the historical
    /// `sha256:000…0` placeholder by construction only if it has the wrong
    /// length; an all-zero hash of the correct length is well-formed but is
    /// still never *produced* here, and callers must obtain hashes from
    /// [`NarHash::of_nar_bytes`].
    pub fn parse(value: &str) -> Result<Self, IntegrityError> {
        let malformed = || IntegrityError::MalformedNarHash {
            value: value.to_string(),
        };
        let digits = value.strip_prefix("sha256:").ok_or_else(malformed)?;
        if digits.len() != NIX_BASE32_SHA256_LEN {
            return Err(malformed());
        }
        if !digits.bytes().all(|b| NIX_BASE32_ALPHABET.contains(&b)) {
            return Err(malformed());
        }
        Ok(Self(value.to_string()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for NarHash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// The `References:` field of a narinfo.
///
/// `Unknown` is a first-class state on purpose: a record that predates
/// reference scanning must say so rather than claim an empty reference set.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum References {
    /// Store-path basenames found by scanning the NAR. May legitimately be
    /// empty for a self-contained object.
    Scanned(Vec<String>),
    /// No reference information was recorded for this object.
    Unknown,
}

/// Wire sentinel for [`References::Unknown`].
pub const REFERENCES_UNKNOWN: &str = "unknown";

impl References {
    /// Parses a `References:` field value. The sentinel `unknown` round-trips
    /// to [`References::Unknown`]; anything else is a whitespace-separated
    /// basename list.
    pub fn parse_narinfo_value(value: &str) -> Self {
        if value.trim() == REFERENCES_UNKNOWN {
            return Self::Unknown;
        }
        Self::Scanned(value.split_whitespace().map(str::to_string).collect())
    }

    /// Renders the `References:` field value.
    pub fn to_narinfo_value(&self) -> String {
        match self {
            Self::Scanned(refs) => refs.join(" "),
            Self::Unknown => REFERENCES_UNKNOWN.to_string(),
        }
    }

    pub fn scanned(&self) -> Option<&[String]> {
        match self {
            Self::Scanned(refs) => Some(refs),
            Self::Unknown => None,
        }
    }
}

/// The integrity triple a publisher signs and a fetcher checks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NarIntegrity {
    pub nar_hash: NarHash,
    pub nar_size: u64,
    pub references: References,
}

impl NarIntegrity {
    /// Computes the triple over serialized NAR bytes, scanning them for store
    /// references. See [`scan_references`] for what that scan can and cannot
    /// see.
    pub fn of_nar_bytes(nar_bytes: &[u8], store_dir: &str) -> Self {
        Self {
            nar_hash: NarHash::of_nar_bytes(nar_bytes),
            nar_size: nar_bytes.len() as u64,
            references: References::Scanned(scan_references(nar_bytes, store_dir)),
        }
    }

    /// Rejects delivered bytes that are not exactly the published NAR.
    ///
    /// Size is checked first because it is the cheaper discriminator; the hash
    /// check is what actually binds the content.
    pub fn verify(&self, delivered: &[u8]) -> Result<(), IntegrityError> {
        let actual_size = delivered.len() as u64;
        if actual_size != self.nar_size {
            return Err(IntegrityError::SizeMismatch {
                expected: self.nar_size,
                actual: actual_size,
            });
        }
        let actual = NarHash::of_nar_bytes(delivered);
        if actual != self.nar_hash {
            return Err(IntegrityError::HashMismatch {
                expected: self.nar_hash.0.clone(),
                actual: actual.0,
            });
        }
        Ok(())
    }
}

/// Encodes bytes in the Nix/Guix base32 alphabet, least-significant digit
/// last (the same order `nix-hash --base32` and Guix's `bytevector->nix-base32-string`
/// produce).
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

/// Scans NAR bytes for literal `<store_dir>/<hash>-<name>` occurrences and
/// returns the sorted, deduplicated basenames.
///
/// # Limitations (deliberately documented, not papered over)
///
/// This is a *syntactic* scan of the object's own bytes. Guix derives the real
/// reference set by scanning for the hash parts of the derivation's declared
/// inputs, which we do not have here. Therefore this function:
///
/// * cannot restrict matches to genuine build inputs (a store path merely
///   *mentioned* in a text file is reported),
/// * cannot see a reference that appears without the `<store_dir>/` prefix,
/// * cannot authoritatively delimit the `-<name>` component inside binary
///   data, so a reported basename may carry trailing bytes that happen to be
///   valid store-name characters.
///
/// It is therefore a best-effort reference set, not an authoritative closure.
/// Callers that have no scan at all must record [`References::Unknown`] rather
/// than an empty list.
pub fn scan_references(nar_bytes: &[u8], store_dir: &str) -> Vec<String> {
    /// Characters Guix allows in the `<name>` part of a store path basename.
    fn is_name_byte(b: u8) -> bool {
        b.is_ascii_alphanumeric() || matches!(b, b'+' | b'-' | b'.' | b'_' | b'?' | b'=')
    }
    fn is_hash_byte(b: u8) -> bool {
        NIX_BASE32_ALPHABET.contains(&b)
    }

    const HASH_LEN: usize = 32;
    let needle = format!("{}/", store_dir).into_bytes();
    let mut found: Vec<String> = Vec::new();

    if needle.is_empty() || nar_bytes.len() < needle.len() + HASH_LEN + 2 {
        return found;
    }

    for start in 0..=(nar_bytes.len() - needle.len()) {
        if &nar_bytes[start..start + needle.len()] != needle.as_slice() {
            continue;
        }
        let hash_start = start + needle.len();
        let hash_end = hash_start + HASH_LEN;
        if hash_end + 1 > nar_bytes.len() {
            continue;
        }
        if !nar_bytes[hash_start..hash_end]
            .iter()
            .copied()
            .all(is_hash_byte)
        {
            continue;
        }
        if nar_bytes[hash_end] != b'-' {
            continue;
        }
        let mut name_end = hash_end + 1;
        while name_end < nar_bytes.len() && is_name_byte(nar_bytes[name_end]) {
            name_end += 1;
        }
        if name_end == hash_end + 1 {
            continue;
        }
        // Both halves were checked byte-by-byte against ASCII sets above.
        let basename = String::from_utf8_lossy(&nar_bytes[hash_start..name_end]).into_owned();
        found.push(basename);
    }

    found.sort_unstable();
    found.dedup();
    found
}

/// Characters Guix allows in the `<name>` part of a store path basename.
fn is_store_name_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'+' | b'-' | b'.' | b'_' | b'?' | b'=')
}

fn is_store_hash_byte(b: u8) -> bool {
    NIX_BASE32_ALPHABET.contains(&b)
}

/// Length of the base32 hash part of a store path basename.
const STORE_HASH_LEN: usize = 32;

/// Most bytes the streaming scanner will carry across a chunk boundary while a
/// candidate match is still open.
///
/// A store-path basename is a filename, so it cannot exceed the 255 bytes a
/// filesystem allows; 64 KiB is three orders of magnitude of headroom. The cap
/// exists only so that a hostile object made of nothing but valid store-name
/// bytes cannot make the scanner buffer without bound. A match longer than this
/// is dropped rather than reported truncated.
const MAX_SCAN_CARRY: usize = 64 * 1024;

/// The chunk-at-a-time twin of [`scan_references`].
///
/// Feeding a byte sequence through `update` in any chunking yields the same
/// answer as calling [`scan_references`] on the whole sequence, with the single
/// documented exception of a candidate longer than [`MAX_SCAN_CARRY`]. All the
/// limitations listed on [`scan_references`] apply here unchanged.
struct ReferenceScanner {
    /// `<store_dir>/`.
    needle: Vec<u8>,
    /// Bytes not yet ruled out as part of a match that runs off the end.
    buf: Vec<u8>,
    found: std::collections::BTreeSet<String>,
}

impl ReferenceScanner {
    fn new(store_dir: &str) -> Self {
        Self {
            needle: format!("{}/", store_dir).into_bytes(),
            buf: Vec::new(),
            found: std::collections::BTreeSet::new(),
        }
    }

    fn update(&mut self, chunk: &[u8]) {
        self.buf.extend_from_slice(chunk);
        self.drain(false);
    }

    fn finish(mut self) -> Vec<String> {
        self.drain(true);
        self.found.into_iter().collect()
    }

    /// Emits every match that is certainly complete and discards every byte
    /// that can no longer start one.
    ///
    /// A match still open at the end of the buffer is *not* emitted unless
    /// `at_eof`; its start index is retained so the next chunk completes it.
    /// Retained bytes are rescanned, and `found` is a set, so re-emitting an
    /// already-seen basename is a no-op rather than a duplicate.
    fn drain(&mut self, at_eof: bool) {
        if self.needle.is_empty() {
            self.buf.clear();
            return;
        }
        let n = self.needle.len();
        let len = self.buf.len();
        let mut retain = len;

        for start in 0..len {
            let available = len - start;
            let compare = n.min(available);
            if self.buf[start..start + compare] != self.needle[..compare] {
                continue;
            }
            if compare < n {
                // A prefix of the needle runs off the end of what we have.
                if !at_eof {
                    retain = retain.min(start);
                }
                continue;
            }
            let hash_start = start + n;
            let hash_end = hash_start + STORE_HASH_LEN;
            if hash_end >= len {
                // Not enough bytes yet to judge the hash and the `-`.
                if !at_eof {
                    retain = retain.min(start);
                }
                continue;
            }
            if !self.buf[hash_start..hash_end]
                .iter()
                .copied()
                .all(is_store_hash_byte)
            {
                continue;
            }
            if self.buf[hash_end] != b'-' {
                continue;
            }
            let mut name_end = hash_end + 1;
            while name_end < len && is_store_name_byte(self.buf[name_end]) {
                name_end += 1;
            }
            if name_end == len && !at_eof {
                // The name may continue into the next chunk; decide later.
                retain = retain.min(start);
                continue;
            }
            if name_end == hash_end + 1 {
                continue;
            }
            // Both halves were checked byte-by-byte against ASCII sets above.
            self.found
                .insert(String::from_utf8_lossy(&self.buf[hash_start..name_end]).into_owned());
        }

        // Never carry more than the documented bound, whatever the input does.
        let retain = retain.max(len.saturating_sub(MAX_SCAN_CARRY));
        self.buf.drain(..retain);
    }
}

/// Serializes a filesystem path into NAR bytes.
///
/// The root path is *not* dereferenced: a symlink root serializes as a symlink
/// node, matching `nix hash path --mode nar`.
///
/// This is the buffered convenience wrapper over [`serialize_nar_into`]; it
/// materializes the whole archive, so it is only appropriate for objects the
/// caller has already bounded. Callers that cannot bound the object should
/// spool to disk with [`nar_and_integrity_to_file`] instead.
pub fn serialize_nar(root: &Path, max_bytes: u64) -> Result<Vec<u8>, NarError> {
    let mut out = Vec::new();
    serialize_nar_into(root, &mut out, max_bytes)?;
    Ok(out)
}

/// Serializes a store path and computes its integrity triple in one pass.
///
/// Buffered: see [`serialize_nar`]. The streaming twin is
/// [`nar_and_integrity_to_file`].
pub fn nar_and_integrity(
    root: &Path,
    store_dir: &str,
    max_bytes: u64,
) -> Result<(Vec<u8>, NarIntegrity), NarError> {
    let nar_bytes = serialize_nar(root, max_bytes)?;
    let integrity = NarIntegrity::of_nar_bytes(&nar_bytes, store_dir);
    Ok((nar_bytes, integrity))
}

/// Serializes a filesystem path into any [`std::io::Write`] sink, returning the
/// number of NAR bytes written.
///
/// The sink is written strictly forwards and is never read back, so a caller
/// can point this at a file, a hasher, a socket, or all three at once. Nothing
/// larger than [`FILE_COPY_CHUNK_BYTES`] plus one directory listing is held in
/// memory regardless of how large the object is.
pub fn serialize_nar_into<W: Write>(root: &Path, sink: W, max_bytes: u64) -> Result<u64, NarError> {
    let mut sink = NarSink::new(sink);
    write_nar_string(&mut sink, b"nix-archive-1")?;
    write_node(&mut sink, root, max_bytes, 0)?;
    sink.flush_inner()?;
    Ok(sink.written)
}

/// Serializes a store path to `sink_path` while computing its integrity triple
/// in the same single pass.
///
/// This is the O(disk) publish path: the NAR is never materialized in memory,
/// and `NarHash`, `NarSize` and `References` all fall out of the bytes as they
/// stream past. The resulting triple is exactly what [`nar_and_integrity`]
/// would have produced for the same tree — see the equivalence test.
///
/// The file at `sink_path` is created (truncating anything already there) and
/// left on disk on success; the caller owns its lifetime. On failure the
/// partial file is left in place too, because deleting it here would race a
/// caller that spooled into a directory it is about to remove wholesale.
pub fn nar_and_integrity_to_file(
    root: &Path,
    store_dir: &str,
    sink_path: &Path,
    max_bytes: u64,
) -> Result<NarIntegrity, NarError> {
    let file = fs::File::create(sink_path).map_err(|e| io_err(sink_path, e))?;
    let mut writer = IntegrityWriter::new(BufWriter::new(file), store_dir);
    // `serialize_nar_into` flushes the sink before it returns, so the file on
    // disk is complete by the time the triple below is built from it.
    let written = serialize_nar_into(root, &mut writer, max_bytes)?;
    Ok(writer.finish(written))
}

/// How much of a regular file's contents is copied into the sink at a time.
///
/// The only unavoidable RAM cost of serializing an arbitrarily large file.
pub const FILE_COPY_CHUNK_BYTES: usize = 64 * 1024;

/// A [`std::io::Write`] sink that counts what it has written and remembers the
/// path to blame when a write fails.
struct NarSink<W: Write> {
    inner: W,
    written: u64,
}

impl<W: Write> NarSink<W> {
    fn new(inner: W) -> Self {
        Self { inner, written: 0 }
    }

    /// Writes every byte or fails; partial writes are retried by
    /// `write_all`, so `written` and the sink can never disagree.
    fn put(&mut self, bytes: &[u8]) -> Result<(), NarError> {
        self.inner.write_all(bytes).map_err(|e| NarError::Io {
            path: PathBuf::from("<nar sink>"),
            message: e.to_string(),
        })?;
        self.written += bytes.len() as u64;
        Ok(())
    }

    fn flush_inner(&mut self) -> Result<(), NarError> {
        self.inner.flush().map_err(|e| NarError::Io {
            path: PathBuf::from("<nar sink>"),
            message: e.to_string(),
        })
    }
}

/// An incremental `NarHash` computation, for callers that see the NAR as a
/// stream of chunks rather than as one slice.
///
/// Feeding every chunk in order and calling [`NarHasher::finish`] yields
/// exactly `NarHash::of_nar_bytes(concatenation)`. It lives here rather than in
/// the HTTP layer so that "what a NarHash is" stays owned by one component.
#[derive(Default)]
pub struct NarHasher {
    hasher: Sha256,
    size: u64,
}

impl NarHasher {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn update(&mut self, chunk: &[u8]) {
        self.hasher.update(chunk);
        self.size += chunk.len() as u64;
    }

    /// Bytes fed so far — the caller's running `NarSize`.
    pub fn size(&self) -> u64 {
        self.size
    }

    pub fn finish(self) -> NarHash {
        NarHash(format!(
            "sha256:{}",
            nix_base32_encode(&self.hasher.finalize())
        ))
    }
}

/// Wraps a sink so that everything written through it is also hashed and
/// scanned for store references.
struct IntegrityWriter<W: Write> {
    inner: W,
    hasher: NarHasher,
    scanner: ReferenceScanner,
}

impl<W: Write> IntegrityWriter<W> {
    fn new(inner: W, store_dir: &str) -> Self {
        Self {
            inner,
            hasher: NarHasher::new(),
            scanner: ReferenceScanner::new(store_dir),
        }
    }

    fn finish(self, nar_size: u64) -> NarIntegrity {
        NarIntegrity {
            nar_hash: self.hasher.finish(),
            nar_size,
            references: References::Scanned(self.scanner.finish()),
        }
    }
}

impl<W: Write> Write for IntegrityWriter<W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        // `write_all` upstream means `buf` is always fully consumed here, so
        // the hasher and the sink observe the identical byte sequence.
        self.inner.write_all(buf)?;
        self.hasher.update(buf);
        self.scanner.update(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

fn write_nar_string<W: Write>(sink: &mut NarSink<W>, value: &[u8]) -> Result<(), NarError> {
    sink.put(&(value.len() as u64).to_le_bytes())?;
    sink.put(value)?;
    let padding = (8 - value.len() % 8) % 8;
    sink.put(&[0u8; 8][..padding])
}

fn io_err(path: &Path, e: std::io::Error) -> NarError {
    NarError::Io {
        path: path.to_path_buf(),
        message: e.to_string(),
    }
}

fn check_size<W: Write>(sink: &NarSink<W>, max_bytes: u64) -> Result<(), NarError> {
    if sink.written > max_bytes {
        return Err(NarError::TooLarge {
            limit: max_bytes,
            at_least: sink.written,
        });
    }
    Ok(())
}

/// Copies exactly `len` bytes of `path` into the sink, in bounded chunks.
///
/// `len` comes from the metadata the header was written from, so the NAR's
/// declared content length and its content can never disagree. A file that
/// shrank under us is an error rather than a short, self-inconsistent archive.
fn copy_file_contents<W: Write>(
    sink: &mut NarSink<W>,
    path: &Path,
    len: u64,
) -> Result<(), NarError> {
    let file = fs::File::open(path).map_err(|e| io_err(path, e))?;
    let mut reader = file.take(len);
    let mut buf = vec![0u8; FILE_COPY_CHUNK_BYTES];
    let mut copied: u64 = 0;
    loop {
        let n = reader.read(&mut buf).map_err(|e| io_err(path, e))?;
        if n == 0 {
            break;
        }
        sink.put(&buf[..n])?;
        copied += n as u64;
    }
    if copied != len {
        return Err(NarError::Io {
            path: path.to_path_buf(),
            message: format!("file shrank while serializing: expected {len} bytes, read {copied}"),
        });
    }
    Ok(())
}

fn write_node<W: Write>(
    sink: &mut NarSink<W>,
    path: &Path,
    max_bytes: u64,
    depth: usize,
) -> Result<(), NarError> {
    if depth > MAX_NAR_DEPTH {
        return Err(NarError::TooDeep {
            path: path.to_path_buf(),
            limit: MAX_NAR_DEPTH,
        });
    }

    let meta = fs::symlink_metadata(path).map_err(|e| io_err(path, e))?;
    let file_type = meta.file_type();

    write_nar_string(sink, b"(")?;
    write_nar_string(sink, b"type")?;

    if file_type.is_symlink() {
        let target = fs::read_link(path).map_err(|e| io_err(path, e))?;
        let target = target.to_str().ok_or_else(|| NarError::NonUtf8Name {
            path: path.to_path_buf(),
        })?;
        write_nar_string(sink, b"symlink")?;
        write_nar_string(sink, b"target")?;
        write_nar_string(sink, target.as_bytes())?;
    } else if file_type.is_file() {
        // Reject before reading: a huge file must not be streamed into the
        // sink just to discover it blows the ceiling.
        if meta.len() > max_bytes {
            return Err(NarError::TooLarge {
                limit: max_bytes,
                at_least: meta.len(),
            });
        }
        write_nar_string(sink, b"regular")?;
        if is_executable(&meta) {
            write_nar_string(sink, b"executable")?;
            write_nar_string(sink, b"")?;
        }
        write_nar_string(sink, b"contents")?;
        // The `str(contents)` production, written in three pieces so the
        // contents never have to exist as one buffer: length, bytes, padding.
        let len = meta.len();
        sink.put(&len.to_le_bytes())?;
        copy_file_contents(sink, path, len)?;
        let padding = (8 - (len % 8)) % 8;
        sink.put(&[0u8; 8][..padding as usize])?;
    } else if file_type.is_dir() {
        write_nar_string(sink, b"directory")?;
        let mut names: Vec<std::ffi::OsString> = Vec::new();
        for entry in fs::read_dir(path).map_err(|e| io_err(path, e))? {
            let entry = entry.map_err(|e| io_err(path, e))?;
            names.push(entry.file_name());
        }
        // NAR requires entries in byte order of their names.
        names.sort();
        for name in names {
            let name_str = name.to_str().ok_or_else(|| NarError::NonUtf8Name {
                path: path.join(&name),
            })?;
            write_nar_string(sink, b"entry")?;
            write_nar_string(sink, b"(")?;
            write_nar_string(sink, b"name")?;
            write_nar_string(sink, name_str.as_bytes())?;
            write_nar_string(sink, b"node")?;
            write_node(sink, &path.join(&name), max_bytes, depth + 1)?;
            write_nar_string(sink, b")")?;
            check_size(sink, max_bytes)?;
        }
    } else {
        return Err(NarError::UnsupportedFileType {
            path: path.to_path_buf(),
        });
    }

    write_nar_string(sink, b")")?;
    check_size(sink, max_bytes)?;
    Ok(())
}

#[cfg(unix)]
fn is_executable(meta: &fs::Metadata) -> bool {
    use std::os::unix::fs::PermissionsExt;
    meta.permissions().mode() & 0o111 != 0
}

#[cfg(not(unix))]
fn is_executable(_meta: &fs::Metadata) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use md5::Md5;
    use std::io::Write;

    /// Golden vectors below are taken verbatim from the upstream Nix test
    /// suite, `tests/functional/hash-path.sh` in NixOS/nix (fetched from
    /// raw.githubusercontent.com at implementation time). Guix uses the same
    /// NAR format and the same nix-base32 rendering, so a value Nix computes
    /// is the value Guix computes.
    ///
    /// * base32 SHA-256 of "abc"        -> `try sha256 ... FORMAT=base32`
    /// * NAR sha256/base32 of a symlink -> `nix hash path --mode nar` case
    /// * NAR sha256/base32 of a file    -> `nix hash path` (defaults to nar mode)
    /// * NAR md5 of a directory         -> the three `try2 md5` cases
    const GOLDEN_BASE32_SHA256_ABC: &str = "1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s";
    const GOLDEN_NAR_SYMLINK: &str = "1bl5ry3x1fcbwgr5c2x50bn572iixh4j1p6ax5isxly2ddgn8pbp";
    const GOLDEN_NAR_REGULAR_HI: &str = "1xmr8jicvzszfzpz46g37mlpvbzjl2wpwvl2b05psipssyp1sm8h";
    const GOLDEN_NAR_DIR_REGULAR_MD5: &str = "ea9b55537dd4c7e104515b2ccfaf4100";
    const GOLDEN_NAR_DIR_EXECUTABLE_MD5: &str = "20f3ffe011d4cfa7d72bfabef7882836";
    const GOLDEN_NAR_DIR_SYMLINK_MD5: &str = "f78b733a68f5edbdf9413899339eaa4a";

    fn md5_hex(bytes: &[u8]) -> String {
        let digest = Md5::digest(bytes);
        digest.iter().map(|b| format!("{:02x}", b)).collect()
    }

    #[test]
    fn nix_base32_matches_upstream_golden_vector() {
        let digest = Sha256::digest(b"abc");
        assert_eq!(nix_base32_encode(&digest), GOLDEN_BASE32_SHA256_ABC);
        assert_eq!(nix_base32_encode(&digest).len(), NIX_BASE32_SHA256_LEN);
    }

    #[test]
    fn nar_of_regular_file_matches_guix_golden_vector() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("hi");
        let mut f = fs::File::create(&path).unwrap();
        f.write_all(b"hi\n").unwrap();
        drop(f);

        let nar = serialize_nar(&path, DEFAULT_MAX_NAR_BYTES).unwrap();
        let integrity = NarIntegrity::of_nar_bytes(&nar, GUIX_STORE_DIR);

        assert_eq!(
            integrity.nar_hash.as_str(),
            format!("sha256:{}", GOLDEN_NAR_REGULAR_HI)
        );
        assert_eq!(integrity.nar_size, nar.len() as u64);
        // Round-trip: the published triple accepts exactly the bytes it came from.
        assert_eq!(integrity.verify(&nar), Ok(()));
    }

    #[test]
    #[cfg(unix)]
    fn nar_of_symlink_matches_guix_golden_vector() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("symlink-to-nowhere");
        std::os::unix::fs::symlink("/non-existent-48cujwe8ndf4as0bne", &path).unwrap();

        let nar = serialize_nar(&path, DEFAULT_MAX_NAR_BYTES).unwrap();
        assert_eq!(
            NarHash::of_nar_bytes(&nar).as_str(),
            format!("sha256:{}", GOLDEN_NAR_SYMLINK)
        );
    }

    #[test]
    #[cfg(unix)]
    fn nar_of_directory_matches_upstream_md5_golden_vectors() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("hash-path");
        fs::create_dir(&root).unwrap();
        let hello = root.join("hello");
        fs::write(&hello, b"Hello World\n").unwrap();
        fs::set_permissions(&hello, fs::Permissions::from_mode(0o644)).unwrap();

        let nar = serialize_nar(&root, DEFAULT_MAX_NAR_BYTES).unwrap();
        assert_eq!(md5_hex(&nar), GOLDEN_NAR_DIR_REGULAR_MD5);

        // The execute bit is part of the content identity.
        fs::set_permissions(&hello, fs::Permissions::from_mode(0o755)).unwrap();
        let nar = serialize_nar(&root, DEFAULT_MAX_NAR_BYTES).unwrap();
        assert_eq!(md5_hex(&nar), GOLDEN_NAR_DIR_EXECUTABLE_MD5);

        // Other permission bits and mtimes are not.
        fs::set_permissions(&hello, fs::Permissions::from_mode(0o744)).unwrap();
        let nar = serialize_nar(&root, DEFAULT_MAX_NAR_BYTES).unwrap();
        assert_eq!(md5_hex(&nar), GOLDEN_NAR_DIR_EXECUTABLE_MD5);

        // File type is.
        fs::remove_file(&hello).unwrap();
        std::os::unix::fs::symlink("x", &hello).unwrap();
        let nar = serialize_nar(&root, DEFAULT_MAX_NAR_BYTES).unwrap();
        assert_eq!(md5_hex(&nar), GOLDEN_NAR_DIR_SYMLINK_MD5);
    }

    #[test]
    fn directory_entries_are_serialized_in_byte_order() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("d");
        fs::create_dir(&root).unwrap();
        // Names chosen so each appears exactly once in the NAR byte stream.
        for name in ["entry-b", "entry-a", "entry-C"] {
            fs::write(root.join(name), b"x").unwrap();
        }
        let nar = serialize_nar(&root, DEFAULT_MAX_NAR_BYTES).unwrap();
        let pos = |needle: &str| {
            nar.windows(needle.len())
                .position(|w| w == needle.as_bytes())
                .unwrap()
        };
        assert!(pos("entry-C") < pos("entry-a"));
        assert!(pos("entry-a") < pos("entry-b"));
    }

    #[test]
    fn tampering_one_byte_is_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("hi");
        fs::write(&path, b"hi\n").unwrap();

        let (nar, integrity) =
            nar_and_integrity(&path, GUIX_STORE_DIR, DEFAULT_MAX_NAR_BYTES).unwrap();
        assert_eq!(integrity.verify(&nar), Ok(()));

        // Flip one byte of the payload: same length, different content.
        let mut tampered = nar.clone();
        let last = tampered.len() - 1;
        let victim = tampered
            .iter()
            .position(|b| *b == b'h')
            .expect("payload byte present");
        tampered[victim] ^= 0x01;
        assert_eq!(tampered.len(), nar.len());
        assert!(matches!(
            integrity.verify(&tampered),
            Err(IntegrityError::HashMismatch { .. })
        ));

        // Truncation is caught by the cheaper size check.
        let truncated = &nar[..last];
        assert!(matches!(
            integrity.verify(truncated),
            Err(IntegrityError::SizeMismatch { .. })
        ));
    }

    #[test]
    fn nar_hash_parse_rejects_placeholders() {
        // The historical fabricated value: `sha256:` + 52 zeros is the right
        // shape, but the short placeholder actually served by GIPS was not.
        assert!(
            NarHash::parse("sha256:0000000000000000000000000000000000000000000000000000").is_ok()
        );
        assert!(matches!(
            NarHash::parse("sha256:0"),
            Err(IntegrityError::MalformedNarHash { .. })
        ));
        assert!(matches!(
            NarHash::parse(""),
            Err(IntegrityError::MalformedNarHash { .. })
        ));
        // `e`, `o`, `u`, `t` are not in the nix base32 alphabet.
        assert!(matches!(
            NarHash::parse("sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
            Err(IntegrityError::MalformedNarHash { .. })
        ));
        assert!(matches!(
            NarHash::parse("sha512:1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s"),
            Err(IntegrityError::MalformedNarHash { .. })
        ));
    }

    #[test]
    fn scan_references_finds_store_paths_and_skips_junk() {
        let real = "/gnu/store/8009y4y5d4rhm796p02a7b8w6k2hvwq2-bash-5.1.16";
        let dupe = "/gnu/store/8009y4y5d4rhm796p02a7b8w6k2hvwq2-bash-5.1.16";
        let other = "/gnu/store/1d1yr2fhq7mkc9r4d5c1p2s0dqk4dpwd-glibc-2.35";
        // `e`, `o`, `u`, `t` are outside the alphabet, so this is not a hash.
        let bogus = "/gnu/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-not-a-hash";
        let blob = format!("prefix\0{}\0{}\0{}\0{}", real, dupe, other, bogus);

        let refs = scan_references(blob.as_bytes(), GUIX_STORE_DIR);
        assert_eq!(
            refs,
            vec![
                "1d1yr2fhq7mkc9r4d5c1p2s0dqk4dpwd-glibc-2.35".to_string(),
                "8009y4y5d4rhm796p02a7b8w6k2hvwq2-bash-5.1.16".to_string(),
            ]
        );
    }

    #[test]
    fn references_round_trip_through_the_wire_form() {
        assert_eq!(
            References::parse_narinfo_value("unknown"),
            References::Unknown
        );
        assert_eq!(References::Unknown.to_narinfo_value(), "unknown");
        let scanned = References::Scanned(vec!["a-b".into(), "c-d".into()]);
        assert_eq!(scanned.to_narinfo_value(), "a-b c-d");
        assert_eq!(
            References::parse_narinfo_value(&scanned.to_narinfo_value()),
            scanned
        );
        // An empty scan is a real answer, distinct from "unknown".
        assert_eq!(
            References::parse_narinfo_value(""),
            References::Scanned(vec![])
        );
    }

    #[test]
    fn oversized_input_is_refused_not_truncated() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("big");
        fs::write(&path, vec![0u8; 4096]).unwrap();
        assert!(matches!(
            serialize_nar(&path, 1024),
            Err(NarError::TooLarge { .. })
        ));
    }

    #[test]
    fn missing_path_is_an_io_error() {
        let dir = tempfile::tempdir().unwrap();
        assert!(matches!(
            serialize_nar(&dir.path().join("nope"), DEFAULT_MAX_NAR_BYTES),
            Err(NarError::Io { .. })
        ));
    }

    // -----------------------------------------------------------------------
    // Stage 27: sink-generic serialization.
    // -----------------------------------------------------------------------

    /// The three golden shapes the serializer has to get right, built into a
    /// fresh temp dir: a regular file, a symlink, and a directory holding both
    /// plus an executable — with a real store reference in the payload so the
    /// `References` half of the triple is a computed answer, not a blank.
    #[cfg(unix)]
    fn golden_fixtures(dir: &Path) -> Vec<(&'static str, PathBuf)> {
        use std::os::unix::fs::PermissionsExt;

        let file = dir.join("hi");
        fs::write(&file, b"hi\n").unwrap();

        let link = dir.join("symlink-to-nowhere");
        std::os::unix::fs::symlink("/non-existent-48cujwe8ndf4as0bne", &link).unwrap();

        let tree = dir.join("tree");
        fs::create_dir(&tree).unwrap();
        fs::write(
            tree.join("hello"),
            b"#!/gnu/store/1d1yr2fhq7mkc9r4d5c1p2s0dqk4dpwd-glibc-2.35/bin/sh\n",
        )
        .unwrap();
        fs::create_dir(tree.join("nested")).unwrap();
        let exe = tree.join("nested").join("run");
        fs::write(
            &exe,
            b"binary\0/gnu/store/8009y4y5d4rhm796p02a7b8w6k2hvwq2-bash-5.1.16\0",
        )
        .unwrap();
        fs::set_permissions(&exe, fs::Permissions::from_mode(0o755)).unwrap();
        std::os::unix::fs::symlink("hello", tree.join("zlink")).unwrap();

        vec![("file", file), ("symlink", link), ("directory", tree)]
    }

    /// Enumerated test 1: the sink-based serializer is byte-identical to the
    /// buffered one, and the spooled triple equals the buffered triple —
    /// hash, size and references alike.
    #[test]
    #[cfg(unix)]
    fn spooled_serialization_matches_the_buffered_serializer_exactly() {
        let dir = tempfile::tempdir().unwrap();
        let sinks = tempfile::tempdir().unwrap();

        for (label, root) in golden_fixtures(dir.path()) {
            let (buffered, buffered_integrity) =
                nar_and_integrity(&root, GUIX_STORE_DIR, DEFAULT_MAX_NAR_BYTES).unwrap();

            // The generic sink, driven into memory: byte-identical output.
            let mut streamed = Vec::new();
            let written = serialize_nar_into(&root, &mut streamed, DEFAULT_MAX_NAR_BYTES).unwrap();
            assert_eq!(streamed, buffered, "{label}: sink output must be identical");
            assert_eq!(written, buffered.len() as u64, "{label}: byte count");

            // The spooling variant: same bytes on disk, same triple.
            let sink_path = sinks.path().join(format!("{label}.nar"));
            let spooled =
                nar_and_integrity_to_file(&root, GUIX_STORE_DIR, &sink_path, DEFAULT_MAX_NAR_BYTES)
                    .unwrap();
            assert_eq!(
                fs::read(&sink_path).unwrap(),
                buffered,
                "{label}: spooled file must be identical"
            );
            assert_eq!(
                spooled, buffered_integrity,
                "{label}: spooled triple must equal the buffered triple"
            );
            assert_eq!(spooled.nar_size, buffered.len() as u64);
        }
    }

    /// The directory fixture really does carry references, so the assertion
    /// above is comparing two non-empty answers rather than two blanks.
    #[test]
    #[cfg(unix)]
    fn the_reference_bearing_fixture_is_not_vacuous() {
        let dir = tempfile::tempdir().unwrap();
        let sinks = tempfile::tempdir().unwrap();
        let (_, tree) = golden_fixtures(dir.path()).pop().unwrap();
        let spooled = nar_and_integrity_to_file(
            &tree,
            GUIX_STORE_DIR,
            &sinks.path().join("t.nar"),
            DEFAULT_MAX_NAR_BYTES,
        )
        .unwrap();
        assert_eq!(
            spooled.references.scanned().unwrap(),
            [
                "1d1yr2fhq7mkc9r4d5c1p2s0dqk4dpwd-glibc-2.35".to_string(),
                "8009y4y5d4rhm796p02a7b8w6k2hvwq2-bash-5.1.16".to_string(),
            ]
        );
    }

    /// The streaming scanner agrees with the whole-buffer scan for *every*
    /// chunking, including ones that split a store path down the middle. This
    /// is the property the spooled `References` rests on.
    #[test]
    fn the_streaming_scanner_agrees_with_the_buffered_scan_at_any_chunk_size() {
        let blob = format!(
            "lead\0{a}\0{a}\0filler{b}tail\0/gnu/store/short-\0",
            a = "/gnu/store/8009y4y5d4rhm796p02a7b8w6k2hvwq2-bash-5.1.16",
            b = "/gnu/store/1d1yr2fhq7mkc9r4d5c1p2s0dqk4dpwd-glibc-2.35",
        );
        let bytes = blob.as_bytes();
        let expected = scan_references(bytes, GUIX_STORE_DIR);
        assert_eq!(expected.len(), 2, "fixture must actually contain matches");

        for chunk in [1usize, 2, 3, 7, 11, 13, 32, 33, 64, 4096] {
            let mut scanner = ReferenceScanner::new(GUIX_STORE_DIR);
            for piece in bytes.chunks(chunk) {
                scanner.update(piece);
            }
            assert_eq!(
                scanner.finish(),
                expected,
                "chunk size {chunk} must not change the answer"
            );
        }
    }

    /// A regular file's contents are copied in bounded pieces, so a file
    /// larger than one copy chunk still serializes to exactly the same bytes.
    #[test]
    fn a_file_larger_than_one_copy_chunk_round_trips() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("big");
        // Deliberately not a multiple of the chunk size, and not a multiple of
        // 8 either, so both the chunk loop and the NAR padding are exercised.
        let contents: Vec<u8> = (0..(FILE_COPY_CHUNK_BYTES * 3 + 5))
            .map(|i| (i % 251) as u8)
            .collect();
        fs::write(&path, &contents).unwrap();

        let (buffered, buffered_integrity) =
            nar_and_integrity(&path, GUIX_STORE_DIR, DEFAULT_MAX_NAR_BYTES).unwrap();
        let sink_path = dir.path().join("spooled.nar");
        let spooled =
            nar_and_integrity_to_file(&path, GUIX_STORE_DIR, &sink_path, DEFAULT_MAX_NAR_BYTES)
                .unwrap();

        assert_eq!(fs::read(&sink_path).unwrap(), buffered);
        assert_eq!(spooled, buffered_integrity);
        assert_eq!(buffered_integrity.verify(&buffered), Ok(()));
    }

    /// The incremental hasher is the streamed serving path's only definition of
    /// `NarHash`, so it has to agree with the one-shot one at any chunking.
    #[test]
    fn the_incremental_hasher_agrees_with_the_one_shot_hash() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("hi");
        fs::write(&path, b"hi\n").unwrap();
        let nar = serialize_nar(&path, DEFAULT_MAX_NAR_BYTES).unwrap();

        for chunk in [1usize, 5, 8, 17, 4096] {
            let mut hasher = NarHasher::new();
            for piece in nar.chunks(chunk) {
                hasher.update(piece);
            }
            assert_eq!(hasher.size(), nar.len() as u64);
            assert_eq!(hasher.finish(), NarHash::of_nar_bytes(&nar));
        }
        // And it reproduces the upstream golden vector, not just itself.
        let mut hasher = NarHasher::new();
        hasher.update(&nar);
        assert_eq!(
            hasher.finish().as_str(),
            format!("sha256:{}", GOLDEN_NAR_REGULAR_HI)
        );
    }

    /// The spooling variant refuses an oversized tree the same way the buffered
    /// one does, rather than filling the disk first.
    #[test]
    fn spooling_still_refuses_an_oversized_input() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("big");
        fs::write(&path, vec![0u8; 4096]).unwrap();
        assert!(matches!(
            nar_and_integrity_to_file(&path, GUIX_STORE_DIR, &dir.path().join("out.nar"), 1024),
            Err(NarError::TooLarge { .. })
        ));
    }
}
