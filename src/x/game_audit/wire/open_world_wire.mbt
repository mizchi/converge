///|
const OPEN_WORLD_AUDIT_WIRE_VERSION : Int = 1

///|
/// Receiver-side allocation and verification budgets.
///
/// Total byte limits are checked before CBOR parsing. Structural limits are
/// checked before any checkpoint signature or authenticated-map verification.
pub(all) struct OpenWorldAuditWireLimits {
  max_envelope_bytes : Int
  max_gap_request_bytes : Int
  max_gap_response_bytes : Int
  max_text_bytes : Int
  max_proof_steps : Int
  max_gap_response_items : Int
} derive(Eq, Debug)

///|
pub fn OpenWorldAuditWireLimits::default() -> OpenWorldAuditWireLimits {
  OpenWorldAuditWireLimits::{
    max_envelope_bytes: 65536,
    max_gap_request_bytes: 16384,
    max_gap_response_bytes: 1048576,
    max_text_bytes: 4096,
    max_proof_steps: 64,
    max_gap_response_items: 256,
  }
}

///|
pub suberror OpenWorldAuditWireError {
  WireInputTooLarge(Int, Int)
  WireTextTooLarge(Int, Int)
  WireProofTooLong(Int, Int)
  WireGapItemsTooMany(Int, Int)
  WireUnsupportedVersion(Int)
  WireNonCanonicalEncoding
  WireMalformedCbor
  WireInvalidShape
  WireIntegerOutOfRange
} derive(Eq, Debug)

///|
fn wire_int(value : Int) -> @cbor.CborValue {
  if value >= 0 {
    @cbor.CborValue::Uint(value.to_uint64())
  } else {
    @cbor.CborValue::Nint((-1 - value).to_uint64())
  }
}

///|
fn decode_wire_int(
  value : @cbor.CborValue,
) -> Int raise OpenWorldAuditWireError {
  match value {
    @cbor.CborValue::Uint(encoded) => {
      if encoded > 0x7FFFFFFFUL {
        raise WireIntegerOutOfRange
      }
      encoded.to_int()
    }
    @cbor.CborValue::Nint(encoded) => {
      if encoded > 0x7FFFFFFFUL {
        raise WireIntegerOutOfRange
      }
      -1 - encoded.to_int()
    }
    _ => raise WireInvalidShape
  }
}

///|
fn decode_wire_array(
  value : @cbor.CborValue,
  expected_length : Int,
) -> Array[@cbor.CborValue] raise OpenWorldAuditWireError {
  match value {
    @cbor.CborValue::Array(items) => {
      if items.length() != expected_length {
        raise WireInvalidShape
      }
      items
    }
    _ => raise WireInvalidShape
  }
}

///|
fn wire_text_bytes(value : String) -> Int {
  @utf8.encode(value[:]).length()
}

///|
fn decode_wire_text(
  value : @cbor.CborValue,
  limits : OpenWorldAuditWireLimits,
) -> String raise OpenWorldAuditWireError {
  match value {
    @cbor.CborValue::Text(text) => {
      let byte_length = wire_text_bytes(text)
      if byte_length > limits.max_text_bytes {
        raise WireTextTooLarge(byte_length, limits.max_text_bytes)
      }
      text
    }
    _ => raise WireInvalidShape
  }
}

///|
fn decode_wire_digest(
  value : @cbor.CborValue,
  limits : OpenWorldAuditWireLimits,
) -> @bft.Digest raise OpenWorldAuditWireError {
  @bft.Digest(decode_wire_text(value, limits))
}

///|
fn decode_wire_public_key(
  value : @cbor.CborValue,
  limits : OpenWorldAuditWireLimits,
) -> @bft.PublicKey raise OpenWorldAuditWireError {
  @bft.PublicKey(decode_wire_text(value, limits))
}

///|
fn decode_wire_signature(
  value : @cbor.CborValue,
  limits : OpenWorldAuditWireLimits,
) -> @bft.Signature raise OpenWorldAuditWireError {
  @bft.Signature(decode_wire_text(value, limits))
}

///|
fn encode_checkpoint(checkpoint : @checkpoint.Checkpoint) -> @cbor.CborValue {
  let hidden = match checkpoint.hidden_state_commitment {
    None => @cbor.CborValue::Null
    Some(digest) => @cbor.CborValue::Text(digest.0)
  }
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(checkpoint.session_id),
    wire_int(checkpoint.epoch),
    @cbor.CborValue::Text(checkpoint.previous_checkpoint.0),
    @cbor.CborValue::Text(checkpoint.manifest_digest.0),
    @cbor.CborValue::Text(checkpoint.event_root.0),
    @cbor.CborValue::Text(checkpoint.public_state_root.0),
    @cbor.CborValue::Text(checkpoint.asset_delta_root.0),
    hidden,
  ])
}

///|
fn decode_checkpoint(
  value : @cbor.CborValue,
  limits : OpenWorldAuditWireLimits,
) -> @checkpoint.Checkpoint raise OpenWorldAuditWireError {
  let fields = decode_wire_array(value, 8)
  let hidden_state_commitment = match fields[7] {
    @cbor.CborValue::Null => None
    encoded => Some(decode_wire_digest(encoded, limits))
  }
  @checkpoint.Checkpoint::{
    session_id: decode_wire_text(fields[0], limits),
    epoch: decode_wire_int(fields[1]),
    previous_checkpoint: decode_wire_digest(fields[2], limits),
    manifest_digest: decode_wire_digest(fields[3], limits),
    event_root: decode_wire_digest(fields[4], limits),
    public_state_root: decode_wire_digest(fields[5], limits),
    asset_delta_root: decode_wire_digest(fields[6], limits),
    hidden_state_commitment,
  }
}

///|
fn encode_signed_checkpoint(
  signed : @checkpoint.SignedCheckpoint,
) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    encode_checkpoint(signed.checkpoint),
    @cbor.CborValue::Text(signed.digest.0),
    @cbor.CborValue::Text(signed.signature.0),
    @cbor.CborValue::Text(signed.authority_key.0),
  ])
}

///|
fn decode_signed_checkpoint(
  value : @cbor.CborValue,
  limits : OpenWorldAuditWireLimits,
) -> @checkpoint.SignedCheckpoint raise OpenWorldAuditWireError {
  let fields = decode_wire_array(value, 4)
  @checkpoint.SignedCheckpoint::{
    checkpoint: decode_checkpoint(fields[0], limits),
    digest: decode_wire_digest(fields[1], limits),
    signature: decode_wire_signature(fields[2], limits),
    authority_key: decode_wire_public_key(fields[3], limits),
  }
}

///|
fn encode_anchor(
  anchor : @open_world.OpenWorldObserverSigningAnchor,
) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(anchor.observer_id),
    @cbor.CborValue::Text(anchor.signer_key.0),
    @cbor.CborValue::Text(anchor.root.0),
    wire_int(anchor.size),
  ])
}

///|
fn decode_anchor(
  value : @cbor.CborValue,
  limits : OpenWorldAuditWireLimits,
) -> @open_world.OpenWorldObserverSigningAnchor raise OpenWorldAuditWireError {
  let fields = decode_wire_array(value, 4)
  @open_world.OpenWorldObserverSigningAnchor::{
    observer_id: decode_wire_text(fields[0], limits),
    signer_key: decode_wire_public_key(fields[1], limits),
    root: decode_wire_digest(fields[2], limits),
    size: decode_wire_int(fields[3]),
  }
}

///|
fn encode_auth_map_step(step : @authmap.AuthMapStep) -> @cbor.CborValue {
  match step {
    @authmap.AuthMapStep::DescendedLeft(key, value, digest) =>
      @cbor.CborValue::Array([
        wire_int(0),
        @cbor.CborValue::Text(key),
        @cbor.CborValue::Text(value),
        @cbor.CborValue::Text(digest.0),
      ])
    @authmap.AuthMapStep::DescendedRight(key, value, digest) =>
      @cbor.CborValue::Array([
        wire_int(1),
        @cbor.CborValue::Text(key),
        @cbor.CborValue::Text(value),
        @cbor.CborValue::Text(digest.0),
      ])
  }
}

///|
fn decode_auth_map_step(
  value : @cbor.CborValue,
  limits : OpenWorldAuditWireLimits,
) -> @authmap.AuthMapStep raise OpenWorldAuditWireError {
  let fields = decode_wire_array(value, 4)
  let key = decode_wire_text(fields[1], limits)
  let entry_value = decode_wire_text(fields[2], limits)
  let digest = decode_wire_digest(fields[3], limits)
  match decode_wire_int(fields[0]) {
    0 => @authmap.AuthMapStep::DescendedLeft(key, entry_value, digest)
    1 => @authmap.AuthMapStep::DescendedRight(key, entry_value, digest)
    _ => raise WireInvalidShape
  }
}

///|
fn encode_auth_map_proof(proof : @authmap.AuthMapProof) -> @cbor.CborValue {
  let path : Array[@cbor.CborValue] = []
  for step in proof.path {
    path.push(encode_auth_map_step(step))
  }
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(proof.key),
    @cbor.CborValue::Text(proof.value),
    @cbor.CborValue::Text(proof.left_digest.0),
    @cbor.CborValue::Text(proof.right_digest.0),
    wire_int(proof.entry_count),
    @cbor.CborValue::Array(path),
  ])
}

///|
fn decode_auth_map_proof(
  value : @cbor.CborValue,
  limits : OpenWorldAuditWireLimits,
) -> @authmap.AuthMapProof raise OpenWorldAuditWireError {
  let fields = decode_wire_array(value, 6)
  let encoded_path = match fields[5] {
    @cbor.CborValue::Array(path) => path
    _ => raise WireInvalidShape
  }
  if encoded_path.length() > limits.max_proof_steps {
    raise WireProofTooLong(encoded_path.length(), limits.max_proof_steps)
  }
  let path : Array[@authmap.AuthMapStep] = []
  for step in encoded_path {
    path.push(decode_auth_map_step(step, limits))
  }
  @authmap.AuthMapProof::{
    key: decode_wire_text(fields[0], limits),
    value: decode_wire_text(fields[1], limits),
    left_digest: decode_wire_digest(fields[2], limits),
    right_digest: decode_wire_digest(fields[3], limits),
    entry_count: decode_wire_int(fields[4]),
    path,
  }
}

///|
fn encode_anchor_envelope_value(
  envelope : @open_world.OpenWorldObserverSigningAnchorEnvelope,
) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    wire_int(OPEN_WORLD_AUDIT_WIRE_VERSION),
    encode_signed_checkpoint(envelope.signed_checkpoint),
    encode_anchor(envelope.anchor),
    encode_auth_map_proof(envelope.membership_proof),
  ])
}

///|
fn decode_wire_version(
  value : @cbor.CborValue,
) -> Unit raise OpenWorldAuditWireError {
  let version = decode_wire_int(value)
  if version != OPEN_WORLD_AUDIT_WIRE_VERSION {
    raise WireUnsupportedVersion(version)
  }
}

///|
fn decode_anchor_envelope_value(
  value : @cbor.CborValue,
  limits : OpenWorldAuditWireLimits,
) -> @open_world.OpenWorldObserverSigningAnchorEnvelope raise OpenWorldAuditWireError {
  let fields = decode_wire_array(value, 4)
  decode_wire_version(fields[0])
  @open_world.OpenWorldObserverSigningAnchorEnvelope::{
    signed_checkpoint: decode_signed_checkpoint(fields[1], limits),
    anchor: decode_anchor(fields[2], limits),
    membership_proof: decode_auth_map_proof(fields[3], limits),
  }
}

///|
priv struct OpenWorldWireCborPreflight {
  input : Bytes
  mut position : Int
}

///|
fn OpenWorldWireCborPreflight::remaining(
  self : OpenWorldWireCborPreflight,
) -> Int {
  self.input.length() - self.position
}

///|
fn OpenWorldWireCborPreflight::read_byte(
  self : OpenWorldWireCborPreflight,
) -> Byte raise OpenWorldAuditWireError {
  if self.position >= self.input.length() {
    raise WireMalformedCbor
  }
  let value = self.input[self.position]
  self.position += 1
  value
}

///|
fn OpenWorldWireCborPreflight::read_uint(
  self : OpenWorldWireCborPreflight,
  byte_count : Int,
) -> UInt64 raise OpenWorldAuditWireError {
  if byte_count < 0 || byte_count > self.remaining() {
    raise WireMalformedCbor
  }
  let mut value = 0UL
  for _ in 0..<byte_count {
    value = (value << 8) | self.read_byte().to_uint64()
  }
  value
}

///|
fn OpenWorldWireCborPreflight::skip_declared_bytes(
  self : OpenWorldWireCborPreflight,
  byte_count : UInt64,
) -> Unit raise OpenWorldAuditWireError {
  if byte_count > self.remaining().to_uint64() {
    raise WireMalformedCbor
  }
  self.position += byte_count.to_int()
}

///|
fn OpenWorldWireCborPreflight::scan_value(
  self : OpenWorldWireCborPreflight,
  depth : Int,
) -> Unit raise OpenWorldAuditWireError {
  if depth > 64 {
    raise WireMalformedCbor
  }
  let initial = self.read_byte().to_int()
  let major_type = (initial >> 5) & 0x07
  let additional = initial & 0x1F
  if additional == 31 || (additional >= 28 && additional <= 30) {
    raise WireMalformedCbor
  }
  let argument = if additional < 24 {
    additional.to_uint64()
  } else {
    let argument_bytes = match additional {
      24 => 1
      25 => 2
      26 => 4
      27 => 8
      _ => raise WireMalformedCbor
    }
    self.read_uint(argument_bytes)
  }
  match major_type {
    0 | 1 => ()
    2 | 3 => self.skip_declared_bytes(argument)
    4 => {
      if argument > self.remaining().to_uint64() {
        raise WireMalformedCbor
      }
      for _ in 0..<argument.to_int() {
        self.scan_value(depth + 1)
      }
    }
    5 => {
      if argument > (self.remaining() / 2).to_uint64() {
        raise WireMalformedCbor
      }
      for _ in 0..<argument.to_int() {
        self.scan_value(depth + 1)
        self.scan_value(depth + 1)
      }
    }
    6 => self.scan_value(depth + 1)
    7 => ()
    _ => raise WireMalformedCbor
  }
}

///|
fn preflight_cbor(input : Bytes) -> Unit raise OpenWorldAuditWireError {
  let scanner = OpenWorldWireCborPreflight::{ input, position: 0 }
  scanner.scan_value(0)
  if scanner.position != input.length() {
    raise WireMalformedCbor
  }
}

///|
fn decode_canonical_cbor(
  input : Bytes,
) -> @cbor.CborValue raise OpenWorldAuditWireError {
  preflight_cbor(input)
  let value = @cbor.decode(input) catch { _ => raise WireMalformedCbor }
  if @cbor.encode(value) != input {
    raise WireNonCanonicalEncoding
  }
  value
}

///|
fn check_wire_size(
  actual : Int,
  maximum : Int,
) -> Unit raise OpenWorldAuditWireError {
  if actual > maximum {
    raise WireInputTooLarge(actual, maximum)
  }
}

///|
pub fn encode_open_world_observer_signing_anchor_envelope(
  envelope : @open_world.OpenWorldObserverSigningAnchorEnvelope,
) -> Bytes {
  @cbor.encode(encode_anchor_envelope_value(envelope))
}

///|
pub fn decode_open_world_observer_signing_anchor_envelope(
  input : Bytes,
  limits~ : OpenWorldAuditWireLimits,
) -> Result[
  @open_world.OpenWorldObserverSigningAnchorEnvelope,
  OpenWorldAuditWireError,
] {
  try {
    check_wire_size(input.length(), limits.max_envelope_bytes)
    decode_anchor_envelope_value(decode_canonical_cbor(input), limits) |> Ok
  } catch {
    error => Err(error)
  }
}

///|
fn encode_gap_request_value(
  request : @open_world.OpenWorldObserverSigningAnchorGapRequest,
) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    wire_int(OPEN_WORLD_AUDIT_WIRE_VERSION),
    @cbor.CborValue::Text(request.log_session_id),
    @cbor.CborValue::Text(request.publisher_key.0),
    wire_int(request.after_epoch),
    @cbor.CborValue::Text(request.after_checkpoint_digest.0),
    wire_int(request.target_epoch),
    wire_int(request.max_items),
  ])
}

///|
pub fn encode_open_world_observer_signing_anchor_gap_request(
  request : @open_world.OpenWorldObserverSigningAnchorGapRequest,
) -> Bytes {
  @cbor.encode(encode_gap_request_value(request))
}

///|
fn decode_gap_request_value(
  value : @cbor.CborValue,
  limits : OpenWorldAuditWireLimits,
) -> @open_world.OpenWorldObserverSigningAnchorGapRequest raise OpenWorldAuditWireError {
  let fields = decode_wire_array(value, 7)
  decode_wire_version(fields[0])
  let max_items = decode_wire_int(fields[6])
  if max_items > limits.max_gap_response_items {
    raise WireGapItemsTooMany(max_items, limits.max_gap_response_items)
  }
  @open_world.OpenWorldObserverSigningAnchorGapRequest::{
    log_session_id: decode_wire_text(fields[1], limits),
    publisher_key: decode_wire_public_key(fields[2], limits),
    after_epoch: decode_wire_int(fields[3]),
    after_checkpoint_digest: decode_wire_digest(fields[4], limits),
    target_epoch: decode_wire_int(fields[5]),
    max_items,
  }
}

///|
pub fn decode_open_world_observer_signing_anchor_gap_request(
  input : Bytes,
  limits~ : OpenWorldAuditWireLimits,
) -> Result[
  @open_world.OpenWorldObserverSigningAnchorGapRequest,
  OpenWorldAuditWireError,
] {
  try {
    check_wire_size(input.length(), limits.max_gap_request_bytes)
    decode_gap_request_value(decode_canonical_cbor(input), limits) |> Ok
  } catch {
    error => Err(error)
  }
}

///|
fn encode_gap_response_value(
  response : @open_world.OpenWorldObserverSigningAnchorGapResponse,
) -> @cbor.CborValue {
  let envelopes : Array[@cbor.CborValue] = []
  for envelope in response.envelopes {
    envelopes.push(encode_anchor_envelope_value(envelope))
  }
  @cbor.CborValue::Array([
    wire_int(OPEN_WORLD_AUDIT_WIRE_VERSION),
    @cbor.CborValue::Array(envelopes),
  ])
}

///|
pub fn encode_open_world_observer_signing_anchor_gap_response(
  response : @open_world.OpenWorldObserverSigningAnchorGapResponse,
) -> Bytes {
  @cbor.encode(encode_gap_response_value(response))
}

///|
fn decode_gap_response_value(
  value : @cbor.CborValue,
  limits : OpenWorldAuditWireLimits,
) -> @open_world.OpenWorldObserverSigningAnchorGapResponse raise OpenWorldAuditWireError {
  let fields = decode_wire_array(value, 2)
  decode_wire_version(fields[0])
  let encoded_envelopes = match fields[1] {
    @cbor.CborValue::Array(envelopes) => envelopes
    _ => raise WireInvalidShape
  }
  if encoded_envelopes.length() > limits.max_gap_response_items {
    raise WireGapItemsTooMany(
      encoded_envelopes.length(),
      limits.max_gap_response_items,
    )
  }
  let envelopes : Array[@open_world.OpenWorldObserverSigningAnchorEnvelope] = []
  for encoded in encoded_envelopes {
    check_wire_size(@cbor.encode(encoded).length(), limits.max_envelope_bytes)
    envelopes.push(decode_anchor_envelope_value(encoded, limits))
  }
  @open_world.OpenWorldObserverSigningAnchorGapResponse::{ envelopes, }
}

///|
pub fn decode_open_world_observer_signing_anchor_gap_response(
  input : Bytes,
  limits~ : OpenWorldAuditWireLimits,
) -> Result[
  @open_world.OpenWorldObserverSigningAnchorGapResponse,
  OpenWorldAuditWireError,
] {
  try {
    check_wire_size(input.length(), limits.max_gap_response_bytes)
    decode_gap_response_value(decode_canonical_cbor(input), limits) |> Ok
  } catch {
    error => Err(error)
  }
}
