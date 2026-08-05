///|
const OPEN_WORLD_PVE_REPLAY_WIRE_VERSION : Int = 2

///|
/// A centrally replayable open-world PvE encounter plus the delayed audit
/// plan, closed eligible set, and observer registration evidence that made the
/// encounter eligible before seed reveal.
pub(all) struct OpenWorldPveReplayBundle {
  signed_audit_checkpoint : @checkpoint.SignedCheckpoint
  signed_anchor_seal_checkpoint : @checkpoint.SignedCheckpoint
  audit_transparency : @open_world.OpenWorldAuditTransparencyEnvelope
  game_manifest_digest : @bft.Digest
  sample_numerator : Int
  sample_denominator : Int
  registered_count : Int
  seed : String
  observers : Array[@attestation.Participant]
  max_faults : Int
  observations : Array[@open_world.SignedOpenWorldRegistrationObservation]
  eligibility_proof : @merkle.MerkleProof
  encounter : PveReplayBundle
}

///|
pub(all) struct OpenWorldPveReplayWireLimits {
  max_bundle_bytes : Int
  max_observers : Int
  max_observations : Int
  max_merkle_steps : Int
  max_transparency_proof_steps : Int
  pve : PveReplayWireLimits
} derive(Eq, Debug)

///|
pub fn OpenWorldPveReplayWireLimits::default() -> OpenWorldPveReplayWireLimits {
  {
    max_bundle_bytes: 1048576,
    max_observers: 64,
    max_observations: 64,
    max_merkle_steps: 64,
    max_transparency_proof_steps: 64,
    pve: PveReplayWireLimits::default(),
  }
}

///|
pub suberror OpenWorldPveReplayWireError {
  OpenWorldReplayInputTooLarge(Int, Int)
  OpenWorldReplayObserversTooMany(Int, Int)
  OpenWorldReplayObservationsTooMany(Int, Int)
  OpenWorldReplayProofTooLong(Int, Int)
  OpenWorldReplayTransparencyCodecRefused(OpenWorldAuditWireError)
  OpenWorldReplayUnsupportedVersion(Int)
  OpenWorldReplayNonCanonicalEncoding
  OpenWorldReplayMalformedCbor
  OpenWorldReplayPveCodecRefused(PveReplayWireError)
} derive(Eq, Debug)

///|
fn encode_open_world_replay_observer(
  observer : @attestation.Participant,
) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(observer.id),
    @cbor.CborValue::Text(observer.key.0),
  ])
}

///|
fn open_world_replay_transparency_limits(
  limits : OpenWorldPveReplayWireLimits,
) -> OpenWorldAuditWireLimits {
  {
    max_envelope_bytes: limits.max_bundle_bytes,
    max_gap_request_bytes: limits.max_bundle_bytes,
    max_gap_response_bytes: limits.max_bundle_bytes,
    max_text_bytes: limits.pve.max_text_bytes,
    max_proof_steps: limits.max_transparency_proof_steps,
    max_gap_response_items: 0,
  }
}

///|
fn encode_open_world_audit_transparency_envelope(
  envelope : @open_world.OpenWorldAuditTransparencyEnvelope,
) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    encode_signed_checkpoint(envelope.signed_checkpoint),
    encode_auth_map_proof(envelope.audit_membership_proof),
    encode_auth_map_proof(envelope.seal_membership_proof),
  ])
}

///|
fn decode_open_world_audit_transparency_envelope(
  value : @cbor.CborValue,
  limits : OpenWorldPveReplayWireLimits,
) -> @open_world.OpenWorldAuditTransparencyEnvelope raise OpenWorldPveReplayWireError {
  let wire_limits = open_world_replay_transparency_limits(limits)
  let fields = decode_wire_array(value, 3) catch {
    error => raise OpenWorldReplayTransparencyCodecRefused(error)
  }
  let signed_checkpoint = decode_signed_checkpoint(fields[0], wire_limits) catch {
    error => raise OpenWorldReplayTransparencyCodecRefused(error)
  }
  let audit_membership_proof = decode_auth_map_proof(fields[1], wire_limits) catch {
    error => raise OpenWorldReplayTransparencyCodecRefused(error)
  }
  let seal_membership_proof = decode_auth_map_proof(fields[2], wire_limits) catch {
    error => raise OpenWorldReplayTransparencyCodecRefused(error)
  }
  { signed_checkpoint, audit_membership_proof, seal_membership_proof }
}

///|
fn decode_open_world_replay_observer(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @attestation.Participant raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 2)
  {
    id: decode_pve_wire_text(fields[0], limits),
    key: @bft.PublicKey(decode_pve_wire_text(fields[1], limits)),
  }
}

///|
fn encode_open_world_replay_observation(
  signed : @open_world.SignedOpenWorldRegistrationObservation,
) -> @cbor.CborValue {
  let observation = signed.observation
  @cbor.CborValue::Array([
    @cbor.CborValue::Array([
      @cbor.CborValue::Text(observation.audit_checkpoint_digest.0),
      @cbor.CborValue::Text(observation.observer_id),
      pve_wire_int(observation.registration_index),
      @cbor.CborValue::Text(observation.encounter_digest.0),
    ]),
    @cbor.CborValue::Text(signed.digest.0),
    @cbor.CborValue::Text(signed.signature.0),
    @cbor.CborValue::Text(signed.signer_key.0),
  ])
}

///|
fn decode_open_world_replay_observation(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @open_world.SignedOpenWorldRegistrationObservation raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 4)
  let observation = decode_pve_wire_array(fields[0], 4)
  {
    observation: {
      audit_checkpoint_digest: @bft.Digest(
        decode_pve_wire_text(observation[0], limits),
      ),
      observer_id: decode_pve_wire_text(observation[1], limits),
      registration_index: decode_pve_wire_int(observation[2]),
      encounter_digest: @bft.Digest(
        decode_pve_wire_text(observation[3], limits),
      ),
    },
    digest: @bft.Digest(decode_pve_wire_text(fields[1], limits)),
    signature: @bft.Signature(decode_pve_wire_text(fields[2], limits)),
    signer_key: @bft.PublicKey(decode_pve_wire_text(fields[3], limits)),
  }
}

///|
fn encode_open_world_merkle_step(step : @merkle.MerkleStep) -> @cbor.CborValue {
  match step {
    SiblingLeft(digest) =>
      @cbor.CborValue::Array([pve_wire_int(0), @cbor.CborValue::Text(digest.0)])
    SiblingRight(digest) =>
      @cbor.CborValue::Array([pve_wire_int(1), @cbor.CborValue::Text(digest.0)])
  }
}

///|
fn decode_open_world_merkle_step(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @merkle.MerkleStep raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 2)
  let digest = @bft.Digest(decode_pve_wire_text(fields[1], limits))
  match decode_pve_wire_int(fields[0]) {
    0 => @merkle.MerkleStep::SiblingLeft(digest)
    1 => @merkle.MerkleStep::SiblingRight(digest)
    _ => raise PveWireInvalidShape
  }
}

///|
fn encode_open_world_merkle_proof(
  proof : @merkle.MerkleProof,
) -> @cbor.CborValue {
  let path : Array[@cbor.CborValue] = []
  for step in proof.path {
    path.push(encode_open_world_merkle_step(step))
  }
  @cbor.CborValue::Array([
    pve_wire_int(proof.leaf_index),
    pve_wire_int(proof.leaf_count),
    @cbor.CborValue::Array(path),
  ])
}

///|
fn decode_open_world_merkle_proof(
  value : @cbor.CborValue,
  limits : OpenWorldPveReplayWireLimits,
) -> @merkle.MerkleProof raise OpenWorldPveReplayWireError {
  let fields = decode_pve_wire_array(value, 3) catch {
    error => raise OpenWorldReplayPveCodecRefused(error)
  }
  let encoded_path = decode_pve_wire_items(fields[2]) catch {
    error => raise OpenWorldReplayPveCodecRefused(error)
  }
  if encoded_path.length() > limits.max_merkle_steps {
    raise OpenWorldReplayProofTooLong(
      encoded_path.length(),
      limits.max_merkle_steps,
    )
  }
  let path : Array[@merkle.MerkleStep] = []
  for encoded in encoded_path {
    let step = decode_open_world_merkle_step(encoded, limits.pve) catch {
      error => raise OpenWorldReplayPveCodecRefused(error)
    }
    path.push(step)
  }
  let leaf_index = decode_pve_wire_int(fields[0]) catch {
    error => raise OpenWorldReplayPveCodecRefused(error)
  }
  let leaf_count = decode_pve_wire_int(fields[1]) catch {
    error => raise OpenWorldReplayPveCodecRefused(error)
  }
  { leaf_index, leaf_count, path }
}

///|
fn encode_open_world_pve_replay_value(
  bundle : OpenWorldPveReplayBundle,
) -> @cbor.CborValue {
  let observers : Array[@cbor.CborValue] = []
  for observer in bundle.observers {
    observers.push(encode_open_world_replay_observer(observer))
  }
  let observations : Array[@cbor.CborValue] = []
  for observation in bundle.observations {
    observations.push(encode_open_world_replay_observation(observation))
  }
  @cbor.CborValue::Array([
    pve_wire_int(OPEN_WORLD_PVE_REPLAY_WIRE_VERSION),
    encode_pve_signed_checkpoint(bundle.signed_audit_checkpoint),
    encode_pve_signed_checkpoint(bundle.signed_anchor_seal_checkpoint),
    encode_open_world_audit_transparency_envelope(bundle.audit_transparency),
    @cbor.CborValue::Text(bundle.game_manifest_digest.0),
    pve_wire_int(bundle.sample_numerator),
    pve_wire_int(bundle.sample_denominator),
    pve_wire_int(bundle.registered_count),
    @cbor.CborValue::Text(bundle.seed),
    @cbor.CborValue::Array(observers),
    pve_wire_int(bundle.max_faults),
    @cbor.CborValue::Array(observations),
    encode_open_world_merkle_proof(bundle.eligibility_proof),
    encode_pve_bundle_value(bundle.encounter),
  ])
}

///|
fn decode_open_world_pve_replay_fields(
  fields : Array[@cbor.CborValue],
  limits : OpenWorldPveReplayWireLimits,
) -> OpenWorldPveReplayBundle raise OpenWorldPveReplayWireError {
  let encoded_observers = decode_pve_wire_items(fields[9]) catch {
    error => raise OpenWorldReplayPveCodecRefused(error)
  }
  if encoded_observers.length() > limits.max_observers {
    raise OpenWorldReplayObserversTooMany(
      encoded_observers.length(),
      limits.max_observers,
    )
  }
  let encoded_observations = decode_pve_wire_items(fields[11]) catch {
    error => raise OpenWorldReplayPveCodecRefused(error)
  }
  if encoded_observations.length() > limits.max_observations {
    raise OpenWorldReplayObservationsTooMany(
      encoded_observations.length(),
      limits.max_observations,
    )
  }
  let observers : Array[@attestation.Participant] = []
  for encoded in encoded_observers {
    let observer = decode_open_world_replay_observer(encoded, limits.pve) catch {
      error => raise OpenWorldReplayPveCodecRefused(error)
    }
    observers.push(observer)
  }
  let observations : Array[@open_world.SignedOpenWorldRegistrationObservation] = []
  for encoded in encoded_observations {
    let observation = decode_open_world_replay_observation(encoded, limits.pve) catch {
      error => raise OpenWorldReplayPveCodecRefused(error)
    }
    observations.push(observation)
  }
  let signed_audit_checkpoint = decode_pve_signed_checkpoint(
    fields[1],
    limits.pve,
  ) catch {
    error => raise OpenWorldReplayPveCodecRefused(error)
  }
  let signed_anchor_seal_checkpoint = decode_pve_signed_checkpoint(
    fields[2],
    limits.pve,
  ) catch {
    error => raise OpenWorldReplayPveCodecRefused(error)
  }
  let game_manifest_digest = @bft.Digest(
    decode_pve_wire_text(fields[4], limits.pve) catch {
      error => raise OpenWorldReplayPveCodecRefused(error)
    },
  )
  let sample_numerator = decode_pve_wire_int(fields[5]) catch {
    error => raise OpenWorldReplayPveCodecRefused(error)
  }
  let sample_denominator = decode_pve_wire_int(fields[6]) catch {
    error => raise OpenWorldReplayPveCodecRefused(error)
  }
  let registered_count = decode_pve_wire_int(fields[7]) catch {
    error => raise OpenWorldReplayPveCodecRefused(error)
  }
  let seed = decode_pve_wire_text(fields[8], limits.pve) catch {
    error => raise OpenWorldReplayPveCodecRefused(error)
  }
  let max_faults = decode_pve_wire_int(fields[10]) catch {
    error => raise OpenWorldReplayPveCodecRefused(error)
  }
  let encounter = decode_pve_bundle_value(fields[13], limits.pve) catch {
    error => raise OpenWorldReplayPveCodecRefused(error)
  }
  {
    signed_audit_checkpoint,
    signed_anchor_seal_checkpoint,
    audit_transparency: decode_open_world_audit_transparency_envelope(
      fields[3],
      limits,
    ),
    game_manifest_digest,
    sample_numerator,
    sample_denominator,
    registered_count,
    seed,
    observers,
    max_faults,
    observations,
    eligibility_proof: decode_open_world_merkle_proof(fields[12], limits),
    encounter,
  }
}

///|
pub fn encode_open_world_pve_replay_bundle(
  bundle : OpenWorldPveReplayBundle,
) -> Bytes {
  @cbor.encode(encode_open_world_pve_replay_value(bundle))
}

///|
pub fn decode_open_world_pve_replay_bundle(
  input : Bytes,
  limits~ : OpenWorldPveReplayWireLimits,
) -> Result[OpenWorldPveReplayBundle, OpenWorldPveReplayWireError] {
  if input.length() > limits.max_bundle_bytes {
    return Err(
      OpenWorldReplayInputTooLarge(input.length(), limits.max_bundle_bytes),
    )
  }
  preflight_cbor(input) catch {
    _ => return Err(OpenWorldReplayMalformedCbor)
  }
  let value = @cbor.decode(input) catch {
    _ => return Err(OpenWorldReplayMalformedCbor)
  }
  if @cbor.encode(value) != input {
    return Err(OpenWorldReplayNonCanonicalEncoding)
  }
  let fields = decode_pve_wire_array(value, 14) catch {
    error => return Err(OpenWorldReplayPveCodecRefused(error))
  }
  let version = decode_pve_wire_int(fields[0]) catch {
    error => return Err(OpenWorldReplayPveCodecRefused(error))
  }
  if version != OPEN_WORLD_PVE_REPLAY_WIRE_VERSION {
    return Err(OpenWorldReplayUnsupportedVersion(version))
  }
  Ok(decode_open_world_pve_replay_fields(fields, limits)) catch {
    error => Err(error)
  }
}
