///|
const PVP_REPLAY_WIRE_VERSION : Int = 1

///|
/// Signed command/receipt pair transported to an adversarial replay worker.
pub(all) struct PvpReplayCommandEvidence {
  input : @bft.SignedEvent
  receipt : @bft.SignedEvent
  intent : @replay.PvpCommandIntent
  observed : @replay.PvpCommandReceipt
}

///|
/// Complete public-state PvP replay plus witness statements over its referee
/// checkpoint. Every signature remains untrusted until central verification.
pub(all) struct PvpReplayBundle {
  referee_peer_id : String
  signed_checkpoint : @checkpoint.SignedCheckpoint
  config : @replay.PvpEpochConfig
  teams : Array[@replay.PvpTeam]
  players : Array[@replay.PvpPlayer]
  witnesses : Array[@witness_manifest.ReplayWitnessIdentity]
  max_faults : Int
  commands : Array[PvpReplayCommandEvidence]
  attestations : Array[@attestation.SignedAttestation]
}

///|
pub(all) struct PvpReplayWireLimits {
  max_bundle_bytes : Int
  max_text_bytes : Int
  max_teams : Int
  max_players : Int
  max_witnesses : Int
  max_commands : Int
  max_attestations : Int
  max_dependencies_per_event : Int
  max_values_per_operation : Int
} derive(Eq, Debug)

///|
pub fn PvpReplayWireLimits::default() -> PvpReplayWireLimits {
  {
    max_bundle_bytes: 1048576,
    max_text_bytes: 4096,
    max_teams: 2,
    max_players: 64,
    max_witnesses: 64,
    max_commands: 4096,
    max_attestations: 64,
    max_dependencies_per_event: 64,
    max_values_per_operation: 16,
  }
}

///|
pub(all) enum PvpReplayWireError {
  PvpWireInputTooLarge(Int, Int)
  PvpWireTeamsTooMany(Int, Int)
  PvpWirePlayersTooMany(Int, Int)
  PvpWireWitnessesTooMany(Int, Int)
  PvpWireCommandsTooMany(Int, Int)
  PvpWireAttestationsTooMany(Int, Int)
  PvpWireUnsupportedVersion(Int)
  PvpWireNonCanonicalEncoding
  PvpWireMalformedCbor
  PvpWireCodecRefused(PveReplayWireError)
} derive(Eq, Debug)

///|
fn pvp_codec_limits(limits : PvpReplayWireLimits) -> PveReplayWireLimits {
  {
    max_bundle_bytes: limits.max_bundle_bytes,
    max_text_bytes: limits.max_text_bytes,
    max_players: limits.max_players,
    max_attacks: limits.max_teams,
    max_transcripts: limits.max_commands,
    max_total_dodge_evidence: limits.max_commands,
    max_asset_effects: 0,
    max_dependencies_per_event: limits.max_dependencies_per_event,
    max_values_per_operation: limits.max_values_per_operation,
  }
}

///|
fn encode_pvp_config(config : @replay.PvpEpochConfig) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(config.match_id),
    pve_wire_int(config.epoch),
    @cbor.CborValue::Text(config.previous_checkpoint.0),
    pve_wire_int(config.player_max_hp),
    pve_wire_int(config.ticks_per_epoch),
    pve_wire_int(config.max_late_ticks),
    pve_wire_int(config.max_move_distance),
    pve_wire_int(config.arena_min_x),
    pve_wire_int(config.arena_max_x),
    pve_wire_int(config.attack_range),
    pve_wire_int(config.attack_damage),
    pve_wire_int(config.score_per_elimination),
  ])
}

///|
fn decode_pvp_config(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @replay.PvpEpochConfig raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 12)
  {
    match_id: decode_pve_wire_text(fields[0], limits),
    epoch: decode_pve_wire_int(fields[1]),
    previous_checkpoint: @bft.Digest(decode_pve_wire_text(fields[2], limits)),
    player_max_hp: decode_pve_wire_int(fields[3]),
    ticks_per_epoch: decode_pve_wire_int(fields[4]),
    max_late_ticks: decode_pve_wire_int(fields[5]),
    max_move_distance: decode_pve_wire_int(fields[6]),
    arena_min_x: decode_pve_wire_int(fields[7]),
    arena_max_x: decode_pve_wire_int(fields[8]),
    attack_range: decode_pve_wire_int(fields[9]),
    attack_damage: decode_pve_wire_int(fields[10]),
    score_per_elimination: decode_pve_wire_int(fields[11]),
  }
}

///|
fn encode_pvp_team(team : @replay.PvpTeam) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(team.team_id),
    pve_wire_int(team.initial_score),
  ])
}

///|
fn decode_pvp_team(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @replay.PvpTeam raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 2)
  {
    team_id: decode_pve_wire_text(fields[0], limits),
    initial_score: decode_pve_wire_int(fields[1]),
  }
}

///|
fn encode_pvp_player(player : @replay.PvpPlayer) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(player.player_id),
    @cbor.CborValue::Text(player.public_key.0),
    @cbor.CborValue::Text(player.team_id),
    pve_wire_int(player.initial_x),
    pve_wire_int(player.initial_hp),
  ])
}

///|
fn decode_pvp_player(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @replay.PvpPlayer raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 5)
  {
    player_id: decode_pve_wire_text(fields[0], limits),
    public_key: @bft.PublicKey(decode_pve_wire_text(fields[1], limits)),
    team_id: decode_pve_wire_text(fields[2], limits),
    initial_x: decode_pve_wire_int(fields[3]),
    initial_hp: decode_pve_wire_int(fields[4]),
  }
}

///|
fn encode_pvp_witness(
  witness : @witness_manifest.ReplayWitnessIdentity,
) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(witness.id),
    @cbor.CborValue::Text(witness.key.0),
  ])
}

///|
fn decode_pvp_witness(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @witness_manifest.ReplayWitnessIdentity raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 2)
  {
    id: decode_pve_wire_text(fields[0], limits),
    key: @bft.PublicKey(decode_pve_wire_text(fields[1], limits)),
  }
}

///|
fn encode_pvp_intent(intent : @replay.PvpCommandIntent) -> @cbor.CborValue {
  let target = match intent.attack_target_id {
    None => @cbor.CborValue::Null
    Some(target_id) => @cbor.CborValue::Text(target_id)
  }
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(intent.match_id),
    pve_wire_int(intent.epoch),
    @cbor.CborValue::Text(intent.base_checkpoint_digest.0),
    pve_wire_int(intent.tick),
    @cbor.CborValue::Text(intent.player_id),
    pve_wire_int(intent.move_to_x),
    target,
  ])
}

///|
fn decode_pvp_intent(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @replay.PvpCommandIntent raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 7)
  let attack_target_id = match fields[6] {
    @cbor.CborValue::Null => None
    encoded => Some(decode_pve_wire_text(encoded, limits))
  }
  {
    match_id: decode_pve_wire_text(fields[0], limits),
    epoch: decode_pve_wire_int(fields[1]),
    base_checkpoint_digest: @bft.Digest(decode_pve_wire_text(fields[2], limits)),
    tick: decode_pve_wire_int(fields[3]),
    player_id: decode_pve_wire_text(fields[4], limits),
    move_to_x: decode_pve_wire_int(fields[5]),
    attack_target_id,
  }
}

///|
fn encode_pvp_receipt(receipt : @replay.PvpCommandReceipt) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    @cbor.CborValue::Text(receipt.command_digest.0),
    pve_wire_int(receipt.received_tick),
  ])
}

///|
fn decode_pvp_receipt(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @replay.PvpCommandReceipt raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 2)
  {
    command_digest: @bft.Digest(decode_pve_wire_text(fields[0], limits)),
    received_tick: decode_pve_wire_int(fields[1]),
  }
}

///|
fn encode_pvp_command(evidence : PvpReplayCommandEvidence) -> @cbor.CborValue {
  @cbor.CborValue::Array([
    encode_pve_signed_event(evidence.input),
    encode_pve_signed_event(evidence.receipt),
    encode_pvp_intent(evidence.intent),
    encode_pvp_receipt(evidence.observed),
  ])
}

///|
fn decode_pvp_command(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> PvpReplayCommandEvidence raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 4)
  {
    input: decode_pve_signed_event(fields[0], limits),
    receipt: decode_pve_signed_event(fields[1], limits),
    intent: decode_pvp_intent(fields[2], limits),
    observed: decode_pvp_receipt(fields[3], limits),
  }
}

///|
fn encode_pvp_attestation_choice(
  choice : @attestation.AttestationChoice,
) -> @cbor.CborValue {
  pve_wire_int(
    match choice {
      Approve => 0
      Challenge => 1
    },
  )
}

///|
fn decode_pvp_attestation_choice(
  value : @cbor.CborValue,
) -> @attestation.AttestationChoice raise PveReplayWireError {
  match decode_pve_wire_int(value) {
    0 => @attestation.AttestationChoice::Approve
    1 => @attestation.AttestationChoice::Challenge
    _ => raise PveWireInvalidShape
  }
}

///|
fn encode_pvp_attestation_purpose(
  purpose : @attestation.AttestationPurpose,
) -> @cbor.CborValue {
  pve_wire_int(
    match purpose {
      CheckpointApproval => 0
      ReplayWitness => 1
    },
  )
}

///|
fn decode_pvp_attestation_purpose(
  value : @cbor.CborValue,
) -> @attestation.AttestationPurpose raise PveReplayWireError {
  match decode_pve_wire_int(value) {
    0 => @attestation.AttestationPurpose::CheckpointApproval
    1 => @attestation.AttestationPurpose::ReplayWitness
    _ => raise PveWireInvalidShape
  }
}

///|
fn encode_pvp_signed_attestation(
  signed : @attestation.SignedAttestation,
) -> @cbor.CborValue {
  let statement = signed.attestation
  @cbor.CborValue::Array([
    @cbor.CborValue::Array([
      @cbor.CborValue::Text(statement.checkpoint_digest.0),
      @cbor.CborValue::Text(statement.participant_id),
      encode_pvp_attestation_purpose(statement.purpose),
      encode_pvp_attestation_choice(statement.choice),
    ]),
    @cbor.CborValue::Text(signed.digest.0),
    @cbor.CborValue::Text(signed.signature.0),
    @cbor.CborValue::Text(signed.signer_key.0),
  ])
}

///|
fn decode_pvp_signed_attestation(
  value : @cbor.CborValue,
  limits : PveReplayWireLimits,
) -> @attestation.SignedAttestation raise PveReplayWireError {
  let fields = decode_pve_wire_array(value, 4)
  let statement = decode_pve_wire_array(fields[0], 4)
  {
    attestation: {
      checkpoint_digest: @bft.Digest(decode_pve_wire_text(statement[0], limits)),
      participant_id: decode_pve_wire_text(statement[1], limits),
      purpose: decode_pvp_attestation_purpose(statement[2]),
      choice: decode_pvp_attestation_choice(statement[3]),
    },
    digest: @bft.Digest(decode_pve_wire_text(fields[1], limits)),
    signature: @bft.Signature(decode_pve_wire_text(fields[2], limits)),
    signer_key: @bft.PublicKey(decode_pve_wire_text(fields[3], limits)),
  }
}

///|
fn encode_pvp_bundle_value(bundle : PvpReplayBundle) -> @cbor.CborValue {
  let teams : Array[@cbor.CborValue] = []
  for team in bundle.teams {
    teams.push(encode_pvp_team(team))
  }
  let players : Array[@cbor.CborValue] = []
  for player in bundle.players {
    players.push(encode_pvp_player(player))
  }
  let witnesses : Array[@cbor.CborValue] = []
  for witness in bundle.witnesses {
    witnesses.push(encode_pvp_witness(witness))
  }
  let commands : Array[@cbor.CborValue] = []
  for command in bundle.commands {
    commands.push(encode_pvp_command(command))
  }
  let attestations : Array[@cbor.CborValue] = []
  for attestation in bundle.attestations {
    attestations.push(encode_pvp_signed_attestation(attestation))
  }
  @cbor.CborValue::Array([
    pve_wire_int(PVP_REPLAY_WIRE_VERSION),
    @cbor.CborValue::Text(bundle.referee_peer_id),
    encode_pve_signed_checkpoint(bundle.signed_checkpoint),
    encode_pvp_config(bundle.config),
    @cbor.CborValue::Array(teams),
    @cbor.CborValue::Array(players),
    @cbor.CborValue::Array(witnesses),
    pve_wire_int(bundle.max_faults),
    @cbor.CborValue::Array(commands),
    @cbor.CborValue::Array(attestations),
  ])
}

///|
fn decode_pvp_bundle_fields(
  fields : Array[@cbor.CborValue],
  limits : PveReplayWireLimits,
) -> PvpReplayBundle raise PveReplayWireError {
  let encoded_teams = decode_pve_wire_items(fields[4])
  let encoded_players = decode_pve_wire_items(fields[5])
  let encoded_witnesses = decode_pve_wire_items(fields[6])
  let encoded_commands = decode_pve_wire_items(fields[8])
  let encoded_attestations = decode_pve_wire_items(fields[9])
  let teams : Array[@replay.PvpTeam] = []
  for encoded in encoded_teams {
    teams.push(decode_pvp_team(encoded, limits))
  }
  let players : Array[@replay.PvpPlayer] = []
  for encoded in encoded_players {
    players.push(decode_pvp_player(encoded, limits))
  }
  let witnesses : Array[@witness_manifest.ReplayWitnessIdentity] = []
  for encoded in encoded_witnesses {
    witnesses.push(decode_pvp_witness(encoded, limits))
  }
  let commands : Array[PvpReplayCommandEvidence] = []
  for encoded in encoded_commands {
    commands.push(decode_pvp_command(encoded, limits))
  }
  let attestations : Array[@attestation.SignedAttestation] = []
  for encoded in encoded_attestations {
    attestations.push(decode_pvp_signed_attestation(encoded, limits))
  }
  {
    referee_peer_id: decode_pve_wire_text(fields[1], limits),
    signed_checkpoint: decode_pve_signed_checkpoint(fields[2], limits),
    config: decode_pvp_config(fields[3], limits),
    teams,
    players,
    witnesses,
    max_faults: decode_pve_wire_int(fields[7]),
    commands,
    attestations,
  }
}

///|
pub fn encode_pvp_replay_bundle(bundle : PvpReplayBundle) -> Bytes {
  @cbor.encode(encode_pvp_bundle_value(bundle))
}

///|
pub fn decode_pvp_replay_bundle(
  input : Bytes,
  limits~ : PvpReplayWireLimits,
) -> Result[PvpReplayBundle, PvpReplayWireError] {
  if input.length() > limits.max_bundle_bytes {
    return Err(PvpWireInputTooLarge(input.length(), limits.max_bundle_bytes))
  }
  preflight_cbor(input) catch {
    _ => return Err(PvpWireMalformedCbor)
  }
  let value = @cbor.decode(input) catch {
    _ => return Err(PvpWireMalformedCbor)
  }
  if @cbor.encode(value) != input {
    return Err(PvpWireNonCanonicalEncoding)
  }
  let codec_limits = pvp_codec_limits(limits)
  let fields = decode_pve_wire_array(value, 10) catch {
    error => return Err(PvpWireCodecRefused(error))
  }
  let version = decode_pve_wire_int(fields[0]) catch {
    error => return Err(PvpWireCodecRefused(error))
  }
  if version != PVP_REPLAY_WIRE_VERSION {
    return Err(PvpWireUnsupportedVersion(version))
  }
  let teams = decode_pve_wire_items(fields[4]) catch {
    error => return Err(PvpWireCodecRefused(error))
  }
  if teams.length() > limits.max_teams {
    return Err(PvpWireTeamsTooMany(teams.length(), limits.max_teams))
  }
  let players = decode_pve_wire_items(fields[5]) catch {
    error => return Err(PvpWireCodecRefused(error))
  }
  if players.length() > limits.max_players {
    return Err(PvpWirePlayersTooMany(players.length(), limits.max_players))
  }
  let witnesses = decode_pve_wire_items(fields[6]) catch {
    error => return Err(PvpWireCodecRefused(error))
  }
  if witnesses.length() > limits.max_witnesses {
    return Err(
      PvpWireWitnessesTooMany(witnesses.length(), limits.max_witnesses),
    )
  }
  let commands = decode_pve_wire_items(fields[8]) catch {
    error => return Err(PvpWireCodecRefused(error))
  }
  if commands.length() > limits.max_commands {
    return Err(PvpWireCommandsTooMany(commands.length(), limits.max_commands))
  }
  let attestations = decode_pve_wire_items(fields[9]) catch {
    error => return Err(PvpWireCodecRefused(error))
  }
  if attestations.length() > limits.max_attestations {
    return Err(
      PvpWireAttestationsTooMany(attestations.length(), limits.max_attestations),
    )
  }
  let bundle = decode_pvp_bundle_fields(fields, codec_limits) catch {
    error => return Err(PvpWireCodecRefused(error))
  }
  Ok(bundle)
}
