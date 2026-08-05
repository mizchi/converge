///|
fn proof_or_fail(tree : MerkleTree, index : Int) -> MerkleProof raise Error {
  match tree.proof(index) {
    Some(proof) => proof
    None => fail("expected Merkle proof")
  }
}

///|
test "proofs verify for every leaf in an odd-sized tree" {
  let hasher = @bft.FnvHasher::new()
  let payloads = ["alpha", "beta", "gamma"]
  let tree = MerkleTree::build(hasher, payloads)
  for index, payload in payloads {
    assert_true(
      verify_inclusion(hasher, payload, tree.root(), proof_or_fail(tree, index)),
    )
  }
}

///|
test "single leaf verifies and empty tree has no inclusion proof" {
  let hasher = @bft.FnvHasher::new()
  let single = MerkleTree::build(hasher, ["only"])
  assert_true(
    verify_inclusion(hasher, "only", single.root(), proof_or_fail(single, 0)),
  )
  let empty = MerkleTree::build(hasher, [])
  assert_eq(empty.leaf_count(), 0)
  assert_eq(empty.proof(0), None)
  assert_not_eq(empty.root(), single.root())
}

///|
test "payload tampering and another root are rejected" {
  let hasher = @bft.FnvHasher::new()
  let tree = MerkleTree::build(hasher, ["alpha", "beta", "gamma"])
  let proof = proof_or_fail(tree, 1)
  assert_false(verify_inclusion(hasher, "tampered", tree.root(), proof))
  let other = MerkleTree::build(hasher, ["alpha", "beta", "other"])
  assert_false(verify_inclusion(hasher, "beta", other.root(), proof))
}

///|
test "proof direction, sibling, and leaf index are authenticated" {
  let hasher = @bft.FnvHasher::new()
  let tree = MerkleTree::build(hasher, ["alpha", "beta", "gamma"])
  let proof = proof_or_fail(tree, 0)
  let reversed_steps = proof.path.copy()
  reversed_steps[0] = match reversed_steps[0] {
    SiblingRight(digest) => MerkleStep::SiblingLeft(digest)
    SiblingLeft(digest) => MerkleStep::SiblingRight(digest)
  }
  let reversed : MerkleProof = { ..proof, path: reversed_steps }
  assert_false(verify_inclusion(hasher, "alpha", tree.root(), reversed))
  let wrong_index : MerkleProof = { ..proof, leaf_index: 1 }
  assert_false(verify_inclusion(hasher, "alpha", tree.root(), wrong_index))
  let odd_proof = proof_or_fail(tree, 2)
  let wrong_sibling_steps = odd_proof.path.copy()
  wrong_sibling_steps[0] = MerkleStep::SiblingRight(@bft.Digest("fake"))
  let wrong_sibling : MerkleProof = { ..odd_proof, path: wrong_sibling_steps }
  assert_false(verify_inclusion(hasher, "gamma", tree.root(), wrong_sibling))
}

///|
test "short, extra, and wrong-count proofs are rejected" {
  let hasher = @bft.FnvHasher::new()
  let tree = MerkleTree::build(hasher, ["a", "b", "c", "d"])
  let proof = proof_or_fail(tree, 2)
  let short_path : Array[MerkleStep] = []
  short_path.push(proof.path[0])
  let short : MerkleProof = { ..proof, path: short_path }
  assert_false(verify_inclusion(hasher, "c", tree.root(), short))
  let extra_path = proof.path.copy()
  extra_path.push(MerkleStep::SiblingRight(@bft.Digest("extra")))
  let extra : MerkleProof = { ..proof, path: extra_path }
  assert_false(verify_inclusion(hasher, "c", tree.root(), extra))
  let wrong_count : MerkleProof = { ..proof, leaf_count: 3 }
  assert_false(verify_inclusion(hasher, "c", tree.root(), wrong_count))
}

///|
test "leaf order and leaf count are bound into the root" {
  let hasher = @bft.FnvHasher::new()
  let left = MerkleTree::build(hasher, ["a", "b", "c"])
  let reordered = MerkleTree::build(hasher, ["b", "a", "c"])
  let extended = MerkleTree::build(hasher, ["a", "b", "c", "c"])
  assert_not_eq(left.root(), reordered.root())
  assert_not_eq(left.root(), extended.root())
}

///|
test "all proof positions verify across power-of-two boundaries" {
  let hasher = @bft.FnvHasher::new()
  for size in 1..<=33 {
    let payloads : Array[String] = []
    for index in 0..<size {
      payloads.push("leaf-" + index.to_string())
    }
    let tree = MerkleTree::build(hasher, payloads)
    for index, payload in payloads {
      assert_true(
        verify_inclusion(
          hasher,
          payload,
          tree.root(),
          proof_or_fail(tree, index),
        ),
      )
    }
  }
}
