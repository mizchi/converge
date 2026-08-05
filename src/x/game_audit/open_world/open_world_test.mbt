///|
fn verified_open_world_checkpoint(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  authority : &@bft.Signer,
  prepared : @checkpoint.PreparedCheckpoint,
) -> @checkpoint.VerifiedCheckpoint raise Error {
  let signed = @checkpoint.sign_prepared_checkpoint(authority, prepared)
  match
    @checkpoint.open_checkpoint(
      hasher,
      verifier,
      authority.public_key(),
      signed,
    ) {
    Opened(verified) => verified
    _ => fail("expected verified open-world checkpoint")
  }
}

///|
fn open_world_epoch_plan(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  authority : &@bft.Signer,
  sample_numerator : Int,
  sample_denominator : Int,
  seed? : String = "epoch-secret-seed",
) -> @checkpoint.VerifiedCheckpoint raise Error {
  let prepared = @checkpoint.prepare_checkpoint(hasher, {
    session_id: "world-1",
    epoch: 10,
    previous_checkpoint: @bft.Digest("world-epoch-9"),
    manifest_digest: open_world_audit_manifest(
      hasher,
      game_manifest_digest=@bft.Digest("open-world-kernel-v1"),
      observer_manifest_digest=open_world_observer_manifest(
        hasher,
        observers=[],
        max_faults=0,
      ),
      sample_numerator~,
      sample_denominator~,
    ),
    event_root: @bft.Digest("audit-epoch-start-events"),
    public_state_root: @bft.Digest("world-state-at-epoch-start"),
    asset_delta_root: @bft.Digest("no-assets"),
    hidden_state_commitment: Some(
      open_world_audit_seed_commitment(
        hasher,
        world_id="world-1",
        epoch=10,
        seed~,
      ),
    ),
  })
  verified_open_world_checkpoint(hasher, verifier, authority, prepared)
}

///|
fn open_world_encounter(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  audit_checkpoint_digest : @bft.Digest,
  authority : &@bft.Signer,
  manifest : @bft.Digest,
  registration_index? : Int = 0,
  event_root? : String = "encounter-events",
) -> @checkpoint.VerifiedCheckpoint raise Error {
  let prepared = @checkpoint.prepare_checkpoint(hasher, {
    session_id: "world-1:encounter-42",
    epoch: registration_index,
    previous_checkpoint: audit_checkpoint_digest,
    manifest_digest: manifest,
    event_root: @bft.Digest(event_root),
    public_state_root: @bft.Digest("encounter-result"),
    asset_delta_root: @bft.Digest("encounter-assets"),
    hidden_state_commitment: None,
  })
  verified_open_world_checkpoint(hasher, verifier, authority, prepared)
}

///|
fn sealed_open_world_epoch(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  authority : &@bft.Signer,
  plan : @checkpoint.VerifiedCheckpoint,
  eligible_anchor_root : @bft.Digest,
  eligible_registry_root : @bft.Digest,
  registered_count~ : Int,
  previous_override? : @bft.Digest? = None,
) -> @checkpoint.VerifiedCheckpoint raise Error {
  let plan_checkpoint = plan.checkpoint()
  let previous = match previous_override {
    Some(value) => value
    None => plan.digest()
  }
  let prepared = @checkpoint.prepare_checkpoint(hasher, {
    session_id: plan_checkpoint.session_id,
    epoch: plan_checkpoint.epoch + 1,
    previous_checkpoint: previous,
    manifest_digest: open_world_anchor_seal_manifest(
      hasher,
      audit_manifest_digest=plan_checkpoint.manifest_digest,
      registered_count~,
    ),
    event_root: eligible_anchor_root,
    public_state_root: eligible_registry_root,
    asset_delta_root: @bft.Digest("epoch-assets"),
    hidden_state_commitment: None,
  })
  verified_open_world_checkpoint(hasher, verifier, authority, prepared)
}

///|
fn reveal_epoch_with_root(
  hasher : &@bft.Hasher,
  plan : @checkpoint.VerifiedCheckpoint,
  seal : @checkpoint.VerifiedCheckpoint,
  registered_count : Int,
  sample_numerator : Int,
  sample_denominator : Int,
  seed? : String = "epoch-secret-seed",
) -> RevealedOpenWorldAuditEpoch raise Error {
  match
    reveal_open_world_audit_epoch(
      hasher,
      plan,
      seal,
      game_manifest_digest=@bft.Digest("open-world-kernel-v1"),
      observer_manifest_digest=open_world_observer_manifest(
        hasher,
        observers=[],
        max_faults=0,
      ),
      sample_numerator~,
      sample_denominator~,
      registered_count~,
      seed~,
    ) {
    AuditEpochRevealed(epoch) => epoch
    _ => fail("expected valid delayed audit seed reveal")
  }
}

///|
fn revealed_open_world_epoch(
  sample_numerator : Int,
  sample_denominator : Int,
) -> RevealedOpenWorldAuditEpoch raise Error {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-referee")
  let plan = open_world_epoch_plan(
    hasher, verifier, authority, sample_numerator, sample_denominator,
  )
  let empty = @merkle.MerkleTree::build(hasher, [])
  let empty_registry = open_world_registry(hasher, [])
  let seal = sealed_open_world_epoch(
    hasher,
    verifier,
    authority,
    plan,
    empty.root(),
    empty_registry.root(),
    registered_count=0,
  )
  reveal_epoch_with_root(
    hasher, plan, seal, 0, sample_numerator, sample_denominator,
  )
}

///|
fn proof_or_fail(
  tree : @merkle.MerkleTree,
  index : Int,
) -> @merkle.MerkleProof raise Error {
  match tree.proof(index) {
    Some(proof) => proof
    None => fail("expected eligible encounter proof")
  }
}

///|
fn open_world_registry(
  hasher : &@bft.Hasher,
  entries : Array[(Int, @bft.Digest)],
) -> @authmap.AuthenticatedMap {
  let registry = @authmap.AuthenticatedMap::new(hasher)
  for entry in entries {
    ignore(
      registry.put(open_world_encounter_registration_key(entry.0), entry.1.0),
    )
  }
  registry
}

///|
fn sparse_encounter_fixture(
  sample_numerator : Int,
  sample_denominator : Int,
) -> (
  RevealedOpenWorldAuditEpoch,
  @checkpoint.VerifiedCheckpoint,
  @merkle.MerkleProof,
) raise Error {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-referee")
  let plan = open_world_epoch_plan(
    hasher, verifier, authority, sample_numerator, sample_denominator,
  )
  let encounter = open_world_encounter(
    hasher,
    verifier,
    plan.digest(),
    authority,
    @bft.Digest("public-encounter-kernel-v1"),
  )
  let eligible = @merkle.MerkleTree::build(hasher, [
    open_world_encounter_anchor_payload(0, encounter.digest()),
  ])
  let registry = open_world_registry(hasher, [(0, encounter.digest())])
  let seal = sealed_open_world_epoch(
    hasher,
    verifier,
    authority,
    plan,
    eligible.root(),
    registry.root(),
    registered_count=1,
  )
  (
    reveal_epoch_with_root(
      hasher, plan, seal, 1, sample_numerator, sample_denominator,
    ),
    encounter,
    proof_or_fail(eligible, 0),
  )
}

///|
fn open_world_witness_roster() -> (
  Array[@bft.MockSigner],
  Array[@attestation.Participant],
) {
  let signers : Array[@bft.MockSigner] = []
  let roster : Array[@attestation.Participant] = []
  for index in 0..<4 {
    let id = "encounter-witness-" + index.to_string()
    let signer = @bft.MockSigner::new(id)
    signers.push(signer)
    roster.push({ id, key: signer.public_key() })
  }
  (signers, roster)
}

///|
fn witnessed_open_world_encounter() -> (
  RevealedOpenWorldAuditEpoch,
  @checkpoint.VerifiedCheckpoint,
  @attestation.WitnessReplayCertificate,
  @merkle.MerkleProof,
) raise Error {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-referee")
  let plan = open_world_epoch_plan(hasher, verifier, authority, 0, 1)
  let (signers, roster) = open_world_witness_roster()
  let game_manifest = @bft.Digest("public-encounter-kernel-v1")
  let manifest = @attestation.replay_witness_session_manifest(
    hasher,
    game_manifest_digest=game_manifest,
    referee_key=authority.public_key(),
    witnesses=roster,
    max_faults=1,
  )
  let encounter = open_world_encounter(
    hasher,
    verifier,
    plan.digest(),
    authority,
    manifest,
  )
  let eligible = @merkle.MerkleTree::build(hasher, [
    open_world_encounter_anchor_payload(0, encounter.digest()),
  ])
  let registry = open_world_registry(hasher, [(0, encounter.digest())])
  let seal = sealed_open_world_epoch(
    hasher,
    verifier,
    authority,
    plan,
    eligible.root(),
    registry.root(),
    registered_count=1,
  )
  let epoch = reveal_epoch_with_root(hasher, plan, seal, 1, 0, 1)
  let prepared = @checkpoint.prepare_checkpoint(hasher, encounter.checkpoint())
  let collector = match
    @attestation.ReplayWitnessCollector::new(
      hasher,
      verifier,
      prepared,
      game_manifest_digest=game_manifest,
      referee_key=authority.public_key(),
      witnesses=roster,
      max_faults=1,
    ) {
    WitnessCollectorReady(value) => value
    _ => fail("expected open-world witness collector")
  }
  for index in 0..<3 {
    ignore(
      collector.deliver(
        @attestation.sign_replay_witness_attestation(
          hasher,
          signers[index],
          prepared,
          roster[index].id,
          @attestation.AttestationChoice::Approve,
        ),
      ),
    )
  }
  let certificate = match collector.certify(encounter) {
    WitnessCertified(value) => value
    _ => fail("expected open-world replay witness certificate")
  }
  (epoch, encounter, certificate, proof_or_fail(eligible, 0))
}

///|
test "audit epoch reveal verifies committed policy seed and closed anchor set" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-referee")
  let plan = open_world_epoch_plan(
    hasher,
    verifier,
    authority,
    1,
    4,
    seed="correct-seed",
  )
  let eligible = @merkle.MerkleTree::build(hasher, [
    open_world_encounter_anchor_payload(0, @bft.Digest("encounter-anchor")),
  ])
  let registry = open_world_registry(hasher, [
    (0, @bft.Digest("encounter-anchor")),
  ])
  let seal = sealed_open_world_epoch(
    hasher,
    verifier,
    authority,
    plan,
    eligible.root(),
    registry.root(),
    registered_count=1,
  )
  match
    reveal_open_world_audit_epoch(
      hasher,
      plan,
      seal,
      game_manifest_digest=@bft.Digest("open-world-kernel-v1"),
      observer_manifest_digest=open_world_observer_manifest(
        hasher,
        observers=[],
        max_faults=0,
      ),
      sample_numerator=1,
      sample_denominator=4,
      registered_count=1,
      seed="wrong-seed",
    ) {
    AuditEpochRefused(AuditSeedCommitmentMismatch) => ()
    _ => fail("wrong delayed audit seed was accepted")
  }
  match
    reveal_open_world_audit_epoch(
      hasher,
      plan,
      seal,
      game_manifest_digest=@bft.Digest("open-world-kernel-v1"),
      observer_manifest_digest=open_world_observer_manifest(
        hasher,
        observers=[],
        max_faults=0,
      ),
      sample_numerator=2,
      sample_denominator=4,
      registered_count=1,
      seed="correct-seed",
    ) {
    AuditEpochRefused(AuditManifestMismatch) => ()
    _ => fail("uncommitted audit sampling policy was accepted")
  }
  match
    reveal_open_world_audit_epoch(
      hasher,
      plan,
      seal,
      game_manifest_digest=@bft.Digest("open-world-kernel-v1"),
      observer_manifest_digest=open_world_observer_manifest(
        hasher,
        observers=[],
        max_faults=0,
      ),
      sample_numerator=1,
      sample_denominator=4,
      registered_count=2,
      seed="correct-seed",
    ) {
    AuditEpochRefused(AuditSealManifestMismatch) => ()
    _ => fail("uncommitted encounter registry count was accepted")
  }
  let bad_seal = sealed_open_world_epoch(
    hasher,
    verifier,
    authority,
    plan,
    eligible.root(),
    registry.root(),
    registered_count=1,
    previous_override=Some(@bft.Digest("different-plan")),
  )
  match
    reveal_open_world_audit_epoch(
      hasher,
      plan,
      bad_seal,
      game_manifest_digest=@bft.Digest("open-world-kernel-v1"),
      observer_manifest_digest=open_world_observer_manifest(
        hasher,
        observers=[],
        max_faults=0,
      ),
      sample_numerator=1,
      sample_denominator=4,
      registered_count=1,
      seed="correct-seed",
    ) {
    AuditEpochRefused(AuditSealParentMismatch) => ()
    _ => fail("anchor seal for another audit plan was accepted")
  }
}

///|
test "zero and full sampling rates route deterministically" {
  let never = revealed_open_world_epoch(0, 1)
  let always = revealed_open_world_epoch(1, 1)
  let anchor = @bft.Digest("first-authenticated-encounter-event")
  assert_false(never.selects_encounter(anchor))
  assert_true(always.selects_encounter(anchor))
  assert_eq(always.selects_encounter(anchor), always.selects_encounter(anchor))
}

///|
test "unsampled witnessed encounter finalizes without central replay" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let (epoch, encounter, certificate, proof) = witnessed_open_world_encounter()
  match
    evaluate_open_world_encounter(
      hasher,
      verifier,
      epoch,
      encounter,
      eligibility_proof=proof,
      outcome_class=@audit.OpenWorldOutcomeClass::Durable,
      peer_certificate=certificate,
    ) {
    EncounterPeerFinalized(finalized) =>
      assert_eq(finalized.digest(), encounter.digest())
    _ => fail("ordinary witnessed encounter required central replay")
  }
}

///|
test "sampling sparse economics and high value outcomes escalate" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let (sampled_epoch, sampled, sampled_proof) = sparse_encounter_fixture(1, 1)
  match
    evaluate_open_world_encounter(
      hasher,
      verifier,
      sampled_epoch,
      sampled,
      eligibility_proof=sampled_proof,
      outcome_class=@audit.OpenWorldOutcomeClass::Ephemeral,
    ) {
    EncounterCentralReplayRequired => ()
    _ => fail("sampled encounter bypassed central replay")
  }
  let (unsampled_epoch, sparse, sparse_proof) = sparse_encounter_fixture(0, 1)
  match
    evaluate_open_world_encounter(
      hasher,
      verifier,
      unsampled_epoch,
      sparse,
      eligibility_proof=sparse_proof,
      outcome_class=@audit.OpenWorldOutcomeClass::Durable,
    ) {
    EncounterCentralReplayRequired => ()
    _ => fail("unwitnessed durable result escaped replay")
  }
  match
    evaluate_open_world_encounter(
      hasher,
      verifier,
      unsampled_epoch,
      sparse,
      eligibility_proof=sparse_proof,
      outcome_class=@audit.OpenWorldOutcomeClass::Ephemeral,
    ) {
    EncounterProvisional => ()
    _ => fail("visual-only sparse encounter was not provisional")
  }
  let (valuable_epoch, valuable, certificate, valuable_proof) = witnessed_open_world_encounter()
  match
    evaluate_open_world_encounter(
      hasher,
      verifier,
      valuable_epoch,
      valuable,
      eligibility_proof=valuable_proof,
      outcome_class=@audit.OpenWorldOutcomeClass::HighValue,
      peer_certificate=certificate,
    ) {
    EncounterCentralReplayRequired => ()
    _ => fail("high-value witness certificate bypassed central replay")
  }
}

///|
test "only encounters included before seed reveal are eligible" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let (epoch, encounter, _) = sparse_encounter_fixture(0, 1)
  let unrelated = @merkle.MerkleTree::build(hasher, [
    open_world_encounter_anchor_payload(0, @bft.Digest("not-this-encounter")),
    open_world_encounter_anchor_payload(
      1,
      @bft.Digest("another-unrelated-encounter"),
    ),
  ])
  let wrong_proof = proof_or_fail(unrelated, 0)
  assert_false(
    @merkle.verify_inclusion(
      hasher,
      open_world_encounter_anchor_payload(0, encounter.digest()),
      epoch.eligible_anchor_root(),
      wrong_proof,
    ),
  )
  match
    evaluate_open_world_encounter(
      hasher,
      verifier,
      epoch,
      encounter,
      eligibility_proof=wrong_proof,
      outcome_class=@audit.OpenWorldOutcomeClass::Ephemeral,
    ) {
    EncounterAnchorNotCommitted => ()
    EncounterEpochAuthorityMismatch => fail("unexpected authority mismatch")
    EncounterEpochParentMismatch => fail("unexpected epoch parent mismatch")
    EncounterInvalidAnchor => fail("unexpected empty anchor")
    _ => fail("post-reveal or uncommitted encounter entered audit routing")
  }
}

///|
test "a signed participant challenge overrides the peer fast path" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let challenger = @bft.MockSigner::new("encounter-challenger")
  let (epoch, encounter, certificate, proof) = witnessed_open_world_encounter()
  let prepared = @checkpoint.prepare_checkpoint(hasher, encounter.checkpoint())
  let evidence = @attestation.EvidenceCollector::new(
    hasher,
    verifier,
    prepared,
    [{ id: "challenger", key: challenger.public_key() }],
  )
  ignore(
    evidence.deliver(
      @attestation.sign_attestation(
        hasher,
        challenger,
        prepared,
        "challenger",
        @attestation.AttestationChoice::Challenge,
      ),
    ),
  )
  match
    evaluate_open_world_encounter(
      hasher,
      verifier,
      epoch,
      encounter,
      eligibility_proof=proof,
      outcome_class=@audit.OpenWorldOutcomeClass::Durable,
      peer_certificate=certificate,
      participant_evidence=evidence,
    ) {
    EncounterCentralReplayRequired => ()
    _ => fail("signed challenge did not trigger selective central replay")
  }
}

///|
test "encounter authority parent and participant evidence stay epoch bound" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-referee")
  let intruder = @bft.MockSigner::new("intruder-referee")
  let plan = open_world_epoch_plan(hasher, verifier, authority, 0, 1)
  let wrong_authority = open_world_encounter(
    hasher,
    verifier,
    plan.digest(),
    intruder,
    @bft.Digest("public-encounter-kernel-v1"),
  )
  let wrong_parent = open_world_encounter(
    hasher,
    verifier,
    @bft.Digest("another-audit-epoch"),
    authority,
    @bft.Digest("public-encounter-kernel-v1"),
    registration_index=1,
    event_root="wrong-parent-events",
  )
  let eligible = @merkle.MerkleTree::build(hasher, [
    open_world_encounter_anchor_payload(0, wrong_authority.digest()),
    open_world_encounter_anchor_payload(1, wrong_parent.digest()),
  ])
  let registry = open_world_registry(hasher, [
    (0, wrong_authority.digest()),
    (1, wrong_parent.digest()),
  ])
  let seal = sealed_open_world_epoch(
    hasher,
    verifier,
    authority,
    plan,
    eligible.root(),
    registry.root(),
    registered_count=2,
  )
  let epoch = reveal_epoch_with_root(hasher, plan, seal, 2, 0, 1)
  match
    evaluate_open_world_encounter(
      hasher,
      verifier,
      epoch,
      wrong_authority,
      eligibility_proof=proof_or_fail(eligible, 0),
      outcome_class=@audit.OpenWorldOutcomeClass::Ephemeral,
    ) {
    EncounterEpochAuthorityMismatch => ()
    _ => fail("encounter signed by another authority crossed audit epoch")
  }
  match
    evaluate_open_world_encounter(
      hasher,
      verifier,
      epoch,
      wrong_parent,
      eligibility_proof=proof_or_fail(eligible, 1),
      outcome_class=@audit.OpenWorldOutcomeClass::Ephemeral,
    ) {
    EncounterEpochParentMismatch => ()
    _ => fail("encounter from another audit epoch crossed the parent boundary")
  }

  let (valid_epoch, valid, valid_proof) = sparse_encounter_fixture(0, 1)
  let foreign_prepared = @checkpoint.prepare_checkpoint(hasher, {
    ..valid.checkpoint(),
    event_root: @bft.Digest("foreign-evidence-events"),
  })
  let foreign_evidence = @attestation.EvidenceCollector::new(
    hasher,
    verifier,
    foreign_prepared,
    [],
  )
  match
    evaluate_open_world_encounter(
      hasher,
      verifier,
      valid_epoch,
      valid,
      eligibility_proof=valid_proof,
      outcome_class=@audit.OpenWorldOutcomeClass::Ephemeral,
      participant_evidence=foreign_evidence,
    ) {
    EncounterEvidenceMismatch => ()
    _ => fail("participant evidence crossed encounter checkpoints")
  }
}

///|
fn central_replayed_open_world_encounter() -> (
  RevealedOpenWorldAuditEpoch,
  @checkpoint.VerifiedCheckpoint,
  @replay.CheckpointReplayMatch,
  @merkle.MerkleProof,
) raise Error {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-referee")
  let plan = open_world_epoch_plan(hasher, verifier, authority, 1, 1)
  let session_id = "world-1:encounter-central"
  let adapter = @bft.BFTAdapter::new(hasher, verifier, session_id~)
  assert_true(
    adapter.register_peer(@types.PeerId("authority"), authority.public_key()),
  )
  let attack : @replay.TelegraphedAttack = {
    attack_id: "central-audit-attack",
    visible_tick: 10,
    resolve_tick: 14,
    center_x: 0,
    radius: 1,
  }
  let event = @replay.make_dungeon_telegraph_event(
    peer=@types.PeerId("authority"),
    counter=0,
    lamport=1,
    deps=[],
    attack~,
  )
  let authenticated = match
    adapter.deliver(adapter.sign(authority, event, [])) {
    Accepted(source) => source
    _ => fail("expected authenticated central replay source")
  }
  let candidate = match
    @replay.prepare_dungeon_encounter(
      hasher,
      session_id~,
      authority_key=authority.public_key(),
      config={
        encounter_id: "central-audit-encounter",
        player_max_hp: 2,
        attack_rules: {
          min_reaction_ticks: 2,
          max_backdate_ticks: 2,
          max_dodge_distance: 4,
          arena_min_x: -10,
          arena_max_x: 10,
          loot_item_type: "audit-token",
        },
      },
      players=[
        {
          player_id: "alice",
          public_key: @bft.PublicKey("alice"),
          initial_x: 0,
        },
      ],
      attacks=[{ attack, damage: 1 }],
      transcripts=[
        {
          attack_id: attack.attack_id,
          telegraph: authenticated,
          dodge_evidence: [],
        },
      ],
    ) {
    CandidateReady(value) => value
    _ => fail("expected central replay candidate")
  }
  let prepared = @checkpoint.prepare_checkpoint(hasher, {
    session_id,
    epoch: 0,
    previous_checkpoint: plan.digest(),
    manifest_digest: candidate.manifest_digest(),
    event_root: candidate.event_root(),
    public_state_root: candidate.public_state_root(),
    asset_delta_root: @bft.Digest("central-audit-assets"),
    hidden_state_commitment: None,
  })
  let encounter = verified_open_world_checkpoint(
    hasher, verifier, authority, prepared,
  )
  let replay_match = match
    @replay.finalize_dungeon_encounter(candidate, encounter) {
    EncounterFinalized(resolution) => resolution.replay_match()
    _ => fail("expected checkpoint-bound central replay")
  }
  let eligible = @merkle.MerkleTree::build(hasher, [
    open_world_encounter_anchor_payload(0, encounter.digest()),
  ])
  let registry = open_world_registry(hasher, [(0, encounter.digest())])
  let seal = sealed_open_world_epoch(
    hasher,
    verifier,
    authority,
    plan,
    eligible.root(),
    registry.root(),
    registered_count=1,
  )
  (
    reveal_epoch_with_root(hasher, plan, seal, 1, 1, 1),
    encounter,
    replay_match,
    proof_or_fail(eligible, 0),
  )
}

///|
test "matching central replay resolves sampled and high value encounters" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let (epoch, encounter, replay_match, proof) = central_replayed_open_world_encounter()
  match
    evaluate_open_world_encounter(
      hasher,
      verifier,
      epoch,
      encounter,
      eligibility_proof=proof,
      outcome_class=@audit.OpenWorldOutcomeClass::HighValue,
      central_replay=replay_match,
    ) {
    EncounterCentralFinalized(finalized) =>
      assert_eq(finalized.digest(), encounter.digest())
    _ => fail("matching central replay did not finalize selected encounter")
  }
}

///|
test "signed slot beyond the committed registry count proves truncation" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-referee")
  let plan = open_world_epoch_plan(hasher, verifier, authority, 0, 1)
  let omitted = open_world_encounter(
    hasher,
    verifier,
    plan.digest(),
    authority,
    @bft.Digest("public-encounter-kernel-v1"),
    registration_index=2,
  )
  let registered = @bft.Digest("registered-slot-zero")
  let tree = @merkle.MerkleTree::build(hasher, [
    open_world_encounter_anchor_payload(0, registered),
  ])
  let registry = open_world_registry(hasher, [(0, registered)])
  let seal = sealed_open_world_epoch(
    hasher,
    verifier,
    authority,
    plan,
    tree.root(),
    registry.root(),
    registered_count=1,
  )
  let epoch = reveal_epoch_with_root(hasher, plan, seal, 1, 0, 1)
  match detect_open_world_seal_conflict(hasher, epoch, omitted) {
    SealConflictDetected(conflict) => {
      assert_eq(conflict.kind(), OpenWorldSealConflictKind::TruncatedRegistry)
      assert_eq(conflict.encounter_digest(), omitted.digest())
      assert_eq(conflict.registration_index(), 2)
      assert_eq(conflict.sealed_encounter_digest(), None)
      assert_eq(conflict.seal_checkpoint_digest(), seal.digest())
    }
    _ => fail("signed out-of-range registration did not prove truncation")
  }
}

///|
test "a different included digest at the signed slot proves substitution" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-referee")
  let plan = open_world_epoch_plan(hasher, verifier, authority, 0, 1)
  let omitted = open_world_encounter(
    hasher,
    verifier,
    plan.digest(),
    authority,
    @bft.Digest("public-encounter-kernel-v1"),
    registration_index=0,
  )
  let substituted = @bft.Digest("different-encounter-at-slot-zero")
  let tree = @merkle.MerkleTree::build(hasher, [
    open_world_encounter_anchor_payload(0, substituted),
  ])
  let registry = open_world_registry(hasher, [(0, substituted)])
  let seal = sealed_open_world_epoch(
    hasher,
    verifier,
    authority,
    plan,
    tree.root(),
    registry.root(),
    registered_count=1,
  )
  let epoch = reveal_epoch_with_root(hasher, plan, seal, 1, 0, 1)
  let proof = proof_or_fail(tree, 0)
  match
    detect_open_world_seal_conflict(
      hasher,
      epoch,
      omitted,
      sealed_encounter_digest=substituted,
      conflicting_inclusion=proof,
    ) {
    SealConflictDetected(conflict) => {
      assert_eq(conflict.kind(), OpenWorldSealConflictKind::SubstitutedSlot)
      assert_eq(conflict.registration_index(), 0)
      assert_eq(conflict.sealed_encounter_digest(), Some(substituted))
    }
    _ => fail("conflicting included digest did not prove substitution")
  }
}

///|
test "invalid or matching inclusion evidence never accuses the seal" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-referee")
  let plan = open_world_epoch_plan(hasher, verifier, authority, 0, 1)
  let encounter = open_world_encounter(
    hasher,
    verifier,
    plan.digest(),
    authority,
    @bft.Digest("public-encounter-kernel-v1"),
    registration_index=0,
  )
  let tree = @merkle.MerkleTree::build(hasher, [
    open_world_encounter_anchor_payload(0, encounter.digest()),
  ])
  let registry = open_world_registry(hasher, [(0, encounter.digest())])
  let seal = sealed_open_world_epoch(
    hasher,
    verifier,
    authority,
    plan,
    tree.root(),
    registry.root(),
    registered_count=1,
  )
  let epoch = reveal_epoch_with_root(hasher, plan, seal, 1, 0, 1)
  let proof = proof_or_fail(tree, 0)
  assert_true(
    detect_open_world_seal_conflict(
      hasher,
      epoch,
      encounter,
      sealed_encounter_digest=encounter.digest(),
      conflicting_inclusion=proof,
    )
    is SealConflictNotFound,
  )
  assert_true(
    detect_open_world_seal_conflict(
      hasher,
      epoch,
      encounter,
      sealed_encounter_digest=@bft.Digest("invented-conflict"),
      conflicting_inclusion=proof,
    )
    is SealConflictEvidenceInvalid,
  )
}

///|
test "authenticated non-membership proves an omitted in-range slot" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-referee")
  let plan = open_world_epoch_plan(hasher, verifier, authority, 0, 1)
  let omitted = open_world_encounter(
    hasher,
    verifier,
    plan.digest(),
    authority,
    @bft.Digest("public-encounter-kernel-v1"),
    registration_index=1,
  )
  let slot_zero = @bft.Digest("registered-slot-zero")
  let slot_two = @bft.Digest("registered-slot-two")
  let tree = @merkle.MerkleTree::build(hasher, [
    open_world_encounter_anchor_payload(0, slot_zero),
    open_world_encounter_anchor_payload(2, slot_two),
  ])
  let registry = open_world_registry(hasher, [(0, slot_zero), (2, slot_two)])
  let seal = sealed_open_world_epoch(
    hasher,
    verifier,
    authority,
    plan,
    tree.root(),
    registry.root(),
    registered_count=3,
  )
  let epoch = reveal_epoch_with_root(hasher, plan, seal, 3, 0, 1)
  let absence = registry
    .absence_proof(open_world_encounter_registration_key(1))
    .unwrap()
  match
    detect_open_world_seal_conflict(
      hasher,
      epoch,
      omitted,
      missing_registration=absence,
    ) {
    SealConflictDetected(conflict) => {
      assert_eq(conflict.kind(), OpenWorldSealConflictKind::MissingSlot)
      assert_eq(
        conflict.source(),
        OpenWorldSealConflictSource::AuthoritySignedEncounter,
      )
      assert_eq(conflict.registration_index(), 1)
      assert_eq(conflict.sealed_encounter_digest(), None)
      assert_eq(conflict.observer_approval_count(), None)
    }
    _ => fail("authenticated empty registry slot did not prove omission")
  }
}

///|
test "tampered or ambiguous non-membership cannot accuse the seal" {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-referee")
  let plan = open_world_epoch_plan(hasher, verifier, authority, 0, 1)
  let omitted = open_world_encounter(
    hasher,
    verifier,
    plan.digest(),
    authority,
    @bft.Digest("public-encounter-kernel-v1"),
    registration_index=1,
  )
  let substituted = @bft.Digest("registered-slot-zero")
  let tree = @merkle.MerkleTree::build(hasher, [
    open_world_encounter_anchor_payload(0, substituted),
  ])
  let registry = open_world_registry(hasher, [(0, substituted)])
  let seal = sealed_open_world_epoch(
    hasher,
    verifier,
    authority,
    plan,
    tree.root(),
    registry.root(),
    registered_count=2,
  )
  let epoch = reveal_epoch_with_root(hasher, plan, seal, 2, 0, 1)
  let absence = registry
    .absence_proof(open_world_encounter_registration_key(1))
    .unwrap()
  let tampered : @authmap.AuthMapAbsenceProof = {
    ..absence,
    key: open_world_encounter_registration_key(0),
  }
  assert_true(
    detect_open_world_seal_conflict(
      hasher,
      epoch,
      omitted,
      missing_registration=tampered,
    )
    is SealConflictEvidenceInvalid,
  )
  assert_true(
    detect_open_world_seal_conflict(
      hasher,
      epoch,
      omitted,
      missing_registration=absence,
      sealed_encounter_digest=substituted,
      conflicting_inclusion=proof_or_fail(tree, 0),
    )
    is SealConflictEvidenceInvalid,
  )
}
