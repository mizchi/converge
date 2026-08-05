///|
/// One authenticated sibling in a Merkle inclusion path.
pub(all) enum MerkleStep {
  SiblingLeft(@bft.Digest)
  SiblingRight(@bft.Digest)
} derive(Eq, Debug)

///|
/// Inclusion path plus the position and total leaf count bound by the root.
pub(all) struct MerkleProof {
  leaf_index : Int
  leaf_count : Int
  path : Array[MerkleStep]
} derive(Eq, Debug)

///|
/// Game-neutral immutable Merkle tree. Payloads are represented only by their
/// leaf digests.
pub struct MerkleTree {
  leaf_hashes : Array[@bft.Digest]
  levels : Array[Array[@bft.Digest]]
  root_digest : @bft.Digest
}

///|
fn append_field(buffer : StringBuilder, value : String) -> Unit {
  buffer.write_string(value.length().to_string())
  buffer.write_char(':')
  buffer.write_string(value)
}

///|
fn hash_leaf(hasher : &@bft.Hasher, payload : String) -> @bft.Digest {
  let buffer = StringBuilder::new()
  append_field(buffer, "merkle-leaf-v1")
  append_field(buffer, payload)
  hasher.hash_string(buffer.to_string())
}

///|
fn hash_node(
  hasher : &@bft.Hasher,
  left : @bft.Digest,
  right : @bft.Digest,
) -> @bft.Digest {
  let buffer = StringBuilder::new()
  append_field(buffer, "merkle-node-v1")
  append_field(buffer, left.0)
  append_field(buffer, right.0)
  hasher.hash_string(buffer.to_string())
}

///|
fn hash_empty(hasher : &@bft.Hasher) -> @bft.Digest {
  let buffer = StringBuilder::new()
  append_field(buffer, "merkle-empty-v1")
  hasher.hash_string(buffer.to_string())
}

///|
fn hash_root(
  hasher : &@bft.Hasher,
  leaf_count : Int,
  content_root : @bft.Digest,
) -> @bft.Digest {
  let buffer = StringBuilder::new()
  append_field(buffer, "merkle-root-v1")
  append_field(buffer, leaf_count.to_string())
  append_field(buffer, content_root.0)
  hasher.hash_string(buffer.to_string())
}

///|
/// Build a tree in O(n). An odd last node is paired with itself.
pub fn MerkleTree::build(
  hasher : &@bft.Hasher,
  payloads : Array[String],
) -> MerkleTree {
  let leaf_hashes : Array[@bft.Digest] = []
  for payload in payloads {
    leaf_hashes.push(hash_leaf(hasher, payload))
  }
  let levels : Array[Array[@bft.Digest]] = []
  let content_root = if leaf_hashes.length() == 0 {
    hash_empty(hasher)
  } else {
    let mut current = leaf_hashes.copy()
    levels.push(current.copy())
    while current.length() > 1 {
      let next : Array[@bft.Digest] = []
      let mut index = 0
      while index < current.length() {
        let left = current[index]
        let right = if index + 1 < current.length() {
          current[index + 1]
        } else {
          left
        }
        next.push(hash_node(hasher, left, right))
        index += 2
      }
      current = next
      levels.push(current.copy())
    }
    current[0]
  }
  MerkleTree::{
    leaf_hashes,
    levels,
    root_digest: hash_root(hasher, payloads.length(), content_root),
  }
}

///|
pub fn MerkleTree::root(self : MerkleTree) -> @bft.Digest {
  self.root_digest
}

///|
pub fn MerkleTree::leaf_count(self : MerkleTree) -> Int {
  self.leaf_hashes.length()
}

///|
/// Produce an O(log n) proof for a valid leaf index.
pub fn MerkleTree::proof(self : MerkleTree, leaf_index : Int) -> MerkleProof? {
  if leaf_index < 0 || leaf_index >= self.leaf_hashes.length() {
    return None
  }
  let path : Array[MerkleStep] = []
  let mut index = leaf_index
  for level_index in 0..<(self.levels.length() - 1) {
    let level = self.levels[level_index]
    if index % 2 == 0 {
      let sibling = if index + 1 < level.length() {
        level[index + 1]
      } else {
        level[index]
      }
      path.push(SiblingRight(sibling))
    } else {
      path.push(SiblingLeft(level[index - 1]))
    }
    index /= 2
  }
  Some(MerkleProof::{ leaf_index, leaf_count: self.leaf_hashes.length(), path })
}

///|
/// Verify a proof in O(log n), rejecting malformed path shapes and counts.
pub fn verify_inclusion(
  hasher : &@bft.Hasher,
  payload : String,
  expected_root : @bft.Digest,
  proof : MerkleProof,
) -> Bool {
  if proof.leaf_count <= 0 ||
    proof.leaf_index < 0 ||
    proof.leaf_index >= proof.leaf_count {
    return false
  }
  let mut current = hash_leaf(hasher, payload)
  let mut index = proof.leaf_index
  let mut node_count = proof.leaf_count
  for step in proof.path {
    if node_count <= 1 {
      return false
    }
    if index % 2 == 0 {
      match step {
        SiblingLeft(_) => return false
        SiblingRight(sibling) => {
          if index + 1 >= node_count && sibling != current {
            return false
          }
          current = hash_node(hasher, current, sibling)
        }
      }
    } else {
      match step {
        SiblingRight(_) => return false
        SiblingLeft(sibling) => current = hash_node(hasher, sibling, current)
      }
    }
    index /= 2
    node_count = (node_count + 1) / 2
  }
  if node_count != 1 || index != 0 {
    return false
  }
  hash_root(hasher, proof.leaf_count, current) == expected_root
}
