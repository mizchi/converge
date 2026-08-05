///|
fn full_approvals(size : Int) -> FixedArray[Bool] {
  FixedArray::from_array(Array::make(size, true)[:])
}

///|
test "bench: checkpoint quorum 8 peers x 1000" (b : @bench.T) {
  let approvals = full_approvals(8)
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(
        decide_checkpoint(
          approvals,
          8,
          challenged=false,
          authority=AuthorityVerdict::Accept,
          replay_matches=false,
        ),
      )
    }
  })
}

///|
test "bench: checkpoint quorum 64 witnesses x 1000" (b : @bench.T) {
  let approvals = full_approvals(64)
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(
        decide_checkpoint(
          approvals,
          43,
          challenged=false,
          authority=AuthorityVerdict::Accept,
          replay_matches=false,
        ),
      )
    }
  })
}

///|
test "bench: authority replay 64 witnesses x 1000" (b : @bench.T) {
  let approvals = full_approvals(64)
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(
        decide_checkpoint(
          approvals,
          43,
          challenged=true,
          authority=AuthorityVerdict::Accept,
          replay_matches=true,
        ),
      )
    }
  })
}

///|
test "bench: market gate x 10000" (b : @bench.T) {
  b.bench(fn() {
    for _ in 0..<10000 {
      b.keep(
        market_accepts(
          CheckpointDecision::Finalized,
          item_included=true,
          rejected_ancestor=false,
        ),
      )
    }
  })
}
