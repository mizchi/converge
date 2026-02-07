///|
/// Trait for signing digests. Implementations can range from mock HMAC to Ed25519.
pub(open) trait Signer {
  sign(Self, Digest) -> Signature
  public_key(Self) -> PublicKey
}

///|
/// Trait for verifying signatures against public keys.
pub(open) trait Verifier {
  verify(Self, PublicKey, Digest, Signature) -> Bool
}

///|
/// Mock signer for testing. Uses "HMAC(secret, digest)" as signature.
pub(all) struct MockSigner {
  secret : String
  key : PublicKey
}

///|
/// Create a new MockSigner with a given peer name.
pub fn MockSigner::new(peer_name : String) -> MockSigner {
  MockSigner::{ secret: "secret_" + peer_name, key: PublicKey(peer_name) }
}

///|
pub impl Signer for MockSigner with sign(self : MockSigner, digest : Digest) -> Signature {
  Signature("HMAC(" + self.secret + "," + digest.0 + ")")
}

///|
pub impl Signer for MockSigner with public_key(self : MockSigner) -> PublicKey {
  self.key
}

///|
/// Mock verifier for testing. Recomputes the expected HMAC and compares.
pub(all) struct MockVerifier {
  /// Maps public key to secret for verification
  secrets : Map[String, String]
}

///|
/// Create a new MockVerifier.
pub fn MockVerifier::new() -> MockVerifier {
  MockVerifier::{ secrets: {} }
}

///|
/// Register a peer's key for verification.
pub fn MockVerifier::register(self : MockVerifier, key : PublicKey) -> Unit {
  self.secrets["secret_" + key.0] = key.0
}

///|
pub impl Verifier for MockVerifier with verify(
  self : MockVerifier,
  key : PublicKey,
  digest : Digest,
  signature : Signature,
) -> Bool {
  ignore(self)
  let expected = "HMAC(secret_" + key.0 + "," + digest.0 + ")"
  signature.0 == expected
}
