///|
const PVE_REPLAY_WIRE_VERSION : Int = 2

///|
/// A signed dodge pair as transported to a deterministic PvE replay worker.
/// Signed events remain untrusted until the central replay verifier admits
/// them through the BFT adapter.
pub(all) struct PveReplayDodgeEvidence {
  input : @bft.SignedEvent
  receipt : @bft.SignedEvent
  intent : @replay.DodgeIntent
  observed : @replay.DodgeReceipt
}

///|
/// Complete wire evidence for one precommitted attack.
pub(all) struct PveReplayAttackTranscript {
  attack_id : String
  telegraph : @bft.SignedEvent
  dodge_evidence : Array[PveReplayDodgeEvidence]
}

///|
/// An authority-signed asset declaration replayed only after the encounter
/// outcome is known. The source is untrusted until admitted by the same BFT
/// event graph as the combat transcript.
pub(all) struct PveReplayAssetEffectEvidence {
  source : @bft.SignedEvent
  effect : @replay.AssetEffect
}

///|
/// Versioned input for one complete deterministic PvE checkpoint replay.
pub(all) struct PveReplayBundle {
  authority_peer_id : String
  signed_checkpoint : @checkpoint.SignedCheckpoint
  config : @replay.DungeonEncounterConfig
  players : Array[@replay.DungeonPlayer]
  attacks : Array[@replay.DungeonEncounterAttack]
  transcripts : Array[PveReplayAttackTranscript]
  asset_effects : Array[PveReplayAssetEffectEvidence]
}

///|
/// Receiver-side resource budgets checked before authentication and replay.
pub(all) struct PveReplayWireLimits {
  max_bundle_bytes : Int
  max_text_bytes : Int
  max_players : Int
  max_attacks : Int
  max_transcripts : Int
  max_total_dodge_evidence : Int
  max_asset_effects : Int
  max_dependencies_per_event : Int
  max_values_per_operation : Int
} derive(Eq, Debug)

///|
pub fn PveReplayWireLimits::default() -> PveReplayWireLimits {
  {
    max_bundle_bytes: 1048576,
    max_text_bytes: 4096,
    max_players: 64,
    max_attacks: 256,
    max_transcripts: 256,
    max_total_dodge_evidence: 4096,
    max_asset_effects: 256,
    max_dependencies_per_event: 64,
    max_values_per_operation: 16,
  }
}

///|
pub suberror PveReplayWireError {
  PveWireInputTooLarge(Int, Int)
  PveWireTextTooLarge(Int, Int)
  PveWirePlayersTooMany(Int, Int)
  PveWireAttacksTooMany(Int, Int)
  PveWireTranscriptsTooMany(Int, Int)
  PveWireDodgeEvidenceTooMany(Int, Int)
  PveWireAssetEffectsTooMany(Int, Int)
  PveWireDependenciesTooMany(Int, Int)
  PveWireValuesTooMany(Int, Int)
  PveWireUnsupportedVersion(Int)
  PveWireNonCanonicalEncoding
  PveWireMalformedCbor
  PveWireInvalidShape
  PveWireIntegerOutOfRange
} derive(Eq, Debug)

///|
fn pve_wire_int(value : Int) -> @cbor.CborValue {
  if value >= 0 {
    @cbor.CborValue::Uint(value.to_uint64())
  } else {
    @cbor.CborValue::Nint((-1 - value).to_uint64())
  }
}

///|
fn decode_pve_wire_int(value : @cbor.CborValue) -> Int raise PveReplayWireError {
  match value {
    @cbor.CborValue::Uint(encoded) => {
      if encoded > 0x7FFFFFFFUL {
        raise PveWireIntegerOutOfRange
      }
      encoded.to_int()
    }
    @cbor.CborValue::Nint(encoded) => {
      if encoded > 0x7FFFFFFFUL {
        raise PveWireIntegerOutOfRange
      }
      -1 - encoded.to_int()
    }
    _ => raise PveWireInvalidShape
  }
}

///|
fn decode_pve_wire_array(
  value : @cbor.CborValue,
  expected_length : Int,
) -> Array[@cbor.CborValue] raise PveReplayWireError {
  match value {
    @cbor.CborValue::Array(items) => {
      if items.length() != expected_length {
        raise PveWireInvalidShape
      }
      items
    }
    _ => raise PveWireInvalidShape
  }
}

///|
fn decode_pve_wire_items(
  value : @cbor.CborValue,
) -> Array[@cbor.CborValue] raise PveReplayWireError {
  match value {
    @cbor.CborValue::Array(items) => items
    _ => raise PveWireInvalidShape
  }
}

///|
fn decode_pve_wire_text(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> String raise PveReplayWireError {
  match value {
    @cbor.CborValue::Text(text) => {
      let length = @utf8.encode(text[:]).length()
      if length > limits.max_text_bytes {
        raise PveWireTextTooLarge(length, limits.max_text_bytes)
      }
      text
    }
    _ => raise PveWireInvalidShape
  }
}

///|
fn pve_check_count(
  actual : Int,
  maximum : Int,
  error : (Int, Int) -> PveReplayWireError,
) -> Unit raise PveReplayWireError {
  if actual > maximum {
    raise error(actual, maximum)
  }
}

///|
fn encode_pve_event_id(id : @types.EventId) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(id.peer.0),
    pve_wire_int(id.counter),
  ])
}

///|
fn decode_pve_event_id(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @types.EventId raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 2)
  {
    peer: @types.PeerId(decode_pve_wire_text(fields[0], limits)),
    counter: decode_pve_wire_int(fields[1]),
  }
}

///|
fn encode_pve_value(value : @types.Value) -> @cbor.CborValue {
  match value {
    Null => @cbor.CborValue::Array([pve_wire_int(0)])
    Bool(value) =>
      @cbor.CborValue::Array([pve_wire_int(1), @cbor.CborValue::Bool(value)])
    Int(value) => @cbor.CborValue::Array([pve_wire_int(2), pve_wire_int(value)])
    Float(value) =>
      @cbor.CborValue::Array([pve_wire_int(3), @cbor.CborValue::Float(value)])
    Str(value) =>
      @cbor.CborValue::Array([pve_wire_int(4), @cbor.CborValue::Text(value)])
  }
}

///|
fn decode_pve_value(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @types.Value raise PveReplayWireError {
  let fields = decode_pve_wire_items(value)
  if fields.length() == 0 {
    raise PveWireInvalidShape
  }
  match decode_pve_wire_int(fields[0]) {
    0 => {
      if fields.length() != 1 {
        raise PveWireInvalidShape
      }
      @types.Value::Null
    }
    1 => {
      if fields.length() != 2 {
        raise PveWireInvalidShape
      }
      match fields[1] {
        @cbor.CborValue::Bool(value) => @types.Value::Bool(value)
        _ => raise PveWireInvalidShape
      }
    }
    2 => {
      if fields.length() != 2 {
        raise PveWireInvalidShape
      }
      @types.Value::Int(decode_pve_wire_int(fields[1]))
    }
    3 => {
      if fields.length() != 2 {
        raise PveWireInvalidShape
      }
      match fields[1] {
        @cbor.CborValue::Float(value) => @types.Value::Float(value)
        _ => raise PveWireInvalidShape
      }
    }
    4 => {
      if fields.length() != 2 {
        raise PveWireInvalidShape
      }
      @types.Value::Str(decode_pve_wire_text(fields[1], limits))
    }
    _ => raise PveWireInvalidShape
  }
}

///|
fn encode_pve_row_op(op : @types.RowOp) -> @cbor.CborValue {
  match op {
    Insert(tbl~, row_id~, values~) => {
      let encoded_values : Array[@cbor.CborValue] = []
      for entry in values {
        encoded_values.push(
          @cbor.CborValue::Array([
            @cbor.CborValue::Text(entry.0),
            encode_pve_value(entry.1),
          ]),
        )
      }
      @cbor.CborValue::Array([
        pve_wire_int(0),
        @cbor.CborValue::Text(tbl),
        @cbor.CborValue::Text(row_id),
        @cbor.CborValue::Array(encoded_values),
      ])
    }
    Update(tbl~, row_id~, col~, value~) =>
      @cbor.CborValue::Array([
        pve_wire_int(1),
        @cbor.CborValue::Text(tbl),
        @cbor.CborValue::Text(row_id),
        @cbor.CborValue::Text(col),
        encode_pve_value(value),
      ])
    Delete(tbl~, row_id~) =>
      @cbor.CborValue::Array([
        pve_wire_int(2),
        @cbor.CborValue::Text(tbl),
        @cbor.CborValue::Text(row_id),
      ])
  }
}

///|
fn decode_pve_row_op(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @types.RowOp raise PveReplayWireError {
  let fields = decode_pve_wire_items(value)
  if fields.length() == 0 {
    raise PveWireInvalidShape
  }
  match decode_pve_wire_int(fields[0]) {
    0 => {
      if fields.length() != 4 {
        raise PveWireInvalidShape
      }
      let encoded_values = decode_pve_wire_items(fields[3])
      pve_check_count(
        encoded_values.length(),
        limits.max_values_per_operation,
        fn(actual, maximum) { PveWireValuesTooMany(actual, maximum) },
      )
      let values : Array[(String, @types.Value)] = []
      for encoded in encoded_values {
        let entry = decode_pve_wire_array(encoded, 2)
        values.push(
          (
            decode_pve_wire_text(entry[0], limits),
            decode_pve_value(entry[1], limits),
          ),
        )
      }
      @types.RowOp::Insert(
        tbl=decode_pve_wire_text(fields[1], limits),
        row_id=decode_pve_wire_text(fields[2], limits),
        values~,
      )
    }
    1 => {
      if fields.length() != 5 {
        raise PveWireInvalidShape
      }
      @types.RowOp::Update(
        tbl=decode_pve_wire_text(fields[1], limits),
        row_id=decode_pve_wire_text(fields[2], limits),
        col=decode_pve_wire_text(fields[3], limits),
        value=decode_pve_value(fields[4], limits),
      )
    }
    2 => {
      if fields.length() != 3 {
        raise PveWireInvalidShape
      }
      @types.RowOp::Delete(
        tbl=decode_pve_wire_text(fields[1], limits),
        row_id=decode_pve_wire_text(fields[2], limits),
      )
    }
    _ => raise PveWireInvalidShape
  }
}

///|
fn encode_pve_event(event : @types.Event) -> @cbor.CborValue {
  let dependencies : Array[@cbor.CborValue] = []
  for dependency in event.deps {
    dependencies.push(encode_pve_event_id(dependency))
  }
  @cbor.CborValue::Array([
    encode_pve_event_id(event.id),
    @cbor.CborValue::Array(dependencies),
    pve_wire_int(event.lamport),
    encode_pve_row_op(event.op),
  ])
}

///|
fn decode_pve_event(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @types.Event raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 4)
  let encoded_dependencies = decode_pve_wire_items(fields[1])
  pve_check_count(
    encoded_dependencies.length(),
    limits.max_dependencies_per_event,
    fn(actual, maximum) { PveWireDependenciesTooMany(actual, maximum) },
  )
  let dependencies : Array[@types.EventId] = []
  for encoded in encoded_dependencies {
    dependencies.push(decode_pve_event_id(encoded, limits))
  }
  {
    id: decode_pve_event_id(fields[0], limits),
    deps: dependencies,
    lamport: decode_pve_wire_int(fields[2]),
    op: decode_pve_row_op(fields[3], limits),
  }
}

///|
fn encode_pve_signed_event(signed : @bft.SignedEvent) -> @cbor.CborValue {
  let dependencies : Array[@cbor.CborValue] = []
  for dependency in signed.dep_hashes {
    dependencies.push(@cbor.CborValue::Text(dependency.0))
  }
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(signed.session_id),
    @cbor.CborValue::Text(signed.digest.0),
    @cbor.CborValue::Text(signed.signature.0),
    @cbor.CborValue::Text(signed.author_key.0),
    @cbor.CborValue::Array(dependencies),
    encode_pve_event(signed.event),
  ])
}

///|
fn decode_pve_signed_event(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @bft.SignedEvent raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 6)
  let encoded_dependencies = decode_pve_wire_items(fields[4])
  pve_check_count(
    encoded_dependencies.length(),
    limits.max_dependencies_per_event,
    fn(actual, maximum) { PveWireDependenciesTooMany(actual, maximum) },
  )
  let dependencies : Array[@bft.Digest] = []
  for encoded in encoded_dependencies {
    dependencies.push(@bft.Digest(decode_pve_wire_text(encoded, limits)))
  }
  {
    session_id: decode_pve_wire_text(fields[0], limits),
    digest: @bft.Digest(decode_pve_wire_text(fields[1], limits)),
    signature: @bft.Signature(decode_pve_wire_text(fields[2], limits)),
    author_key: @bft.PublicKey(decode_pve_wire_text(fields[3], limits)),
    dep_hashes: dependencies,
    event: decode_pve_event(fields[5], limits),
  }
}

///|
fn encode_pve_checkpoint(
  checkpoint : @checkpoint.Checkpoint,
) -> @cbor.CborValue {
  let hidden = match checkpoint.hidden_state_commitment {
    Some(digest) => @cbor.CborValue::Text(digest.0)
    None => @cbor.CborValue::Null
  }
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(checkpoint.session_id),
    pve_wire_int(checkpoint.epoch),
    @cbor.CborValue::Text(checkpoint.previous_checkpoint.0),
    @cbor.CborValue::Text(checkpoint.manifest_digest.0),
    @cbor.CborValue::Text(checkpoint.event_root.0),
    @cbor.CborValue::Text(checkpoint.public_state_root.0),
    @cbor.CborValue::Text(checkpoint.asset_delta_root.0),
    hidden,
  ])
}

///|
fn decode_pve_checkpoint(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @checkpoint.Checkpoint raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 8)
  let hidden_state_commitment = match fields[7] {
    @cbor.CborValue::Null => None
    encoded => Some(@bft.Digest(decode_pve_wire_text(encoded, limits)))
  }
  {
    session_id: decode_pve_wire_text(fields[0], limits),
    epoch: decode_pve_wire_int(fields[1]),
    previous_checkpoint: @bft.Digest(decode_pve_wire_text(fields[2], limits)),
    manifest_digest: @bft.Digest(decode_pve_wire_text(fields[3], limits)),
    event_root: @bft.Digest(decode_pve_wire_text(fields[4], limits)),
    public_state_root: @bft.Digest(decode_pve_wire_text(fields[5], limits)),
    asset_delta_root: @bft.Digest(decode_pve_wire_text(fields[6], limits)),
    hidden_state_commitment,
  }
}

///|
fn encode_pve_signed_checkpoint(
  signed : @checkpoint.SignedCheckpoint,
) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    encode_pve_checkpoint(signed.checkpoint),
    @cbor.CborValue::Text(signed.digest.0),
    @cbor.CborValue::Text(signed.signature.0),
    @cbor.CborValue::Text(signed.authority_key.0),
  ])
}

///|
fn decode_pve_signed_checkpoint(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @checkpoint.SignedCheckpoint raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 4)
  {
    checkpoint: decode_pve_checkpoint(fields[0], limits),
    digest: @bft.Digest(decode_pve_wire_text(fields[1], limits)),
    signature: @bft.Signature(decode_pve_wire_text(fields[2], limits)),
    authority_key: @bft.PublicKey(decode_pve_wire_text(fields[3], limits)),
  }
}

///|
fn encode_pve_config(
  config : @replay.DungeonEncounterConfig,
) -> @cbor.CborValue {
  let rules = config.attack_rules
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(config.encounter_id),
    pve_wire_int(config.player_max_hp),
    @cbor.CborValue::Array([
      pve_wire_int(rules.min_reaction_ticks),
      pve_wire_int(rules.max_backdate_ticks),
      pve_wire_int(rules.max_dodge_distance),
      pve_wire_int(rules.arena_min_x),
      pve_wire_int(rules.arena_max_x),
      @cbor.CborValue::Text(rules.loot_item_type),
    ]),
  ])
}

///|
fn decode_pve_config(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @replay.DungeonEncounterConfig raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 3)
  let rules = decode_pve_wire_array(fields[2], 6)
  {
    encounter_id: decode_pve_wire_text(fields[0], limits),
    player_max_hp: decode_pve_wire_int(fields[1]),
    attack_rules: {
      min_reaction_ticks: decode_pve_wire_int(rules[0]),
      max_backdate_ticks: decode_pve_wire_int(rules[1]),
      max_dodge_distance: decode_pve_wire_int(rules[2]),
      arena_min_x: decode_pve_wire_int(rules[3]),
      arena_max_x: decode_pve_wire_int(rules[4]),
      loot_item_type: decode_pve_wire_text(rules[5], limits),
    },
  }
}

///|
fn encode_pve_player(player : @replay.DungeonPlayer) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(player.player_id),
    @cbor.CborValue::Text(player.public_key.0),
    pve_wire_int(player.initial_x),
  ])
}

///|
fn decode_pve_player(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @replay.DungeonPlayer raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 3)
  {
    player_id: decode_pve_wire_text(fields[0], limits),
    public_key: @bft.PublicKey(decode_pve_wire_text(fields[1], limits)),
    initial_x: decode_pve_wire_int(fields[2]),
  }
}

///|
fn encode_pve_attack(spec : @replay.DungeonEncounterAttack) -> @cbor.CborValue {
  let attack = spec.attack
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(attack.attack_id),
    pve_wire_int(attack.visible_tick),
    pve_wire_int(attack.resolve_tick),
    pve_wire_int(attack.center_x),
    pve_wire_int(attack.radius),
    pve_wire_int(spec.damage),
  ])
}

///|
fn decode_pve_attack(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @replay.DungeonEncounterAttack raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 6)
  {
    attack: {
      attack_id: decode_pve_wire_text(fields[0], limits),
      visible_tick: decode_pve_wire_int(fields[1]),
      resolve_tick: decode_pve_wire_int(fields[2]),
      center_x: decode_pve_wire_int(fields[3]),
      radius: decode_pve_wire_int(fields[4]),
    },
    damage: decode_pve_wire_int(fields[5]),
  }
}

///|
fn encode_pve_dodge_intent(intent : @replay.DodgeIntent) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(intent.attack_id),
    @cbor.CborValue::Text(intent.player_id),
    @cbor.CborValue::Text(intent.telegraph_digest.0),
    pve_wire_int(intent.client_tick),
    pve_wire_int(intent.to_x),
  ])
}

///|
fn decode_pve_dodge_intent(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @replay.DodgeIntent raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 5)
  {
    attack_id: decode_pve_wire_text(fields[0], limits),
    player_id: decode_pve_wire_text(fields[1], limits),
    telegraph_digest: @bft.Digest(decode_pve_wire_text(fields[2], limits)),
    client_tick: decode_pve_wire_int(fields[3]),
    to_x: decode_pve_wire_int(fields[4]),
  }
}

///|
fn encode_pve_dodge_receipt(receipt : @replay.DodgeReceipt) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(receipt.input_digest.0),
    pve_wire_int(receipt.received_tick),
  ])
}

///|
fn decode_pve_dodge_receipt(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @replay.DodgeReceipt raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 2)
  {
    input_digest: @bft.Digest(decode_pve_wire_text(fields[0], limits)),
    received_tick: decode_pve_wire_int(fields[1]),
  }
}

///|
fn encode_pve_evidence(evidence : PveReplayDodgeEvidence) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    encode_pve_signed_event(evidence.input),
    encode_pve_signed_event(evidence.receipt),
    encode_pve_dodge_intent(evidence.intent),
    encode_pve_dodge_receipt(evidence.observed),
  ])
}

///|
fn decode_pve_evidence(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> PveReplayDodgeEvidence raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 4)
  {
    input: decode_pve_signed_event(fields[0], limits),
    receipt: decode_pve_signed_event(fields[1], limits),
    intent: decode_pve_dodge_intent(fields[2], limits),
    observed: decode_pve_dodge_receipt(fields[3], limits),
  }
}

///|
fn encode_pve_transcript(
  transcript : PveReplayAttackTranscript,
) -> @cbor.CborValue {
  let evidence : Array[@cbor.CborValue] = []
  for item in transcript.dodge_evidence {
    evidence.push(encode_pve_evidence(item))
  }
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(transcript.attack_id),
    encode_pve_signed_event(transcript.telegraph),
    @cbor.CborValue::Array(evidence),
  ])
}

///|
fn decode_pve_transcript(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> PveReplayAttackTranscript raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 3)
  let encoded_evidence = decode_pve_wire_items(fields[2])
  let evidence : Array[PveReplayDodgeEvidence] = []
  for item in encoded_evidence {
    evidence.push(decode_pve_evidence(item, limits))
  }
  {
    attack_id: decode_pve_wire_text(fields[0], limits),
    telegraph: decode_pve_signed_event(fields[1], limits),
    dodge_evidence: evidence,
  }
}

///|
fn encode_pve_asset_effect(effect : @replay.AssetEffect) -> @cbor.CborValue {
  match effect {
    Create(asset_id~, recipient_id~, item_type~, quantity~, output_index~) =>
      @cbor.CborValue::Array([
        pve_wire_int(0),
        @cbor.CborValue::Text(asset_id),
        @cbor.CborValue::Text(recipient_id),
        @cbor.CborValue::Text(item_type),
        pve_wire_int(quantity),
        pve_wire_int(output_index),
      ])
    Transfer(asset_id~, from_owner~, to_owner~, expected_version~) =>
      @cbor.CborValue::Array([
        pve_wire_int(1),
        @cbor.CborValue::Text(asset_id),
        @cbor.CborValue::Text(from_owner),
        @cbor.CborValue::Text(to_owner),
        pve_wire_int(expected_version),
      ])
  }
}

///|
fn decode_pve_asset_effect(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @replay.AssetEffect raise PveReplayWireError {
  let fields = decode_pve_wire_items(value)
  if fields.length() == 0 {
    raise PveWireInvalidShape
  }
  match decode_pve_wire_int(fields[0]) {
    0 => {
      if fields.length() != 6 {
        raise PveWireInvalidShape
      }
      @replay.AssetEffect::Create(
        asset_id=decode_pve_wire_text(fields[1], limits),
        recipient_id=decode_pve_wire_text(fields[2], limits),
        item_type=decode_pve_wire_text(fields[3], limits),
        quantity=decode_pve_wire_int(fields[4]),
        output_index=decode_pve_wire_int(fields[5]),
      )
    }
    1 => {
      if fields.length() != 5 {
        raise PveWireInvalidShape
      }
      @replay.AssetEffect::Transfer(
        asset_id=decode_pve_wire_text(fields[1], limits),
        from_owner=decode_pve_wire_text(fields[2], limits),
        to_owner=decode_pve_wire_text(fields[3], limits),
        expected_version=decode_pve_wire_int(fields[4]),
      )
    }
    _ => raise PveWireInvalidShape
  }
}

///|
fn encode_pve_asset_evidence(
  evidence : PveReplayAssetEffectEvidence,
) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    encode_pve_signed_event(evidence.source),
    encode_pve_asset_effect(evidence.effect),
  ])
}

///|
fn decode_pve_asset_evidence(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> PveReplayAssetEffectEvidence raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 2)
  {
    source: decode_pve_signed_event(fields[0], limits),
    effect: decode_pve_asset_effect(fields[1], limits),
  }
}

///|
fn encode_pve_bundle_value(bundle : PveReplayBundle) -> @cbor.CborValue {
  let players : Array[@cbor.CborValue] = []
  for player in bundle.players {
    players.push(encode_pve_player(player))
  }
  let attacks : Array[@cbor.CborValue] = []
  for attack in bundle.attacks {
    attacks.push(encode_pve_attack(attack))
  }
  let transcripts : Array[@cbor.CborValue] = []
  for transcript in bundle.transcripts {
    transcripts.push(encode_pve_transcript(transcript))
  }
  let asset_effects : Array[@cbor.CborValue] = []
  for evidence in bundle.asset_effects {
    asset_effects.push(encode_pve_asset_evidence(evidence))
  }
  @cbor.CborValue::Array([
    pve_wire_int(PVE_REPLAY_WIRE_VERSION),
    @cbor.CborValue::Text(bundle.authority_peer_id),
    encode_pve_signed_checkpoint(bundle.signed_checkpoint),
    encode_pve_config(bundle.config),
    @cbor.CborValue::Array(players),
    @cbor.CborValue::Array(attacks),
    @cbor.CborValue::Array(transcripts),
    @cbor.CborValue::Array(asset_effects),
  ])
}

///|
fn decode_pve_bundle_value(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> PveReplayBundle raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 8)
  let version = decode_pve_wire_int(fields[0])
  if version != PVE_REPLAY_WIRE_VERSION {
    raise PveWireUnsupportedVersion(version)
  }
  let encoded_players = decode_pve_wire_items(fields[4])
  pve_check_count(encoded_players.length(), limits.max_players, fn(
    actual,
    maximum,
  ) {
    PveWirePlayersTooMany(actual, maximum)
  })
  let encoded_attacks = decode_pve_wire_items(fields[5])
  pve_check_count(encoded_attacks.length(), limits.max_attacks, fn(
    actual,
    maximum,
  ) {
    PveWireAttacksTooMany(actual, maximum)
  })
  let encoded_transcripts = decode_pve_wire_items(fields[6])
  pve_check_count(encoded_transcripts.length(), limits.max_transcripts, fn(
    actual,
    maximum,
  ) {
    PveWireTranscriptsTooMany(actual, maximum)
  })
  let encoded_asset_effects = decode_pve_wire_items(fields[7])
  pve_check_count(encoded_asset_effects.length(), limits.max_asset_effects, fn(
    actual,
    maximum,
  ) {
    PveWireAssetEffectsTooMany(actual, maximum)
  })
  let players : Array[@replay.DungeonPlayer] = []
  for encoded in encoded_players {
    players.push(decode_pve_player(encoded, limits))
  }
  let attacks : Array[@replay.DungeonEncounterAttack] = []
  for encoded in encoded_attacks {
    attacks.push(decode_pve_attack(encoded, limits))
  }
  let transcripts : Array[PveReplayAttackTranscript] = []
  let mut total_evidence = 0
  for encoded in encoded_transcripts {
    let transcript = decode_pve_transcript(encoded, limits)
    total_evidence += transcript.dodge_evidence.length()
    pve_check_count(total_evidence, limits.max_total_dodge_evidence, fn(
      actual,
      maximum,
    ) {
      PveWireDodgeEvidenceTooMany(actual, maximum)
    })
    transcripts.push(transcript)
  }
  let asset_effects : Array[PveReplayAssetEffectEvidence] = []
  for encoded in encoded_asset_effects {
    asset_effects.push(decode_pve_asset_evidence(encoded, limits))
  }
  {
    authority_peer_id: decode_pve_wire_text(fields[1], limits),
    signed_checkpoint: decode_pve_signed_checkpoint(fields[2], limits),
    config: decode_pve_config(fields[3], limits),
    players,
    attacks,
    transcripts,
    asset_effects,
  }
}

///|
pub fn encode_pve_replay_bundle(bundle : PveReplayBundle) -> Bytes {
  @cbor.encode(encode_pve_bundle_value(bundle))
}

///|
pub fn decode_pve_replay_bundle(
  input : Bytes,
  limits~ : PveReplayWireLimits,
) -> Result[PveReplayBundle, PveReplayWireError] {
  try {
    if input.length() > limits.max_bundle_bytes {
      raise PveWireInputTooLarge(input.length(), limits.max_bundle_bytes)
    }
    preflight_cbor(input) catch {
      _ => raise PveWireMalformedCbor
    }
    let value = @cbor.decode(input) catch { _ => raise PveWireMalformedCbor }
    if @cbor.encode(value) != input {
      raise PveWireNonCanonicalEncoding
    }
    decode_pve_bundle_value(value, limits) |> Ok
  } catch {
    error => Err(error)
  }
}
