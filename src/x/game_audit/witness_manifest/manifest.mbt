///|
/// Identity committed into an adversarial replay-witness session manifest.
pub(all) struct ReplayWitnessIdentity {
  id : String
  key : @bft.PublicKey
} derive(Eq, Debug)

///|
fn append_field(buffer : StringBuilder, value : String) -> Unit {
  buffer.write_string(value.length().to_string())
  buffer.write_char(':')
  buffer.write_string(value)
}

///|
/// Canonical manifest shared by the game replay kernel and witness collector.
pub fn replay_witness_session_manifest(
  hasher : &@bft.Hasher,
  game_manifest_digest~ : @bft.Digest,
  referee_key~ : @bft.PublicKey,
  witnesses~ : Array[ReplayWitnessIdentity],
  max_faults~ : Int,
) -> @bft.Digest {
  let buffer = StringBuilder::new()
  append_field(buffer, "replay-witness-session-v1")
  append_field(buffer, game_manifest_digest.0)
  append_field(buffer, referee_key.0)
  append_field(buffer, max_faults.to_string())
  let sorted = witnesses.copy()
  sorted.sort_by(fn(left, right) {
    if left.id != right.id {
      right.id.compare(left.id)
    } else {
      right.key.0.compare(left.key.0)
    }
  })
  append_field(buffer, sorted.length().to_string())
  for witness in sorted {
    append_field(buffer, witness.id)
    append_field(buffer, witness.key.0)
  }
  hasher.hash_string(buffer.to_string())
}
