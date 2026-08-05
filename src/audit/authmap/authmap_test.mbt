///|
fn map_with(entries : Array[(String, String)]) -> AuthenticatedMap {
  let map = AuthenticatedMap::new(@bft.FnvHasher::new())
  for entry in entries {
    ignore(map.put(entry.0, entry.1))
  }
  map
}

///|
fn proof_or_fail(
  map : AuthenticatedMap,
  key : String,
) -> AuthMapProof raise Error {
  match map.proof(key) {
    Some(proof) => proof
    None => fail("expected authenticated-map proof")
  }
}

///|
test "same entries converge to one root regardless of insertion order" {
  let left = map_with([("a", "1"), ("b", "2"), ("c", "3"), ("d", "4")])
  let right = map_with([("d", "4"), ("b", "2"), ("a", "1"), ("c", "3")])
  assert_eq(left.root(), right.root())
  assert_eq(left.size(), 4)
  assert_eq(right.get("c"), Some("3"))
}

///|
test "insert update unchanged and remove have explicit outcomes" {
  let empty = AuthenticatedMap::new(@bft.FnvHasher::new())
  let empty_root = empty.root()
  assert_eq(empty.put("asset", "alice"), AuthMapMutation::Inserted)
  assert_eq(empty.put("asset", "alice"), AuthMapMutation::Unchanged)
  assert_eq(empty.put("asset", "bob"), AuthMapMutation::Updated)
  assert_eq(empty.get("asset"), Some("bob"))
  assert_true(empty.remove("asset"))
  assert_false(empty.remove("asset"))
  assert_eq(empty.size(), 0)
  assert_eq(empty.root(), empty_root)
}

///|
test "membership proofs verify for every key" {
  let hasher = @bft.FnvHasher::new()
  let entries = [
    ("asset-a", "alice"),
    ("asset-b", "bob"),
    ("asset-c", "carol"),
    ("asset-d", "dave"),
    ("asset-e", "eve"),
  ]
  let map = map_with(entries)
  for entry in entries {
    assert_true(
      verify_membership(hasher, map.root(), proof_or_fail(map, entry.0)),
    )
  }
  assert_eq(map.proof("missing"), None)
}

///|
test "proof key value root sibling and count tampering are rejected" {
  let hasher = @bft.FnvHasher::new()
  let map = map_with([("a", "1"), ("b", "2"), ("c", "3"), ("d", "4")])
  let proof = proof_or_fail(map, "c")
  assert_false(verify_membership(hasher, map.root(), { ..proof, key: "other" }))
  assert_false(
    verify_membership(hasher, map.root(), { ..proof, value: "tampered" }),
  )
  assert_false(verify_membership(hasher, @bft.Digest("other-root"), proof))
  assert_false(
    verify_membership(hasher, map.root(), {
      ..proof,
      entry_count: proof.entry_count + 1,
    }),
  )
  let mut checked_path_tamper = false
  for key in ["a", "b", "c", "d"] {
    let candidate = proof_or_fail(map, key)
    if !checked_path_tamper && candidate.path.length() > 0 {
      let changed = candidate.path.copy()
      changed[0] = match changed[0] {
        DescendedLeft(parent_key, parent_value, _) =>
          AuthMapStep::DescendedRight(
            parent_key,
            parent_value,
            @bft.Digest("fake-sibling"),
          )
        DescendedRight(parent_key, parent_value, _) =>
          AuthMapStep::DescendedLeft(
            parent_key,
            parent_value,
            @bft.Digest("fake-sibling"),
          )
      }
      assert_false(
        verify_membership(hasher, map.root(), { ..candidate, path: changed }),
      )
      checked_path_tamper = true
    }
  }
  assert_true(checked_path_tamper)
}

///|
test "larger forward reverse and shuffled builds converge" {
  let forward : Array[(String, String)] = []
  let reverse : Array[(String, String)] = []
  let shuffled : Array[(String, String)] = []
  for index in 0..<100 {
    forward.push(("key-" + index.to_string(), "value-" + index.to_string()))
    let reversed = 99 - index
    reverse.push(
      ("key-" + reversed.to_string(), "value-" + reversed.to_string()),
    )
  }
  for offset in 0..<10 {
    for index in 0..<10 {
      let shuffled_index = index * 10 + offset
      shuffled.push(
        (
          "key-" + shuffled_index.to_string(),
          "value-" + shuffled_index.to_string(),
        ),
      )
    }
  }
  assert_eq(map_with(forward).root(), map_with(reverse).root())
  assert_eq(map_with(forward).root(), map_with(shuffled).root())
}

///|
test "forked maps isolate later mutations" {
  let original = map_with([("asset-a", "alice")])
  let forked = original.fork()
  ignore(forked.put("asset-b", "bob"))
  ignore(forked.put("asset-a", "carol"))
  assert_eq(original.size(), 1)
  assert_eq(original.get("asset-a"), Some("alice"))
  assert_eq(original.get("asset-b"), None)
  assert_not_eq(original.root(), forked.root())
}

///|
fn absence_proof_or_fail(
  map : AuthenticatedMap,
  key : String,
) -> AuthMapAbsenceProof raise Error {
  match map.absence_proof(key) {
    Some(proof) => proof
    None => fail("expected authenticated-map non-membership proof")
  }
}

///|
test "non-membership proofs verify for empty and populated maps" {
  let hasher = @bft.FnvHasher::new()
  let empty = AuthenticatedMap::new(hasher)
  assert_true(
    verify_non_membership(
      hasher,
      empty.root(),
      absence_proof_or_fail(empty, "missing"),
    ),
  )
  let populated = map_with([("a", "1"), ("c", "3"), ("e", "5"), ("g", "7")])
  for missing in ["0", "b", "d", "f", "z"] {
    assert_true(
      verify_non_membership(
        hasher,
        populated.root(),
        absence_proof_or_fail(populated, missing),
      ),
    )
  }
  assert_eq(populated.absence_proof("c"), None)
}

///|
test "non-membership proof root key count and path tampering are rejected" {
  let hasher = @bft.FnvHasher::new()
  let map = map_with([("a", "1"), ("c", "3"), ("e", "5"), ("g", "7")])
  let proof = absence_proof_or_fail(map, "d")
  assert_false(verify_non_membership(hasher, @bft.Digest("wrong-root"), proof))
  assert_false(verify_non_membership(hasher, map.root(), { ..proof, key: "c" }))
  assert_false(
    verify_non_membership(hasher, map.root(), {
      ..proof,
      entry_count: proof.entry_count + 1,
    }),
  )
  let shortened = proof.path.copy()
  ignore(shortened.pop())
  assert_false(
    verify_non_membership(hasher, map.root(), { ..proof, path: shortened }),
  )
}
