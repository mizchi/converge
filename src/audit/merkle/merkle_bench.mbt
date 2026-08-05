///|
fn benchmark_payloads(size : Int) -> Array[String] {
  let payloads : Array[String] = []
  for index in 0..<size {
    payloads.push("receipt-payload-" + index.to_string())
  }
  payloads
}

///|
test "bench: build 1000-leaf Merkle tree" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let payloads = benchmark_payloads(1000)
  b.bench(fn() { b.keep(MerkleTree::build(hasher, payloads)) })
}

///|
test "bench: verify 1000 proofs in a 1024-leaf tree" (b : @bench.T) {
  let hasher = @bft.FnvHasher::new()
  let payloads = benchmark_payloads(1024)
  let tree = MerkleTree::build(hasher, payloads)
  let proof = match tree.proof(777) {
    Some(proof) => proof
    None => abort("benchmark proof missing")
  }
  b.bench(fn() {
    for _ in 0..<1000 {
      b.keep(verify_inclusion(hasher, payloads[777], tree.root(), proof))
    }
  })
}
