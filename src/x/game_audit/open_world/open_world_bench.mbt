///|
fn bench_verified_checkpoint(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  authority : &@bft.Signer,
  checkpoint : @checkpoint.Checkpoint,
) -> @checkpoint.VerifiedCheckpoint {
  let prepared = @checkpoint.prepare_checkpoint(hasher, checkpoint)
  let signed = @checkpoint.sign_prepared_checkpoint(authority, prepared)
  match
    @checkpoint.open_checkpoint(
      hasher,
      verifier,
      authority.public_key(),
      signed,
    ) {
    Opened(verified) => verified
    _ => abort("benchmark checkpoint verification failed")
  }
}

///|
fn bench_open_world_fixture() -> (
  RevealedOpenWorldAuditEpoch,
  @checkpoint.VerifiedCheckpoint,
  @merkle.MerkleProof,
) {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("world-referee")
  let game_manifest = @bft.Digest("open-world-bench-kernel-v1")
  let observer_manifest = open_world_observer_manifest(
    hasher,
    observers=[],
    max_faults=0,
  )
  let seed = "benchmark-delayed-seed"
  let manifest = open_world_audit_manifest(
    hasher,
    game_manifest_digest=game_manifest,
    observer_manifest_digest=observer_manifest,
    sample_numerator=1,
    sample_denominator=100,
  )
  let plan = bench_verified_checkpoint(hasher, verifier, authority, {
    session_id: "benchmark-world",
    epoch: 100,
    previous_checkpoint: @bft.Digest("epoch-99"),
    manifest_digest: manifest,
    event_root: @bft.Digest("epoch-start"),
    public_state_root: @bft.Digest("world-start-state"),
    asset_delta_root: @bft.Digest("no-assets"),
    hidden_state_commitment: Some(
      open_world_audit_seed_commitment(
        hasher,
        world_id="benchmark-world",
        epoch=100,
        seed~,
      ),
    ),
  })
  let encounter = bench_verified_checkpoint(hasher, verifier, authority, {
    session_id: "benchmark-world:encounter-1",
    epoch: 0,
    previous_checkpoint: plan.digest(),
    manifest_digest: @bft.Digest("encounter-kernel"),
    event_root: @bft.Digest("encounter-events"),
    public_state_root: @bft.Digest("encounter-state"),
    asset_delta_root: @bft.Digest("encounter-assets"),
    hidden_state_commitment: None,
  })
  let tree = @merkle.MerkleTree::build(hasher, [
    open_world_encounter_anchor_payload(0, encounter.digest()),
  ])
  let registry = @authmap.AuthenticatedMap::new(hasher)
  ignore(
    registry.put(open_world_encounter_registration_key(0), encounter.digest().0),
  )
  let seal = bench_verified_checkpoint(hasher, verifier, authority, {
    session_id: "benchmark-world",
    epoch: 101,
    previous_checkpoint: plan.digest(),
    manifest_digest: open_world_anchor_seal_manifest(
      hasher,
      audit_manifest_digest=manifest,
      registered_count=1,
    ),
    event_root: tree.root(),
    public_state_root: registry.root(),
    asset_delta_root: @bft.Digest("epoch-assets"),
    hidden_state_commitment: None,
  })
  let epoch = match
    reveal_open_world_audit_epoch(
      hasher,
      plan,
      seal,
      game_manifest_digest=game_manifest,
      observer_manifest_digest=observer_manifest,
      sample_numerator=1,
      sample_denominator=100,
      registered_count=1,
      seed~,
    ) {
    AuditEpochRevealed(epoch) => epoch
    _ => abort("benchmark audit epoch reveal failed")
  }
  let proof = match tree.proof(0) {
    Some(proof) => proof
    None => abort("benchmark eligibility proof missing")
  }
  (epoch, encounter, proof)
}

///|
test "bench: select 1000 delayed open-world audit samples" (b : @bench.T) {
  let (epoch, _, _) = bench_open_world_fixture()
  b.bench(fn() {
    for index in 0..<1000 {
      b.keep(epoch.selects_encounter(@bft.Digest(index.to_string())))
    }
  })
}

///|
test "bench: evaluate 1000 Merkle-eligible provisional encounters" (
  b : @bench.T,
) {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let (epoch, encounter, proof) = bench_open_world_fixture()
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(
        evaluate_open_world_encounter(
          hasher,
          verifier,
          epoch,
          encounter,
          eligibility_proof=proof,
          outcome_class=@audit.OpenWorldOutcomeClass::Ephemeral,
        ),
      )
    }
  })
}

///|
test "bench: reject 1000 false seal-conflict accusations" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let (epoch, encounter, proof) = bench_open_world_fixture()
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(
        detect_open_world_seal_conflict(
          hasher,
          epoch,
          encounter,
          sealed_encounter_digest=encounter.digest(),
          conflicting_inclusion=proof,
        ),
      )
    }
  })
}

///|
fn bench_observer_registration_fixture() -> (
  @checkpoint.VerifiedCheckpoint,
  Array[@attestation.Participant],
  Array[SignedOpenWorldRegistrationObservation],
) {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("benchmark-world-authority")
  let observers : Array[@attestation.Participant] = []
  for index in 0..<4 {
    let id = "benchmark-observer-" + index.to_string()
    let signer = @bft.MockSigner::new(id)
    observers.push({ id, key: signer.public_key() })
  }
  let observer_manifest = open_world_observer_manifest(
    hasher,
    observers~,
    max_faults=1,
  )
  let manifest = open_world_audit_manifest(
    hasher,
    game_manifest_digest=@bft.Digest("observer-benchmark-kernel-v1"),
    observer_manifest_digest=observer_manifest,
    sample_numerator=1,
    sample_denominator=100,
  )
  let plan = bench_verified_checkpoint(hasher, verifier, authority, {
    session_id: "observer-benchmark-world",
    epoch: 500,
    previous_checkpoint: @bft.Digest("observer-benchmark-epoch-499"),
    manifest_digest: manifest,
    event_root: @bft.Digest("observer-benchmark-events"),
    public_state_root: @bft.Digest("observer-benchmark-state"),
    asset_delta_root: @bft.Digest("no-assets"),
    hidden_state_commitment: Some(
      open_world_audit_seed_commitment(
        hasher,
        world_id="observer-benchmark-world",
        epoch=500,
        seed="observer-benchmark-seed",
      ),
    ),
  })
  let rebound : Array[SignedOpenWorldRegistrationObservation] = []
  for index in 0..<3 {
    let id = observers[index].id
    let signer = @bft.MockSigner::new(id)
    let ledger = match
      OpenWorldObserverSigningLedger::new(hasher, signer, observer_id=id) {
      ObserverSigningLedgerReady(ledger) => ledger
      _ => abort("benchmark observer signing ledger failed")
    }
    match
      ledger.sign_registration(
        audit_checkpoint_digest=plan.digest(),
        registration_index=7777,
        encounter_digest=@bft.Digest("observed-encounter-7777"),
      ) {
      ObserverObservationSigned(receipt) => rebound.push(receipt)
      _ => abort("benchmark observer registration signing failed")
    }
  }
  (plan, observers, rebound)
}

///|
fn bench_observer_certificate(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  plan : @checkpoint.VerifiedCheckpoint,
  observers : Array[@attestation.Participant],
  receipts : Array[SignedOpenWorldRegistrationObservation],
) -> OpenWorldRegistrationCertificate {
  let collector = match
    OpenWorldRegistrationObserverCollector::new(
      hasher,
      verifier,
      plan,
      game_manifest_digest=@bft.Digest("observer-benchmark-kernel-v1"),
      sample_numerator=1,
      sample_denominator=100,
      observers~,
      max_faults=1,
      registration_index=7777,
      encounter_digest=@bft.Digest("observed-encounter-7777"),
    ) {
    RegistrationObserverCollectorReady(collector) => collector
    _ => abort("benchmark observer collector failed")
  }
  for receipt in receipts {
    ignore(collector.deliver(receipt))
  }
  match collector.certify() {
    RegistrationObserved(certificate) => certificate
    _ => abort("benchmark observer certificate failed")
  }
}

///|
test "bench: certify 1000 four-observer registrations" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let (plan, observers, receipts) = bench_observer_registration_fixture()
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(
        bench_observer_certificate(hasher, verifier, plan, observers, receipts),
      )
    }
  })
}

///|
fn bench_observed_omission_fixture() -> (
  RevealedOpenWorldAuditEpoch,
  OpenWorldRegistrationCertificate,
  @authmap.AuthMapAbsenceProof,
) {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("benchmark-world-authority")
  let (plan, observers, receipts) = bench_observer_registration_fixture()
  let certificate = bench_observer_certificate(
    hasher, verifier, plan, observers, receipts,
  )
  let registry = @authmap.AuthenticatedMap::new(hasher)
  for index in 0..<10000 {
    if index != 7777 {
      ignore(
        registry.put(
          open_world_encounter_registration_key(index),
          "encounter-" + index.to_string(),
        ),
      )
    }
  }
  let empty_tree = @merkle.MerkleTree::build(hasher, [])
  let seal = bench_verified_checkpoint(hasher, verifier, authority, {
    session_id: "observer-benchmark-world",
    epoch: 501,
    previous_checkpoint: plan.digest(),
    manifest_digest: open_world_anchor_seal_manifest(
      hasher,
      audit_manifest_digest=plan.checkpoint().manifest_digest,
      registered_count=10000,
    ),
    event_root: empty_tree.root(),
    public_state_root: registry.root(),
    asset_delta_root: @bft.Digest("no-assets"),
    hidden_state_commitment: None,
  })
  let epoch = match
    reveal_open_world_audit_epoch(
      hasher,
      plan,
      seal,
      game_manifest_digest=@bft.Digest("observer-benchmark-kernel-v1"),
      observer_manifest_digest=open_world_observer_manifest(
        hasher,
        observers~,
        max_faults=1,
      ),
      sample_numerator=1,
      sample_denominator=100,
      registered_count=10000,
      seed="observer-benchmark-seed",
    ) {
    AuditEpochRevealed(epoch) => epoch
    _ => abort("benchmark observed omission epoch failed")
  }
  let absence = match
    registry.absence_proof(open_world_encounter_registration_key(7777)) {
    Some(proof) => proof
    None => abort("benchmark observed omission proof missing")
  }
  (epoch, certificate, absence)
}

///|
test "bench: detect 1000 observed omissions in 10000 slots" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let (epoch, certificate, absence) = bench_observed_omission_fixture()
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(
        detect_observed_open_world_seal_conflict(
          hasher,
          epoch,
          certificate,
          missing_registration=absence,
        ),
      )
    }
  })
}

///|
test "bench: sign 1000 observer ledger registrations" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let signer = @bft.MockSigner::new("benchmark-signing-observer")
  b.bench(fn() {
    let ledger = match
      OpenWorldObserverSigningLedger::new(
        hasher,
        signer,
        observer_id="benchmark-signing-observer",
      ) {
      ObserverSigningLedgerReady(ledger) => ledger
      _ => abort("benchmark signing ledger build failed")
    }
    for index in 0..<1000 {
      b.keep(
        ledger.sign_registration(
          audit_checkpoint_digest=@bft.Digest("benchmark-signing-plan"),
          registration_index=index,
          encounter_digest=@bft.Digest("encounter-" + index.to_string()),
        ),
      )
    }
  })
}

///|
test "bench: reject 1000 conflicting observer signatures" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let signer = @bft.MockSigner::new("benchmark-signing-observer")
  let ledger = match
    OpenWorldObserverSigningLedger::new(
      hasher,
      signer,
      observer_id="benchmark-signing-observer",
    ) {
    ObserverSigningLedgerReady(ledger) => ledger
    _ => abort("benchmark signing ledger build failed")
  }
  ignore(
    ledger.sign_registration(
      audit_checkpoint_digest=@bft.Digest("benchmark-signing-plan"),
      registration_index=7,
      encounter_digest=@bft.Digest("original-encounter"),
    ),
  )
  b.bench(fn() {
    for index in 0..<1000 {
      b.keep(
        ledger.sign_registration(
          audit_checkpoint_digest=@bft.Digest("benchmark-signing-plan"),
          registration_index=7,
          encounter_digest=@bft.Digest("conflict-" + index.to_string()),
        ),
      )
    }
  })
}

///|
test "bench: validate 1000 trusted observer signing anchors" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let signer = @bft.MockSigner::new("benchmark-anchored-observer")
  let store = OpenWorldInMemoryObserverSigningStore::new(hasher)
  let ledger = match
    OpenWorldObserverSigningLedger::new_with_store(
      hasher,
      signer,
      observer_id="benchmark-anchored-observer",
      store~,
    ) {
    ObserverSigningLedgerReady(ledger) => ledger
    _ => abort("benchmark anchored ledger build failed")
  }
  ignore(
    ledger.sign_registration(
      audit_checkpoint_digest=@bft.Digest("benchmark-signing-plan"),
      registration_index=1,
      encounter_digest=@bft.Digest("benchmark-encounter"),
    ),
  )
  let anchor = ledger.anchor()
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(
        OpenWorldObserverSigningLedger::new_with_store(
          hasher,
          signer,
          observer_id="benchmark-anchored-observer",
          store~,
          trusted_anchor=anchor,
        ),
      )
    }
  })
}

///|
test "bench: reject 1000 rolled-back observer signing stores" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let signer = @bft.MockSigner::new("benchmark-anchored-observer")
  let committed_store = OpenWorldInMemoryObserverSigningStore::new(hasher)
  let committed = match
    OpenWorldObserverSigningLedger::new_with_store(
      hasher,
      signer,
      observer_id="benchmark-anchored-observer",
      store=committed_store,
    ) {
    ObserverSigningLedgerReady(ledger) => ledger
    _ => abort("benchmark committed ledger build failed")
  }
  ignore(
    committed.sign_registration(
      audit_checkpoint_digest=@bft.Digest("benchmark-signing-plan"),
      registration_index=1,
      encounter_digest=@bft.Digest("benchmark-encounter"),
    ),
  )
  let anchor = committed.anchor()
  let rolled_back_store = OpenWorldInMemoryObserverSigningStore::new(hasher)
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(
        OpenWorldObserverSigningLedger::new_with_store(
          hasher,
          signer,
          observer_id="benchmark-anchored-observer",
          store=rolled_back_store,
          trusted_anchor=anchor,
        ),
      )
    }
  })
}

///|
test "bench: verify 1000 signing anchors in a 1024-observer map" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("benchmark-anchor-authority")
  let log_session_id = "benchmark-world:observer-signing-anchors"
  let anchors : Array[OpenWorldObserverSigningAnchor] = []
  let anchor_map = @authmap.AuthenticatedMap::new(hasher)
  for index in 0..<1024 {
    let anchor = OpenWorldObserverSigningAnchor::{
      observer_id: "observer-" + index.to_string(),
      signer_key: @bft.PublicKey("observer-key-" + index.to_string()),
      root: @bft.Digest("observer-root-" + index.to_string()),
      size: 100 + index,
    }
    anchors.push(anchor)
    ignore(
      anchor_map.put(
        open_world_observer_signing_anchor_key(anchor),
        open_world_observer_signing_anchor_value(anchor),
      ),
    )
  }
  let checkpoint = bench_verified_checkpoint(hasher, verifier, authority, {
    session_id: log_session_id,
    epoch: 72,
    previous_checkpoint: @bft.Digest("benchmark-anchor-batch-71"),
    manifest_digest: open_world_observer_signing_anchor_log_manifest(
      hasher,
      log_session_id~,
    ),
    event_root: @bft.Digest("benchmark-anchor-publication-events"),
    public_state_root: anchor_map.root(),
    asset_delta_root: @bft.Digest("no-assets"),
    hidden_state_commitment: None,
  })
  let target = anchors[777]
  let proof = match
    anchor_map.proof(open_world_observer_signing_anchor_key(target)) {
    Some(proof) => proof
    None => abort("benchmark signing anchor proof missing")
  }
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(
        open_published_open_world_observer_signing_anchor(
          hasher,
          checkpoint,
          log_session_id~,
          anchor=target,
          membership_proof=proof,
        ),
      )
    }
  })
}

///|
fn bench_published_signing_anchor_head(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  authority : &@bft.Signer,
  log_session_id : String,
  epoch : Int,
  previous_checkpoint : @bft.Digest,
  root_label : String,
) -> PublishedOpenWorldObserverSigningAnchor {
  let anchor = OpenWorldObserverSigningAnchor::{
    observer_id: "benchmark-head-observer",
    signer_key: @bft.PublicKey("benchmark-head-observer-key"),
    root: @bft.Digest(root_label),
    size: epoch + 1,
  }
  let anchor_map = @authmap.AuthenticatedMap::new(hasher)
  let key = open_world_observer_signing_anchor_key(anchor)
  ignore(anchor_map.put(key, open_world_observer_signing_anchor_value(anchor)))
  let checkpoint = bench_verified_checkpoint(hasher, verifier, authority, {
    session_id: log_session_id,
    epoch,
    previous_checkpoint,
    manifest_digest: open_world_observer_signing_anchor_log_manifest(
      hasher,
      log_session_id~,
    ),
    event_root: @bft.Digest("benchmark-anchor-head-events"),
    public_state_root: anchor_map.root(),
    asset_delta_root: @bft.Digest("no-assets"),
    hidden_state_commitment: None,
  })
  let proof = match anchor_map.proof(key) {
    Some(proof) => proof
    None => abort("benchmark anchor head proof missing")
  }
  match
    open_published_open_world_observer_signing_anchor(
      hasher,
      checkpoint,
      log_session_id~,
      anchor~,
      membership_proof=proof,
    ) {
    ObserverSigningAnchorPublished(published) => published
    _ => abort("benchmark anchor head publication failed")
  }
}

///|
fn bench_published_signing_anchor_chain(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  authority : &@bft.Signer,
  session : String,
  head_count : Int,
) -> Array[PublishedOpenWorldObserverSigningAnchor] {
  let heads : Array[PublishedOpenWorldObserverSigningAnchor] = []
  let mut previous = @bft.Digest("benchmark-head-genesis")
  for epoch in 0..<head_count {
    let head = bench_published_signing_anchor_head(
      hasher,
      verifier,
      authority,
      session,
      epoch,
      previous,
      "benchmark-head-root-" + epoch.to_string(),
    )
    previous = head.publication_checkpoint_digest()
    heads.push(head)
  }
  heads
}

///|
test "bench: advance 1000 gossiped signing anchor heads" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("benchmark-head-authority")
  let session = "benchmark-world:anchor-head-gossip"
  let heads = bench_published_signing_anchor_chain(
    hasher, verifier, authority, session, 1001,
  )
  b.bench(fn() {
    let tracker = OpenWorldObserverSigningAnchorHeadTracker::new(heads[0])
    for index in 1..<heads.length() {
      b.keep(tracker.deliver(heads[index]))
    }
  })
}

///|
test "bench: recover 1000 signing anchor head gaps atomically" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("benchmark-batch-authority")
  let session = "benchmark-world:anchor-head-batch"
  let heads = bench_published_signing_anchor_chain(
    hasher, verifier, authority, session, 1001,
  )
  let recovery : Array[PublishedOpenWorldObserverSigningAnchor] = []
  for index in 1..<heads.length() {
    recovery.push(heads[index])
  }
  b.bench(fn() {
    let tracker = OpenWorldObserverSigningAnchorHeadTracker::new(heads[0])
    b.keep(tracker.deliver_batch(recovery))
  })
}

///|
test "bench: detect 1000 signing anchor checkpoint forks" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let authority = @bft.MockSigner::new("benchmark-fork-authority")
  let session = "benchmark-world:anchor-head-forks"
  let accepted = bench_published_signing_anchor_head(
    hasher,
    verifier,
    authority,
    session,
    50,
    @bft.Digest("benchmark-head-49"),
    "accepted-head-root",
  )
  let conflicting = bench_published_signing_anchor_head(
    hasher,
    verifier,
    authority,
    session,
    50,
    @bft.Digest("benchmark-head-49"),
    "conflicting-head-root",
  )
  b.bench(fn() {
    let tracker = OpenWorldObserverSigningAnchorHeadTracker::new(accepted)
    for _ in 0..<1000 {
      b.keep(tracker.deliver(conflicting))
    }
  })
}
