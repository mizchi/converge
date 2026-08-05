///|
const INVENTORY_LISTING_WIRE_VERSION : Int = 1

///|
/// Compact current-owner evidence. The checkpoint authenticates the inventory
/// root while replay witnesses attest the deterministic transition kernel.
pub(all) struct InventoryListingProofBundle {
  signed_checkpoint : @checkpoint.SignedCheckpoint
  game_manifest_digest : @bft.Digest
  witnesses : Array[@witness_manifest.ReplayWitnessIdentity]
  max_faults : Int
  attestations : Array[@attestation.SignedAttestation]
  proof : @inventory.InventoryProof
} derive(Eq, Debug)

///|
pub(all) struct InventoryListingWireLimits {
  max_bundle_bytes : Int
  max_text_bytes : Int
  max_witnesses : Int
  max_attestations : Int
  max_proof_steps : Int
} derive(Eq, Debug)

///|
pub fn InventoryListingWireLimits::default() -> InventoryListingWireLimits {
  {
    max_bundle_bytes: 262144,
    max_text_bytes: 4096,
    max_witnesses: 64,
    max_attestations: 64,
    max_proof_steps: 64,
  }
}

///|
pub(all) enum InventoryListingWireError {
  InventoryWireInputTooLarge(Int, Int)
  InventoryWireWitnessesTooMany(Int, Int)
  InventoryWireAttestationsTooMany(Int, Int)
  InventoryWireUnsupportedVersion(Int)
  InventoryWireNonCanonicalEncoding
  InventoryWireMalformedCbor
  InventoryWireCodecRefused(OpenWorldAuditWireError)
} derive(Eq, Debug)

///|
fn inventory_open_world_limits(
  limits : InventoryListingWireLimits,
) -> OpenWorldAuditWireLimits {
  {
    max_envelope_bytes: limits.max_bundle_bytes,
    max_gap_request_bytes: limits.max_bundle_bytes,
    max_gap_response_bytes: limits.max_bundle_bytes,
    max_text_bytes: limits.max_text_bytes,
    max_proof_steps: limits.max_proof_steps,
    max_gap_response_items: limits.max_witnesses.max(limits.max_attestations),
  }
}

///|
fn encode_inventory_asset_record(
  record : @inventory.AssetRecord,
) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(record.asset_id),
    @cbor.CborValue::Text(record.owner_id),
    @cbor.CborValue::Text(record.item_type),
    wire_int(record.quantity),
    @cbor.CborValue::Text(record.origin_source_event.0),
    wire_int(record.origin_output_index),
    @cbor.CborValue::Text(record.origin_receipt_digest.0),
    wire_int(record.version),
    @cbor.CborValue::Text(record.last_event.0),
  ])
}

///|
fn decode_inventory_asset_record(
  value : @cbor.CborValue,
  limits : OpenWorldAuditWireLimits,
) -> @inventory.AssetRecord raise OpenWorldAuditWireError {
  let fields = decode_wire_array(value, 9)
  {
    asset_id: decode_wire_text(fields[0], limits),
    owner_id: decode_wire_text(fields[1], limits),
    item_type: decode_wire_text(fields[2], limits),
    quantity: decode_wire_int(fields[3]),
    origin_source_event: decode_wire_digest(fields[4], limits),
    origin_output_index: decode_wire_int(fields[5]),
    origin_receipt_digest: decode_wire_digest(fields[6], limits),
    version: decode_wire_int(fields[7]),
    last_event: decode_wire_digest(fields[8], limits),
  }
}

///|
fn encode_inventory_proof(proof : @inventory.InventoryProof) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    encode_inventory_asset_record(proof.record),
    encode_auth_map_proof(proof.map_proof),
  ])
}

///|
fn decode_inventory_proof(
  value : @cbor.CborValue,
  limits : OpenWorldAuditWireLimits,
) -> @inventory.InventoryProof raise OpenWorldAuditWireError {
  let fields = decode_wire_array(value, 2)
  {
    record: decode_inventory_asset_record(fields[0], limits),
    map_proof: decode_auth_map_proof(fields[1], limits),
  }
}

///|
fn encode_inventory_witness(
  witness : @witness_manifest.ReplayWitnessIdentity,
) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(witness.id),
    @cbor.CborValue::Text(witness.key.0),
  ])
}

///|
fn decode_inventory_witness(
  value : @cbor.CborValue,
  limits : OpenWorldAuditWireLimits,
) -> @witness_manifest.ReplayWitnessIdentity raise OpenWorldAuditWireError {
  let fields = decode_wire_array(value, 2)
  {
    id: decode_wire_text(fields[0], limits),
    key: decode_wire_public_key(fields[1], limits),
  }
}

///|
fn encode_inventory_attestation_choice(
  choice : @attestation.AttestationChoice,
) -> @cbor.CborValue {
  wire_int(
    match choice {
      Approve => 0
      Challenge => 1
    },
  )
}

///|
fn decode_inventory_attestation_choice(
  value : @cbor.CborValue,
) -> @attestation.AttestationChoice raise OpenWorldAuditWireError {
  match decode_wire_int(value) {
    0 => @attestation.AttestationChoice::Approve
    1 => @attestation.AttestationChoice::Challenge
    _ => raise WireInvalidShape
  }
}

///|
fn encode_inventory_attestation_purpose(
  purpose : @attestation.AttestationPurpose,
) -> @cbor.CborValue {
  wire_int(
    match purpose {
      CheckpointApproval => 0
      ReplayWitness => 1
    },
  )
}

///|
fn decode_inventory_attestation_purpose(
  value : @cbor.CborValue,
) -> @attestation.AttestationPurpose raise OpenWorldAuditWireError {
  match decode_wire_int(value) {
    0 => @attestation.AttestationPurpose::CheckpointApproval
    1 => @attestation.AttestationPurpose::ReplayWitness
    _ => raise WireInvalidShape
  }
}

///|
fn encode_inventory_signed_attestation(
  signed : @attestation.SignedAttestation,
) -> @cbor.CborValue {
  let statement = signed.attestation
  @cbor.CborValue::Array([
    @cbor.CborValue::Array([
      @cbor.CborValue::Text(statement.checkpoint_digest.0),
      @cbor.CborValue::Text(statement.participant_id),
      encode_inventory_attestation_purpose(statement.purpose),
      encode_inventory_attestation_choice(statement.choice),
    ]),
    @cbor.CborValue::Text(signed.digest.0),
    @cbor.CborValue::Text(signed.signature.0),
    @cbor.CborValue::Text(signed.signer_key.0),
  ])
}

///|
fn decode_inventory_signed_attestation(
  value : @cbor.CborValue,
  limits : OpenWorldAuditWireLimits,
) -> @attestation.SignedAttestation raise OpenWorldAuditWireError {
  let fields = decode_wire_array(value, 4)
  let statement = decode_wire_array(fields[0], 4)
  {
    attestation: {
      checkpoint_digest: decode_wire_digest(statement[0], limits),
      participant_id: decode_wire_text(statement[1], limits),
      purpose: decode_inventory_attestation_purpose(statement[2]),
      choice: decode_inventory_attestation_choice(statement[3]),
    },
    digest: decode_wire_digest(fields[1], limits),
    signature: decode_wire_signature(fields[2], limits),
    signer_key: decode_wire_public_key(fields[3], limits),
  }
}

///|
fn encode_inventory_listing_value(
  bundle : InventoryListingProofBundle,
) -> @cbor.CborValue {
  let witnesses : Array[@cbor.CborValue] = []
  for witness in bundle.witnesses {
    witnesses.push(encode_inventory_witness(witness))
  }
  let attestations : Array[@cbor.CborValue] = []
  for attestation in bundle.attestations {
    attestations.push(encode_inventory_signed_attestation(attestation))
  }
  @cbor.CborValue::Array([
    wire_int(INVENTORY_LISTING_WIRE_VERSION),
    encode_signed_checkpoint(bundle.signed_checkpoint),
    @cbor.CborValue::Text(bundle.game_manifest_digest.0),
    @cbor.CborValue::Array(witnesses),
    wire_int(bundle.max_faults),
    @cbor.CborValue::Array(attestations),
    encode_inventory_proof(bundle.proof),
  ])
}

///|
fn inventory_wire_items(
  value : @cbor.CborValue,
) -> Array[@cbor.CborValue] raise OpenWorldAuditWireError {
  match value {
    @cbor.CborValue::Array(items) => items
    _ => raise WireInvalidShape
  }
}

///|
pub fn encode_inventory_listing_proof_bundle(
  bundle : InventoryListingProofBundle,
) -> Bytes {
  @cbor.encode(encode_inventory_listing_value(bundle))
}

///|
pub fn decode_inventory_listing_proof_bundle(
  input : Bytes,
  limits~ : InventoryListingWireLimits,
) -> Result[InventoryListingProofBundle, InventoryListingWireError] {
  if input.length() > limits.max_bundle_bytes {
    return Err(
      InventoryWireInputTooLarge(input.length(), limits.max_bundle_bytes),
    )
  }
  preflight_cbor(input) catch {
    _ => return Err(InventoryWireMalformedCbor)
  }
  let value = @cbor.decode(input) catch {
    _ => return Err(InventoryWireMalformedCbor)
  }
  if @cbor.encode(value) != input {
    return Err(InventoryWireNonCanonicalEncoding)
  }
  let fields = decode_wire_array(value, 7) catch {
    error => return Err(InventoryWireCodecRefused(error))
  }
  let version = decode_wire_int(fields[0]) catch {
    error => return Err(InventoryWireCodecRefused(error))
  }
  if version != INVENTORY_LISTING_WIRE_VERSION {
    return Err(InventoryWireUnsupportedVersion(version))
  }
  let encoded_witnesses = inventory_wire_items(fields[3]) catch {
    error => return Err(InventoryWireCodecRefused(error))
  }
  if encoded_witnesses.length() > limits.max_witnesses {
    return Err(
      InventoryWireWitnessesTooMany(
        encoded_witnesses.length(),
        limits.max_witnesses,
      ),
    )
  }
  let encoded_attestations = inventory_wire_items(fields[5]) catch {
    error => return Err(InventoryWireCodecRefused(error))
  }
  if encoded_attestations.length() > limits.max_attestations {
    return Err(
      InventoryWireAttestationsTooMany(
        encoded_attestations.length(),
        limits.max_attestations,
      ),
    )
  }
  let codec_limits = inventory_open_world_limits(limits)
  let witnesses : Array[@witness_manifest.ReplayWitnessIdentity] = []
  for encoded in encoded_witnesses {
    let witness = decode_inventory_witness(encoded, codec_limits) catch {
      error => return Err(InventoryWireCodecRefused(error))
    }
    witnesses.push(witness)
  }
  let attestations : Array[@attestation.SignedAttestation] = []
  for encoded in encoded_attestations {
    let attestation = decode_inventory_signed_attestation(encoded, codec_limits) catch {
      error => return Err(InventoryWireCodecRefused(error))
    }
    attestations.push(attestation)
  }
  let signed_checkpoint = decode_signed_checkpoint(fields[1], codec_limits) catch {
    error => return Err(InventoryWireCodecRefused(error))
  }
  let game_manifest_digest = decode_wire_digest(fields[2], codec_limits) catch {
    error => return Err(InventoryWireCodecRefused(error))
  }
  let max_faults = decode_wire_int(fields[4]) catch {
    error => return Err(InventoryWireCodecRefused(error))
  }
  let proof = decode_inventory_proof(fields[6], codec_limits) catch {
    error => return Err(InventoryWireCodecRefused(error))
  }
  Ok({
    signed_checkpoint,
    game_manifest_digest,
    witnesses,
    max_faults,
    attestations,
    proof,
  })
}
