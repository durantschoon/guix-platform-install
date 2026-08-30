use crate::fraud::sha256_digest;

/// A compact, deterministic Bloom Filter for store path and substitute set membership testing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BloomFilter {
    bit_count: usize,
    num_hashes: usize,
    bits: Vec<u8>,
}

impl BloomFilter {
    /// Create a Bloom filter with the given item capacity and desired false positive probability.
    pub fn new(capacity: usize, false_positive_rate: f64) -> Self {
        let capacity = std::cmp::max(capacity, 1);
        let fp = false_positive_rate.clamp(0.00001, 0.5);

        // Optimal number of bits: m = - (n * ln(p)) / (ln(2)^2)
        let ln2_squared = std::f64::consts::LN_2 * std::f64::consts::LN_2;
        let num_bits = (-(capacity as f64) * fp.ln() / ln2_squared).ceil() as usize;
        let num_bits = std::cmp::max(num_bits, 64);

        // Optimal number of hash functions: k = (m / n) * ln(2)
        let num_hashes =
            ((num_bits as f64 / capacity as f64) * std::f64::consts::LN_2).round() as usize;
        let num_hashes = num_hashes.clamp(1, 16);

        let byte_count = (num_bits + 7) / 8;
        Self {
            bit_count: byte_count * 8,
            num_hashes,
            bits: vec![0u8; byte_count],
        }
    }

    /// Construct a Bloom filter from existing raw bit bytes and hash count.
    pub fn from_bytes(bytes: Vec<u8>, num_hashes: usize) -> Self {
        let bit_count = bytes.len() * 8;
        Self {
            bit_count,
            num_hashes: num_hashes.clamp(1, 16),
            bits: bytes,
        }
    }

    /// Return the raw underlying byte representation.
    pub fn as_bytes(&self) -> &[u8] {
        &self.bits
    }

    /// Return the number of hash functions used.
    pub fn num_hashes(&self) -> usize {
        self.num_hashes
    }

    /// Compute double-hash indices for an input item.
    fn hash_indices(&self, item: &[u8]) -> Vec<usize> {
        let digest = sha256_digest(item);

        let h1 = u64::from_be_bytes(digest[0..8].try_into().unwrap());
        let h2 = u64::from_be_bytes(digest[8..16].try_into().unwrap());

        let mut indices = Vec::with_capacity(self.num_hashes);
        for i in 0..self.num_hashes {
            // Enhanced double hashing: g_i(x) = (h1 + i * h2 + i^2) mod m
            let combined = h1
                .wrapping_add((i as u64).wrapping_mul(h2))
                .wrapping_add((i * i) as u64);
            indices.push((combined as usize) % self.bit_count);
        }
        indices
    }

    /// Insert an item into the Bloom filter.
    pub fn insert(&mut self, item: &[u8]) {
        if self.bit_count == 0 {
            return;
        }
        for bit_idx in self.hash_indices(item) {
            let byte_idx = bit_idx / 8;
            let bit_offset = bit_idx % 8;
            self.bits[byte_idx] |= 1 << bit_offset;
        }
    }

    /// Test if an item is possibly in the set (returns false if definitely NOT present).
    pub fn contains(&self, item: &[u8]) -> bool {
        if self.bit_count == 0 {
            return false;
        }
        for bit_idx in self.hash_indices(item) {
            let byte_idx = bit_idx / 8;
            let bit_offset = bit_idx % 8;
            if (self.bits[byte_idx] & (1 << bit_offset)) == 0 {
                return false;
            }
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bloom_filter_membership_and_bounds() {
        let mut filter = BloomFilter::new(100, 0.01);
        let items = [
            b"4zi91dws060g7x6a19ffmvf16f56s92c-hello-2.10".as_slice(),
            b"5zi91dws060g7x6a19ffmvf16f56s92c-gcc-11.3.0".as_slice(),
            b"6zi91dws060g7x6a19ffmvf16f56s92c-glibc-2.35".as_slice(),
        ];

        for item in &items {
            filter.insert(item);
        }

        // Must contain all inserted items
        for item in &items {
            assert!(filter.contains(item));
        }

        // Must not contain absent items
        assert!(!filter.contains(b"00000000000000000000000000000000-absent-pkg"));
        assert!(!filter.contains(b"99999999999999999999999999999999-not-found"));

        // Serialization roundtrip
        let bytes = filter.as_bytes().to_vec();
        let loaded = BloomFilter::from_bytes(bytes, filter.num_hashes());
        assert_eq!(filter, loaded);
        for item in &items {
            assert!(loaded.contains(item));
        }
    }
}
