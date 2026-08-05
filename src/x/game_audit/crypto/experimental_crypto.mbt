///|
/// SHA-256 adapter backed by `mizchi/experimental_crypto/hash`.
///
/// The dependency is explicitly experimental and unaudited. This adapter is
/// suitable for interoperability tests and realistic benchmarks, not a claim
/// of production cryptographic review.
pub struct ExperimentalSha256Hasher {}

///|
pub fn ExperimentalSha256Hasher::new() -> ExperimentalSha256Hasher {
  ExperimentalSha256Hasher::{  }
}

///|
fn bytes_to_lower_hex(bytes : Bytes) -> String {
  let digits = "0123456789abcdef"
  let output = StringBuilder::new()
  for byte in bytes {
    let value = byte.to_int()
    output.write_char(
      digits.code_unit_at((value >> 4) & 0x0F).to_int().unsafe_to_char(),
    )
    output.write_char(
      digits.code_unit_at(value & 0x0F).to_int().unsafe_to_char(),
    )
  }
  output.to_string()
}

///|
fn hex_nibble(code : UInt16) -> Int? {
  let value = code.to_int()
  if value >= '0'.to_int() && value <= '9'.to_int() {
    Some(value - '0'.to_int())
  } else if value >= 'a'.to_int() && value <= 'f'.to_int() {
    Some(value - 'a'.to_int() + 10)
  } else if value >= 'A'.to_int() && value <= 'F'.to_int() {
    Some(value - 'A'.to_int() + 10)
  } else {
    None
  }
}

///|
fn bytes_from_hex(value : String) -> Bytes? {
  if value.length() % 2 != 0 {
    return None
  }
  let output = FixedArray::make(value.length() / 2, b'\x00')
  for index in 0..<output.length() {
    let high = match hex_nibble(value[index * 2]) {
      Some(nibble) => nibble
      None => return None
    }
    let low = match hex_nibble(value[index * 2 + 1]) {
      Some(nibble) => nibble
      None => return None
    }
    output[index] = ((high << 4) | low).to_byte()
  }
  Some(Bytes::from_array(output))
}

///|
pub impl @bft.Hasher for ExperimentalSha256Hasher with fn hash_string(
  self : ExperimentalSha256Hasher,
  value : String,
) -> @bft.Digest {
  ignore(self)
  let bytes = @utf8.encode(value[:])
  @bft.Digest(bytes_to_lower_hex(@hash.sha256(bytes)))
}

///|
/// Ed25519 signer backed by the experimental RFC 8032 implementation.
pub struct ExperimentalEd25519Signer {
  private_key : @ed25519.PrivateKey
  public_key : @bft.PublicKey
}

///|
pub fn ExperimentalEd25519Signer::new(
  seed : Bytes,
) -> ExperimentalEd25519Signer raise @ed25519.Ed25519Error {
  let private_key = @ed25519.PrivateKey::from_seed(seed)
  let public_key = @bft.PublicKey(
    bytes_to_lower_hex(private_key.public_key().to_bytes()),
  )
  ExperimentalEd25519Signer::{ private_key, public_key }
}

///|
pub impl @bft.Signer for ExperimentalEd25519Signer with fn sign(
  self : ExperimentalEd25519Signer,
  digest : @bft.Digest,
) -> @bft.Signature {
  let message = @utf8.encode(digest.0[:])
  @bft.Signature(bytes_to_lower_hex(self.private_key.sign(message)))
}

///|
pub impl @bft.Signer for ExperimentalEd25519Signer with fn public_key(
  self : ExperimentalEd25519Signer,
) -> @bft.PublicKey {
  self.public_key
}

///|
/// Stateless strict Ed25519 verifier for hex-encoded BFT keys/signatures.
pub struct ExperimentalEd25519Verifier {}

///|
pub fn ExperimentalEd25519Verifier::new() -> ExperimentalEd25519Verifier {
  ExperimentalEd25519Verifier::{  }
}

///|
pub impl @bft.Verifier for ExperimentalEd25519Verifier with fn verify(
  self : ExperimentalEd25519Verifier,
  public_key : @bft.PublicKey,
  digest : @bft.Digest,
  signature : @bft.Signature,
) -> Bool {
  ignore(self)
  let key_bytes = match bytes_from_hex(public_key.0) {
    Some(bytes) => bytes
    None => return false
  }
  let signature_bytes = match bytes_from_hex(signature.0) {
    Some(bytes) => bytes
    None => return false
  }
  let key = @ed25519.PublicKey::from_bytes(key_bytes) catch {
    _ => return false
  }
  key.verify_strict(@utf8.encode(digest.0[:]), signature_bytes) catch {
    _ => false
  }
}
