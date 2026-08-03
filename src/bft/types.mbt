///|
/// Content-addressed hash digest of an event.
pub(all) struct Digest(String) derive(Eq, Compare, Hash, Debug)

///|
/// Cryptographic signature over a digest.
pub(all) struct Signature(String) derive(Eq, Debug)

///|
/// Public key identifying a peer for signature verification.
pub(all) struct PublicKey(String) derive(Eq, Hash, Debug)

///|
/// An event wrapped with cryptographic authentication.
/// Contains the original event plus its hash, signature, and dependency hashes.
pub(all) struct SignedEvent {
  digest : Digest
  signature : Signature
  author_key : PublicKey
  dep_hashes : Array[Digest]
  event : @types.Event
}

///|
/// Kind of Byzantine fault detected.
pub(all) enum BFTAlertKind {
  Equivocation
  HashMismatch
  InvalidSignature
  MissingDependency
} derive(Eq, Debug)

///|
/// Report of a detected Byzantine fault.
pub(all) struct BFTAlert {
  kind : BFTAlertKind
  peer : @types.PeerId
  digest : Digest
  detail : String
} derive(Eq, Debug)

///|
/// Result of attempting to deliver a signed event through the BFT adapter.
pub(all) enum DeliveryResult {
  Accepted(@types.Event)
  Buffered
  Rejected(BFTAlert)
} derive(Eq, Debug)
