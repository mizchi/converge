///|
test "replay witness manifest is roster-order independent and policy-bound" {
  let hasher = @bft.FnvHasher::new()
  let witnesses : Array[ReplayWitnessIdentity] = [
    { id: "alice", key: @bft.PublicKey("alice-key") },
    { id: "bob", key: @bft.PublicKey("bob-key") },
  ]
  let reverse = [witnesses[1], witnesses[0]]
  let left = replay_witness_session_manifest(
    hasher,
    game_manifest_digest=@bft.Digest("game-v1"),
    referee_key=@bft.PublicKey("referee"),
    witnesses~,
    max_faults=0,
  )
  assert_eq(
    left,
    replay_witness_session_manifest(
      hasher,
      game_manifest_digest=@bft.Digest("game-v1"),
      referee_key=@bft.PublicKey("referee"),
      witnesses=reverse,
      max_faults=0,
    ),
  )
  assert_not_eq(
    left,
    replay_witness_session_manifest(
      hasher,
      game_manifest_digest=@bft.Digest("game-v1"),
      referee_key=@bft.PublicKey("referee"),
      witnesses~,
      max_faults=1,
    ),
  )
}
