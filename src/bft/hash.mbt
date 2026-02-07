///|
/// Trait for computing content-addressed digests.
/// Implementations can range from simple FNV (testing) to SHA-256 (production).
pub(open) trait Hasher {
  hash_string(Self, String) -> Digest
}

///|
/// FNV-1a 32-bit hasher for simulation and testing.
/// Not cryptographically secure — use SHA-256 for production.
pub(all) struct FnvHasher {}

///|
/// Create a new FnvHasher.
pub fn FnvHasher::new() -> FnvHasher {
  FnvHasher::{  }
}

///|
/// FNV-1a 32-bit offset basis.
let fnv_offset_basis : UInt = 2166136261

///|
/// FNV-1a 32-bit prime.
let fnv_prime : UInt = 16777619

///|
/// Compute FNV-1a 32-bit hash and return as hex string digest.
pub impl Hasher for FnvHasher with hash_string(self : FnvHasher, data : String) -> Digest {
  ignore(self)
  let mut hash = fnv_offset_basis
  for i in 0..<data.length() {
    let byte = data[i].to_int().reinterpret_as_uint() & 0xFF
    hash = hash ^ byte
    hash = hash * fnv_prime
  }
  Digest(uint_to_hex(hash))
}

///|
fn nibble_to_hex_char(n : Int) -> Char {
  if n < 10 {
    ('0'.to_int() + n).unsafe_to_char()
  } else {
    ('a'.to_int() + n - 10).unsafe_to_char()
  }
}

///|
fn uint_to_hex(value : UInt) -> String {
  let buf = StringBuilder::new()
  for i = 7; i >= 0; i = i - 1 {
    let shift = i * 4
    let nibble = (value >> shift).land(0xF).reinterpret_as_int()
    buf.write_char(nibble_to_hex_char(nibble))
  }
  buf.to_string()
}
