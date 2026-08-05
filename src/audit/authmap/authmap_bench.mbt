///|
fn benchmark_map(size : Int) -> AuthenticatedMap {
  let map = AuthenticatedMap::new(@bft.FnvHasher::new())
  for index in 0..<size {
    ignore(
      map.put("asset-" + index.to_string(), "owner-" + (index % 64).to_string()),
    )
  }
  map
}

///|
test "bench: authenticated map insert 10000" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  b.bench(fn() {
    let map = AuthenticatedMap::new(hasher)
    for index in 0..<10000 {
      ignore(map.put("asset-" + index.to_string(), "owner"))
    }
    b.keep(map.root())
  })
}

///|
test "bench: authenticated map update 1000 of 10000" (b : @bench.T) {
  let original = benchmark_map(10000)
  b.bench(fn() {
    let map = original.fork()
    for index in 0..<1000 {
      ignore(map.put("asset-" + index.to_string(), "new-owner"))
    }
    b.keep(map.root())
  })
}

///|
test "bench: verify 1000 membership proofs in 10000 entries" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let map = benchmark_map(10000)
  let proof = match map.proof("asset-7777") {
    Some(proof) => proof
    None => abort("benchmark map proof missing")
  }
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(verify_membership(hasher, map.root(), proof))
    }
  })
}

///|
test "bench: verify 1000 non-membership proofs in 10000 entries" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let map = benchmark_map(10000)
  let proof = match map.absence_proof("asset-missing") {
    Some(proof) => proof
    None => abort("benchmark map non-membership proof missing")
  }
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(verify_non_membership(hasher, map.root(), proof))
    }
  })
}
