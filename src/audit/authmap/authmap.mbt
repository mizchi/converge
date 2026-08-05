///|
pub enum AuthNode {
  Empty
  Branch(String, String, @bft.Digest, @bft.Digest, AuthNode, AuthNode)
}

///|
pub(all) enum AuthMapMutation {
  Inserted
  Updated
  Unchanged
} derive(Eq, Debug)

///|
/// A parent encountered while descending toward a membership proof target.
pub(all) enum AuthMapStep {
  DescendedLeft(String, String, @bft.Digest)
  DescendedRight(String, String, @bft.Digest)
} derive(Eq, Debug)

///|
pub(all) struct AuthMapProof {
  key : String
  value : String
  left_digest : @bft.Digest
  right_digest : @bft.Digest
  entry_count : Int
  path : Array[AuthMapStep]
} derive(Eq, Debug)

///|
/// Search path ending at an authenticated empty child for a missing key.
pub(all) struct AuthMapAbsenceProof {
  key : String
  entry_count : Int
  path : Array[AuthMapStep]
} derive(Eq, Debug)

///|
/// Deterministic authenticated treap. Key-derived priorities make the root
/// independent of insertion order while retaining expected logarithmic height.
pub struct AuthenticatedMap {
  hasher : &@bft.Hasher
  empty_digest : @bft.Digest
  mut root_node : AuthNode
  mut entry_count : Int
}

///|
fn append_field(buffer : StringBuilder, value : String) -> Unit {
  buffer.write_string(value.length().to_string())
  buffer.write_char(':')
  buffer.write_string(value)
}

///|
fn tagged_hash(
  hasher : &@bft.Hasher,
  tag : String,
  fields : Array[String],
) -> @bft.Digest {
  let buffer = StringBuilder::new()
  append_field(buffer, tag)
  for field in fields {
    append_field(buffer, field)
  }
  hasher.hash_string(buffer.to_string())
}

///|
fn key_priority(hasher : &@bft.Hasher, key : String) -> @bft.Digest {
  tagged_hash(hasher, "authmap-priority-v1", [key])
}

///|
fn AuthNode::digest(self : AuthNode, empty_digest : @bft.Digest) -> @bft.Digest {
  match self {
    Empty => empty_digest
    Branch(_, _, _, digest, _, _) => digest
  }
}

///|
fn make_branch(
  hasher : &@bft.Hasher,
  empty_digest : @bft.Digest,
  key : String,
  value : String,
  priority : @bft.Digest,
  left : AuthNode,
  right : AuthNode,
) -> AuthNode {
  let digest = tagged_hash(hasher, "authmap-node-v1", [
    key,
    value,
    left.digest(empty_digest).0,
    right.digest(empty_digest).0,
  ])
  Branch(key, value, priority, digest, left, right)
}

///|
fn priority_before(
  left_priority : @bft.Digest,
  left_key : String,
  right_priority : @bft.Digest,
  right_key : String,
) -> Bool {
  let order = left_priority.0.compare(right_priority.0)
  order < 0 || (order == 0 && left_key.compare(right_key) < 0)
}

///|
fn rotate_right(
  hasher : &@bft.Hasher,
  empty_digest : @bft.Digest,
  root : AuthNode,
) -> AuthNode {
  match root {
    Branch(
      key,
      value,
      priority,
      _,
      Branch(left_key, left_value, left_priority, _, left_left, left_right),
      right
    ) => {
      let moved = make_branch(
        hasher, empty_digest, key, value, priority, left_right, right,
      )
      make_branch(
        hasher, empty_digest, left_key, left_value, left_priority, left_left, moved,
      )
    }
    _ => root
  }
}

///|
fn rotate_left(
  hasher : &@bft.Hasher,
  empty_digest : @bft.Digest,
  root : AuthNode,
) -> AuthNode {
  match root {
    Branch(
      key,
      value,
      priority,
      _,
      left,
      Branch(right_key, right_value, right_priority, _, right_left, right_right)
    ) => {
      let moved = make_branch(
        hasher, empty_digest, key, value, priority, left, right_left,
      )
      make_branch(
        hasher, empty_digest, right_key, right_value, right_priority, moved, right_right,
      )
    }
    _ => root
  }
}

///|
fn put_node(
  hasher : &@bft.Hasher,
  empty_digest : @bft.Digest,
  node : AuthNode,
  key : String,
  value : String,
) -> (AuthNode, Bool, Bool) {
  match node {
    Empty =>
      (
        make_branch(
          hasher,
          empty_digest,
          key,
          value,
          key_priority(hasher, key),
          Empty,
          Empty,
        ),
        true,
        true,
      )
    Branch(node_key, node_value, priority, _, left, right) => {
      let order = key.compare(node_key)
      if order == 0 {
        if value == node_value {
          (
            make_branch(
              hasher, empty_digest, node_key, node_value, priority, left, right,
            ),
            false,
            false,
          )
        } else {
          (
            make_branch(
              hasher, empty_digest, node_key, value, priority, left, right,
            ),
            false,
            true,
          )
        }
      } else if order < 0 {
        let inserted = put_node(hasher, empty_digest, left, key, value)
        let rebuilt = make_branch(
          hasher,
          empty_digest,
          node_key,
          node_value,
          priority,
          inserted.0,
          right,
        )
        let result = match inserted.0 {
          Branch(child_key, _, child_priority, _, _, _) =>
            if priority_before(child_priority, child_key, priority, node_key) {
              rotate_right(hasher, empty_digest, rebuilt)
            } else {
              rebuilt
            }
          Empty => rebuilt
        }
        (result, inserted.1, inserted.2)
      } else {
        let inserted = put_node(hasher, empty_digest, right, key, value)
        let rebuilt = make_branch(
          hasher,
          empty_digest,
          node_key,
          node_value,
          priority,
          left,
          inserted.0,
        )
        let result = match inserted.0 {
          Branch(child_key, _, child_priority, _, _, _) =>
            if priority_before(child_priority, child_key, priority, node_key) {
              rotate_left(hasher, empty_digest, rebuilt)
            } else {
              rebuilt
            }
          Empty => rebuilt
        }
        (result, inserted.1, inserted.2)
      }
    }
  }
}

///|
fn merge_nodes(
  hasher : &@bft.Hasher,
  empty_digest : @bft.Digest,
  left : AuthNode,
  right : AuthNode,
) -> AuthNode {
  match (left, right) {
    (Empty, other) => other
    (other, Empty) => other
    (
      Branch(left_key, left_value, left_priority, _, left_left, left_right),
      Branch(right_key, right_value, right_priority, _, right_left, right_right),
    ) =>
      if priority_before(left_priority, left_key, right_priority, right_key) {
        make_branch(
          hasher,
          empty_digest,
          left_key,
          left_value,
          left_priority,
          left_left,
          merge_nodes(hasher, empty_digest, left_right, right),
        )
      } else {
        make_branch(
          hasher,
          empty_digest,
          right_key,
          right_value,
          right_priority,
          merge_nodes(hasher, empty_digest, left, right_left),
          right_right,
        )
      }
  }
}

///|
fn remove_node(
  hasher : &@bft.Hasher,
  empty_digest : @bft.Digest,
  node : AuthNode,
  key : String,
) -> (AuthNode, Bool) {
  match node {
    Empty => (Empty, false)
    Branch(node_key, node_value, priority, _, left, right) => {
      let order = key.compare(node_key)
      if order == 0 {
        (merge_nodes(hasher, empty_digest, left, right), true)
      } else if order < 0 {
        let removed = remove_node(hasher, empty_digest, left, key)
        (
          make_branch(
            hasher,
            empty_digest,
            node_key,
            node_value,
            priority,
            removed.0,
            right,
          ),
          removed.1,
        )
      } else {
        let removed = remove_node(hasher, empty_digest, right, key)
        (
          make_branch(
            hasher,
            empty_digest,
            node_key,
            node_value,
            priority,
            left,
            removed.0,
          ),
          removed.1,
        )
      }
    }
  }
}

///|
pub fn AuthenticatedMap::new(hasher : &@bft.Hasher) -> AuthenticatedMap {
  AuthenticatedMap::{
    hasher,
    empty_digest: tagged_hash(hasher, "authmap-empty-v1", []),
    root_node: Empty,
    entry_count: 0,
  }
}

///|
pub fn AuthenticatedMap::fork(self : AuthenticatedMap) -> AuthenticatedMap {
  AuthenticatedMap::{
    hasher: self.hasher,
    empty_digest: self.empty_digest,
    root_node: self.root_node,
    entry_count: self.entry_count,
  }
}

///|
pub fn AuthenticatedMap::put(
  self : AuthenticatedMap,
  key : String,
  value : String,
) -> AuthMapMutation {
  let changed = put_node(
    self.hasher,
    self.empty_digest,
    self.root_node,
    key,
    value,
  )
  self.root_node = changed.0
  if changed.1 {
    self.entry_count += 1
    Inserted
  } else if changed.2 {
    Updated
  } else {
    Unchanged
  }
}

///|
pub fn AuthenticatedMap::remove(self : AuthenticatedMap, key : String) -> Bool {
  let removed = remove_node(self.hasher, self.empty_digest, self.root_node, key)
  self.root_node = removed.0
  if removed.1 {
    self.entry_count -= 1
  }
  removed.1
}

///|
pub fn AuthenticatedMap::get(self : AuthenticatedMap, key : String) -> String? {
  let mut node = self.root_node
  while true {
    match node {
      Empty => return None
      Branch(node_key, value, _, _, left, right) => {
        let order = key.compare(node_key)
        if order == 0 {
          return Some(value)
        }
        node = if order < 0 { left } else { right }
      }
    }
  }
  None
}

///|
fn map_root(
  hasher : &@bft.Hasher,
  entry_count : Int,
  node_digest : @bft.Digest,
) -> @bft.Digest {
  tagged_hash(hasher, "authmap-root-v1", [
    entry_count.to_string(),
    node_digest.0,
  ])
}

///|
pub fn AuthenticatedMap::root(self : AuthenticatedMap) -> @bft.Digest {
  map_root(
    self.hasher,
    self.entry_count,
    self.root_node.digest(self.empty_digest),
  )
}

///|
pub fn AuthenticatedMap::size(self : AuthenticatedMap) -> Int {
  self.entry_count
}

///|
fn collect_proof(
  node : AuthNode,
  empty_digest : @bft.Digest,
  key : String,
  entry_count : Int,
  path : Array[AuthMapStep],
) -> AuthMapProof? {
  match node {
    Empty => None
    Branch(node_key, value, _, _, left, right) => {
      let order = key.compare(node_key)
      if order == 0 {
        Some(AuthMapProof::{
          key: node_key,
          value,
          left_digest: left.digest(empty_digest),
          right_digest: right.digest(empty_digest),
          entry_count,
          path,
        })
      } else if order < 0 {
        path.push(DescendedLeft(node_key, value, right.digest(empty_digest)))
        collect_proof(left, empty_digest, key, entry_count, path)
      } else {
        path.push(DescendedRight(node_key, value, left.digest(empty_digest)))
        collect_proof(right, empty_digest, key, entry_count, path)
      }
    }
  }
}

///|
pub fn AuthenticatedMap::proof(
  self : AuthenticatedMap,
  key : String,
) -> AuthMapProof? {
  collect_proof(self.root_node, self.empty_digest, key, self.entry_count, [])
}

///|
fn collect_absence_proof(
  node : AuthNode,
  empty_digest : @bft.Digest,
  key : String,
  entry_count : Int,
  path : Array[AuthMapStep],
) -> AuthMapAbsenceProof? {
  match node {
    Empty => Some(AuthMapAbsenceProof::{ key, entry_count, path })
    Branch(node_key, value, _, _, left, right) => {
      let order = key.compare(node_key)
      if order == 0 {
        None
      } else if order < 0 {
        path.push(DescendedLeft(node_key, value, right.digest(empty_digest)))
        collect_absence_proof(left, empty_digest, key, entry_count, path)
      } else {
        path.push(DescendedRight(node_key, value, left.digest(empty_digest)))
        collect_absence_proof(right, empty_digest, key, entry_count, path)
      }
    }
  }
}

///|
/// Produce a proof only when the searched key reaches an empty child.
pub fn AuthenticatedMap::absence_proof(
  self : AuthenticatedMap,
  key : String,
) -> AuthMapAbsenceProof? {
  collect_absence_proof(
    self.root_node,
    self.empty_digest,
    key,
    self.entry_count,
    [],
  )
}

///|
/// Verify an authenticated-map membership proof in expected O(log n).
pub fn verify_membership(
  hasher : &@bft.Hasher,
  expected_root : @bft.Digest,
  proof : AuthMapProof,
) -> Bool {
  if proof.entry_count <= 0 {
    return false
  }
  let mut current = tagged_hash(hasher, "authmap-node-v1", [
    proof.key,
    proof.value,
    proof.left_digest.0,
    proof.right_digest.0,
  ])
  let mut index = proof.path.length() - 1
  while index >= 0 {
    match proof.path[index] {
      DescendedLeft(parent_key, parent_value, right_sibling) => {
        if proof.key.compare(parent_key) >= 0 {
          return false
        }
        current = tagged_hash(hasher, "authmap-node-v1", [
          parent_key,
          parent_value,
          current.0,
          right_sibling.0,
        ])
      }
      DescendedRight(parent_key, parent_value, left_sibling) => {
        if proof.key.compare(parent_key) <= 0 {
          return false
        }
        current = tagged_hash(hasher, "authmap-node-v1", [
          parent_key,
          parent_value,
          left_sibling.0,
          current.0,
        ])
      }
    }
    index -= 1
  }
  map_root(hasher, proof.entry_count, current) == expected_root
}

///|
/// Verify that an ordered search for `proof.key` ends at an authenticated
/// empty child under the expected root.
pub fn verify_non_membership(
  hasher : &@bft.Hasher,
  expected_root : @bft.Digest,
  proof : AuthMapAbsenceProof,
) -> Bool {
  if proof.entry_count < 0 ||
    (proof.entry_count == 0 && proof.path.length() != 0) ||
    (proof.entry_count > 0 && proof.path.length() == 0) {
    return false
  }
  let empty_digest = tagged_hash(hasher, "authmap-empty-v1", [])
  let mut current = empty_digest
  let mut index = proof.path.length() - 1
  while index >= 0 {
    match proof.path[index] {
      DescendedLeft(parent_key, parent_value, right_sibling) => {
        if proof.key.compare(parent_key) >= 0 {
          return false
        }
        current = tagged_hash(hasher, "authmap-node-v1", [
          parent_key,
          parent_value,
          current.0,
          right_sibling.0,
        ])
      }
      DescendedRight(parent_key, parent_value, left_sibling) => {
        if proof.key.compare(parent_key) <= 0 {
          return false
        }
        current = tagged_hash(hasher, "authmap-node-v1", [
          parent_key,
          parent_value,
          left_sibling.0,
          current.0,
        ])
      }
    }
    index -= 1
  }
  map_root(hasher, proof.entry_count, current) == expected_root
}
