///|
let dungeon_telegraph_table : String = "converge.dungeon.telegraph.v1"

///|
let dungeon_dodge_table : String = "converge.dungeon.dodge.v1"

///|
let dungeon_receipt_table : String = "converge.dungeon.receipt.v1"

///|
fn append_int_field(buffer : StringBuilder, value : Int) -> Unit {
  append_field(buffer, value.to_string())
}

///|
pub fn serialize_telegraphed_attack(attack : TelegraphedAttack) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "telegraphed-attack-v1")
  append_field(buffer, attack.attack_id)
  append_int_field(buffer, attack.visible_tick)
  append_int_field(buffer, attack.resolve_tick)
  append_int_field(buffer, attack.center_x)
  append_int_field(buffer, attack.radius)
  buffer.to_string()
}

///|
pub fn serialize_dodge_intent(intent : DodgeIntent) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "dodge-intent-v1")
  append_field(buffer, intent.attack_id)
  append_field(buffer, intent.player_id)
  append_field(buffer, intent.telegraph_digest.0)
  append_int_field(buffer, intent.client_tick)
  append_int_field(buffer, intent.to_x)
  buffer.to_string()
}

///|
pub fn serialize_dodge_receipt(receipt : DodgeReceipt) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "dodge-receipt-v1")
  append_field(buffer, receipt.input_digest.0)
  append_int_field(buffer, receipt.received_tick)
  buffer.to_string()
}

///|
pub fn make_dungeon_telegraph_event(
  peer~ : @types.PeerId,
  counter~ : Int,
  lamport~ : Int,
  deps~ : Array[@types.EventId],
  attack~ : TelegraphedAttack,
) -> @types.Event {
  {
    id: { peer, counter },
    deps,
    lamport,
    op: @types.RowOp::Insert(
      tbl=dungeon_telegraph_table,
      row_id=attack.attack_id,
      values=[
        ("attack", @types.Value::Str(serialize_telegraphed_attack(attack))),
      ],
    ),
  }
}

///|
pub fn make_dungeon_dodge_event(
  peer~ : @types.PeerId,
  counter~ : Int,
  lamport~ : Int,
  deps~ : Array[@types.EventId],
  intent~ : DodgeIntent,
) -> @types.Event {
  {
    id: { peer, counter },
    deps,
    lamport,
    op: @types.RowOp::Insert(
      tbl=dungeon_dodge_table,
      row_id=intent.attack_id + ":" + intent.player_id,
      values=[("intent", @types.Value::Str(serialize_dodge_intent(intent)))],
    ),
  }
}

///|
pub fn make_dungeon_receipt_event(
  peer~ : @types.PeerId,
  counter~ : Int,
  lamport~ : Int,
  deps~ : Array[@types.EventId],
  receipt~ : DodgeReceipt,
) -> @types.Event {
  {
    id: { peer, counter },
    deps,
    lamport,
    op: @types.RowOp::Insert(
      tbl=dungeon_receipt_table,
      row_id=receipt.input_digest.0,
      values=[("receipt", @types.Value::Str(serialize_dodge_receipt(receipt)))],
    ),
  }
}

///|
fn valid_config(config : TelegraphDungeonConfig) -> Bool {
  config.min_reaction_ticks >= 0 &&
  config.max_backdate_ticks >= 0 &&
  config.max_dodge_distance >= 0 &&
  config.arena_min_x <= config.arena_max_x &&
  config.loot_item_type != ""
}

///|
fn roster_map(
  config : TelegraphDungeonConfig,
  players : Array[DungeonPlayer],
) -> Map[String, DungeonPlayer]? {
  if players.length() == 0 {
    return None
  }
  let by_id : Map[String, DungeonPlayer] = Map([])
  let used_keys : Map[String, Bool] = Map([])
  for player in players {
    if player.player_id == "" ||
      player.public_key.0 == "" ||
      player.initial_x < config.arena_min_x ||
      player.initial_x > config.arena_max_x ||
      by_id.contains(player.player_id) ||
      used_keys.contains(player.public_key.0) {
      return None
    }
    by_id[player.player_id] = player
    used_keys[player.public_key.0] = true
  }
  Some(by_id)
}

///|
fn valid_attack(
  config : TelegraphDungeonConfig,
  attack : TelegraphedAttack,
) -> Bool {
  attack.attack_id != "" &&
  attack.visible_tick >= 0 &&
  attack.resolve_tick > attack.visible_tick + config.min_reaction_ticks &&
  attack.center_x >= config.arena_min_x &&
  attack.center_x <= config.arena_max_x &&
  attack.radius >= 0
}

///|
fn exact_insert(
  source : @bft.AuthenticatedEvent,
  table : String,
  row_id : String,
  field : String,
  payload : String,
) -> Bool {
  let event = source.event()
  if event.id.counter < 0 || event.lamport < 0 {
    return false
  }
  match event.op {
    @types.RowOp::Insert(tbl~, row_id=actual_row_id, values~) =>
      tbl == table &&
      actual_row_id == row_id &&
      values.length() == 1 &&
      values[0].0 == field &&
      values[0].1 == @types.Value::Str(payload)
    _ => false
  }
}

///|
fn one_dependency(
  source : @bft.AuthenticatedEvent,
  expected : @types.EventId,
) -> Bool {
  let deps = source.event().deps
  deps.length() == 1 && deps[0] == expected
}

///|
fn telegraph_source_valid(
  session_id : String,
  authority_key : @bft.PublicKey,
  source : @bft.AuthenticatedEvent,
  attack : TelegraphedAttack,
) -> Bool {
  source.session_id() == session_id &&
  source.author_key() == authority_key &&
  exact_insert(
    source,
    dungeon_telegraph_table,
    attack.attack_id,
    "attack",
    serialize_telegraphed_attack(attack),
  )
}

///|
fn distance(a : Int, b : Int) -> Int {
  if a >= b {
    a - b
  } else {
    b - a
  }
}

///|
fn dodge_evidence_valid(
  session_id : String,
  authority_key : @bft.PublicKey,
  config : TelegraphDungeonConfig,
  player : DungeonPlayer,
  telegraph_source : @bft.AuthenticatedEvent,
  attack : TelegraphedAttack,
  evidence : DodgeEvidence,
) -> Bool {
  let intent = evidence.intent
  let observed = evidence.observed
  let input = evidence.input
  let receipt = evidence.receipt
  let player_evidence_valid = intent.attack_id == attack.attack_id &&
    intent.player_id == player.player_id &&
    input.session_id() == session_id &&
    input.author_key() == player.public_key &&
    input.event().id.peer.0 == player.player_id &&
    exact_insert(
      input,
      dungeon_dodge_table,
      intent.attack_id + ":" + intent.player_id,
      "intent",
      serialize_dodge_intent(intent),
    ) &&
    receipt.session_id() == session_id &&
    receipt.author_key() == authority_key &&
    observed.input_digest == input.digest() &&
    exact_insert(
      receipt,
      dungeon_receipt_table,
      input.digest().0,
      "receipt",
      serialize_dodge_receipt(observed),
    )
  let causally_bound = intent.telegraph_digest == telegraph_source.digest() &&
    one_dependency(input, telegraph_source.event().id) &&
    one_dependency(receipt, input.event().id)
  let reaction_window = @audit.dodge_reaction_window_allowed(
    attack.visible_tick,
    attack.resolve_tick,
    config.min_reaction_ticks,
    intent.client_tick,
  )
  let receipt_bound = @audit.dodge_receipt_bound_allowed(
    intent.client_tick,
    observed.received_tick,
    config.max_backdate_ticks,
  )
  let movement_legal = intent.to_x >= config.arena_min_x &&
    intent.to_x <= config.arena_max_x &&
    distance(intent.to_x, player.initial_x) <= config.max_dodge_distance
  @audit.telegraph_dodge_allowed(
    telegraph_valid=true,
    player_evidence_valid~,
    causally_bound~,
    reaction_window~,
    receipt_bound~,
    movement_legal~,
  )
}

///|
pub fn telegraph_dungeon_manifest(
  hasher : &@bft.Hasher,
  authority_key : @bft.PublicKey,
  config : TelegraphDungeonConfig,
  players : Array[DungeonPlayer],
) -> @bft.Digest {
  let buffer = StringBuilder::new()
  append_field(buffer, "telegraph-dungeon-kernel-v1")
  append_field(buffer, authority_key.0)
  append_int_field(buffer, config.min_reaction_ticks)
  append_int_field(buffer, config.max_backdate_ticks)
  append_int_field(buffer, config.max_dodge_distance)
  append_int_field(buffer, config.arena_min_x)
  append_int_field(buffer, config.arena_max_x)
  append_field(buffer, config.loot_item_type)
  let sorted = players.copy()
  sorted.sort_by(fn(a, b) { b.player_id.compare(a.player_id) })
  append_int_field(buffer, sorted.length())
  for player in sorted {
    append_field(buffer, player.player_id)
    append_field(buffer, player.public_key.0)
    append_int_field(buffer, player.initial_x)
  }
  hasher.hash_string(buffer.to_string())
}

///|
/// Resolve one already-validated attack. `players` may contain the full roster
/// or only players still alive in a multi-attack encounter; each player's
/// `initial_x` is the position committed before this attack.
fn replay_attack_step(
  session_id : String,
  authority_key : @bft.PublicKey,
  config : TelegraphDungeonConfig,
  players_by_id : Map[String, DungeonPlayer],
  players : Array[DungeonPlayer],
  telegraph_source : @bft.AuthenticatedEvent,
  attack : TelegraphedAttack,
  dodge_evidence : Array[DodgeEvidence],
) -> DungeonAttackStep {
  let accepted : Map[String, DodgeIntent] = Map([])
  let accepted_digests : Map[String, @bft.Digest] = Map([])
  let equivocators : Map[String, Bool] = Map([])
  for evidence in dodge_evidence {
    let player_id = evidence.intent.player_id
    match players_by_id.get(player_id) {
      None => ()
      Some(player) =>
        if dodge_evidence_valid(
            session_id, authority_key, config, player, telegraph_source, attack,
            evidence,
          ) {
          if equivocators.contains(player_id) {
            continue
          }
          match accepted_digests.get(player_id) {
            None => {
              accepted[player_id] = evidence.intent
              accepted_digests[player_id] = evidence.input.digest()
            }
            Some(existing) =>
              if existing != evidence.input.digest() {
                ignore(accepted.remove(player_id))
                ignore(accepted_digests.remove(player_id))
                equivocators[player_id] = true
              }
          }
        }
    }
  }
  let sorted_players = players.copy()
  sorted_players.sort_by(fn(a, b) { b.player_id.compare(a.player_id) })
  let positions : Map[String, Int] = Map([])
  let hit : Array[String] = []
  let equivocated : Array[String] = []
  for player in sorted_players {
    if equivocators.contains(player.player_id) {
      equivocated.push(player.player_id)
      positions[player.player_id] = player.initial_x
      hit.push(player.player_id)
      continue
    }
    let position = match accepted.get(player.player_id) {
      Some(intent) => intent.to_x
      None => player.initial_x
    }
    positions[player.player_id] = position
    if distance(position, attack.center_x) <= attack.radius {
      hit.push(player.player_id)
    }
  }
  {
    positions,
    hit,
    equivocators: equivocated,
    accepted_dodges: accepted.length(),
  }
}

///|
/// Replay implementation used only after the public checkpoint boundary.
/// Input array order does not affect the result. A player presenting two
/// distinct valid dodge inputs is marked as an equivocator and receives no loot.
fn replay_telegraphed_attack(
  hasher : &@bft.Hasher,
  session_id~ : String,
  authority_key~ : @bft.PublicKey,
  config~ : TelegraphDungeonConfig,
  players~ : Array[DungeonPlayer],
  telegraph_source~ : @bft.AuthenticatedEvent,
  attack~ : TelegraphedAttack,
  dodge_evidence~ : Array[DodgeEvidence],
) -> DungeonReplayResult {
  if session_id == "" || authority_key.0 == "" || !valid_config(config) {
    return Refused(InvalidConfiguration)
  }
  let players_by_id = match roster_map(config, players) {
    Some(roster) => roster
    None => return Refused(InvalidRoster)
  }
  if !valid_attack(config, attack) ||
    !telegraph_source_valid(session_id, authority_key, telegraph_source, attack) {
    return Refused(InvalidTelegraph)
  }
  let manifest = telegraph_dungeon_manifest(
    hasher, authority_key, config, players,
  )
  if manifest.0 == "" {
    return Refused(EmptyManifest)
  }
  let step = replay_attack_step(
    session_id, authority_key, config, players_by_id, players, telegraph_source,
    attack, dodge_evidence,
  )
  let sorted_players = players.copy()
  sorted_players.sort_by(fn(a, b) { b.player_id.compare(a.player_id) })
  let survivors : Array[String] = []
  let hit_set : Map[String, Bool] = Map([])
  for player_id in step.hit {
    hit_set[player_id] = true
  }
  for player in sorted_players {
    if !hit_set.contains(player.player_id) {
      survivors.push(player.player_id)
    }
  }
  Resolved(DungeonResolution::{
    session: session_id,
    authority: authority_key,
    attack_id: attack.attack_id,
    loot_item_type: config.loot_item_type,
    manifest,
    survivors,
    hit: step.hit,
    equivocators: step.equivocators,
    accepted_dodges: step.accepted_dodges,
  })
}

///|
/// Canonical Merkle root for the exact event set consumed by this one-attack
/// kernel. Network duplicates are removed and digests are sorted before build.
pub fn dungeon_transcript_root(
  hasher : &@bft.Hasher,
  telegraph_source : @bft.AuthenticatedEvent,
  dodge_evidence : Array[DodgeEvidence],
) -> @bft.Digest {
  let seen : Map[String, Bool] = Map([])
  let payloads : Array[String] = []
  let add = fn(digest : @bft.Digest) {
    if !seen.contains(digest.0) {
      seen[digest.0] = true
      payloads.push(digest.0)
    }
  }
  add(telegraph_source.digest())
  for evidence in dodge_evidence {
    add(evidence.input.digest())
    add(evidence.receipt.digest())
  }
  payloads.sort_by(fn(a, b) { b.compare(a) })
  @merkle.MerkleTree::build(hasher, payloads).root()
}

///|
/// Replay a telegraphed attack only when an authority-verified checkpoint binds
/// the session, kernel manifest, and exact event-set root supplied here.
pub fn replay_checkpointed_telegraphed_attack(
  hasher : &@bft.Hasher,
  session_id~ : String,
  authority_key~ : @bft.PublicKey,
  config~ : TelegraphDungeonConfig,
  players~ : Array[DungeonPlayer],
  checkpoint~ : @checkpoint.VerifiedCheckpoint,
  telegraph_source~ : @bft.AuthenticatedEvent,
  attack~ : TelegraphedAttack,
  dodge_evidence~ : Array[DodgeEvidence],
) -> DungeonReplayResult {
  let committed = checkpoint.checkpoint()
  if checkpoint.authority_key() != authority_key {
    return Refused(CheckpointAuthorityMismatch)
  }
  if committed.session_id != session_id {
    return Refused(CheckpointSessionMismatch)
  }
  let result = replay_telegraphed_attack(
    hasher,
    session_id~,
    authority_key~,
    config~,
    players~,
    telegraph_source~,
    attack~,
    dodge_evidence~,
  )
  match result {
    Refused(reason) => Refused(reason)
    Resolved(resolution) => {
      if committed.manifest_digest != resolution.manifest_digest() {
        return Refused(CheckpointManifestMismatch)
      }
      let event_root = dungeon_transcript_root(
        hasher, telegraph_source, dodge_evidence,
      )
      if committed.event_root != event_root {
        return Refused(CheckpointEventRootMismatch)
      }
      Resolved(resolution)
    }
  }
}

///|
pub fn DungeonResolution::survivor_ids(
  self : DungeonResolution,
) -> Array[String] {
  self.survivors.copy()
}

///|
pub fn DungeonResolution::hit_ids(self : DungeonResolution) -> Array[String] {
  self.hit.copy()
}

///|
pub fn DungeonResolution::equivocator_ids(
  self : DungeonResolution,
) -> Array[String] {
  self.equivocators.copy()
}

///|
pub fn DungeonResolution::accepted_dodge_count(self : DungeonResolution) -> Int {
  self.accepted_dodges
}

///|
pub fn DungeonResolution::manifest_digest(
  self : DungeonResolution,
) -> @bft.Digest {
  self.manifest
}

///|
pub fn dungeon_loot_asset_id(
  session : String,
  attack_id : String,
  recipient_id : String,
) -> String {
  let buffer = StringBuilder::new()
  append_field(buffer, "dungeon-loot-v1")
  append_field(buffer, session)
  append_field(buffer, attack_id)
  append_field(buffer, recipient_id)
  buffer.to_string()
}

///|
fn deterministic_loot_effect(
  session : String,
  attack_id : String,
  loot_item_type : String,
  recipient_id : String,
) -> AssetEffect {
  AssetEffect::Create(
    asset_id=dungeon_loot_asset_id(session, attack_id, recipient_id),
    recipient_id~,
    item_type=loot_item_type,
    quantity=1,
    output_index=0,
  )
}

///|
pub fn DungeonResolution::loot_effect(
  self : DungeonResolution,
  recipient_id : String,
) -> AssetEffect? {
  for survivor in self.survivors {
    if survivor == recipient_id {
      return Some(
        deterministic_loot_effect(
          self.session,
          self.attack_id,
          self.loot_item_type,
          recipient_id,
        ),
      )
    }
  }
  None
}

///|
pub fn DungeonResolution::loot_kernel(
  self : DungeonResolution,
) -> DungeonLootKernel {
  let eligible : Map[String, Bool] = Map([])
  for survivor in self.survivors {
    eligible[survivor] = true
  }
  DungeonLootKernel::{
    session: self.session,
    authority: self.authority,
    attack_id: self.attack_id,
    loot_item_type: self.loot_item_type,
    manifest: self.manifest,
    eligible,
  }
}

///|
pub impl AssetReplayKernel for DungeonLootKernel with fn manifest_digest(
  self : DungeonLootKernel,
) -> @bft.Digest {
  self.manifest
}

///|
pub impl AssetReplayKernel for DungeonLootKernel with fn replay(
  self : DungeonLootKernel,
  source : @bft.AuthenticatedEvent,
  effect : AssetEffect,
) -> Bool {
  if source.session_id() != self.session ||
    source.author_key() != self.authority {
    return false
  }
  match effect {
    AssetEffect::Create(
      asset_id~,
      recipient_id~,
      item_type~,
      quantity~,
      output_index~
    ) =>
      self.eligible.contains(recipient_id) &&
      asset_id ==
      dungeon_loot_asset_id(self.session, self.attack_id, recipient_id) &&
      item_type == self.loot_item_type &&
      quantity == 1 &&
      output_index == 0 &&
      exact_insert(
        source,
        "converge.asset-effect.v1",
        asset_id,
        "effect",
        serialize_asset_effect(effect),
      )
    _ => false
  }
}
