///|
fn bench_prepared() -> @checkpoint.PreparedCheckpoint {
  @checkpoint.prepare_checkpoint(@bft.FnvHasher::new(), @checkpoint.Checkpoint::{
    session_id: "dungeon-42",
    epoch: 7,
    previous_checkpoint: @bft.Digest("previous"),
    manifest_digest: @bft.Digest("manifest"),
    event_root: @bft.Digest("events"),
    public_state_root: @bft.Digest("state"),
    asset_delta_root: @bft.Digest("items"),
    hidden_state_commitment: None,
  })
}

///|
fn bench_roster(size : Int) -> (Array[@bft.MockSigner], Array[Participant]) {
  let signers : Array[@bft.MockSigner] = []
  let roster : Array[Participant] = []
  for i in 0..<size {
    let id = "peer-" + i.to_string()
    let signer = @bft.MockSigner::new(id)
    signers.push(signer)
    roster.push({ id, key: signer.public_key() })
  }
  (signers, roster)
}

///|
test "bench: sign 1000 participant approvals" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let signer = @bft.MockSigner::new("alice")
  let target = bench_prepared()
  b.bench(fn() {
    for i in 0..<1000 {
      b.keep(
        sign_attestation(
          hasher,
          signer,
          target,
          "alice-" + i.to_string(),
          Approve,
        ),
      )
    }
  })
}

///|
test "bench: verify and collect 8 participant approvals" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let target = bench_prepared()
  let (signers, roster) = bench_roster(8)
  let signed : Array[SignedAttestation] = []
  for i in 0..<8 {
    signed.push(
      sign_attestation(hasher, signers[i], target, roster[i].id, Approve),
    )
  }
  b.bench(fn() {
    let collector = EvidenceCollector::new(hasher, verifier, target, roster)
    for item in signed {
      b.keep(collector.deliver(item))
    }
    b.keep(collector.evidence())
  })
}

///|
test "bench: verify and collect 64 participant approvals" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let target = bench_prepared()
  let (signers, roster) = bench_roster(64)
  let signed : Array[SignedAttestation] = []
  for i in 0..<64 {
    signed.push(
      sign_attestation(hasher, signers[i], target, roster[i].id, Approve),
    )
  }
  b.bench(fn() {
    let collector = EvidenceCollector::new(hasher, verifier, target, roster)
    for item in signed {
      b.keep(collector.deliver(item))
    }
    b.keep(collector.evidence())
  })
}

///|
fn bench_replay_witness_target(
  hasher : &@bft.Hasher,
  referee : &@bft.Signer,
  roster : Array[Participant],
  max_faults : Int,
) -> @checkpoint.PreparedCheckpoint {
  let manifest = replay_witness_session_manifest(
    hasher,
    game_manifest_digest=@bft.Digest("pvp-bench-kernel-v1"),
    referee_key=referee.public_key(),
    witnesses=roster,
    max_faults~,
  )
  @checkpoint.prepare_checkpoint(hasher, {
    ..bench_prepared().checkpoint(),
    manifest_digest: manifest,
  })
}

///|
fn bench_verified_referee_checkpoint(
  hasher : &@bft.Hasher,
  verifier : &@bft.Verifier,
  referee : &@bft.Signer,
  target : @checkpoint.PreparedCheckpoint,
) -> @checkpoint.VerifiedCheckpoint {
  let signed = @checkpoint.sign_prepared_checkpoint(referee, target)
  match
    @checkpoint.open_checkpoint(hasher, verifier, referee.public_key(), signed) {
    Opened(verified) => verified
    _ => abort("benchmark referee checkpoint verification failed")
  }
}

///|
fn bench_replay_witness_certificate(
  b : @bench.T,
  witness_count : Int,
  max_faults : Int,
) -> Unit {
  let hasher = @bft.FnvHasher::new()
  let verifier = @bft.MockVerifier::new()
  let referee = @bft.MockSigner::new("referee")
  let (signers, roster) = bench_roster(witness_count)
  let target = bench_replay_witness_target(hasher, referee, roster, max_faults)
  let verified = bench_verified_referee_checkpoint(
    hasher, verifier, referee, target,
  )
  let required = @audit.replay_witness_quorum_size(witness_count, max_faults)
  let signed : Array[SignedAttestation] = []
  for index in 0..<witness_count {
    signed.push(
      sign_replay_witness_attestation(
        hasher,
        signers[index],
        target,
        roster[index].id,
        if index < required {
          Approve
        } else {
          Challenge
        },
      ),
    )
  }
  b.bench(fn() {
    let collector = match
      ReplayWitnessCollector::new(
        hasher,
        verifier,
        target,
        game_manifest_digest=@bft.Digest("pvp-bench-kernel-v1"),
        referee_key=referee.public_key(),
        witnesses=roster,
        max_faults~,
      ) {
      WitnessCollectorReady(value) => value
      _ => abort("benchmark replay witness collector rejected")
    }
    for item in signed {
      b.keep(collector.deliver(item))
    }
    b.keep(collector.certify(verified))
  })
}

///|
test "bench: certify 8 replay witnesses with f=2" (b : @bench.T) {
  bench_replay_witness_certificate(b, 8, 2)
}

///|
test "bench: certify 64 replay witnesses with f=21" (b : @bench.T) {
  bench_replay_witness_certificate(b, 64, 21)
}
