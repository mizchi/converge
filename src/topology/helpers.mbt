// Helper functions for topology simulations

///|
/// Collect all entries from an EphemeralStore for given namespaces.
pub fn collect_entries(
  store : @ephemeral.EphemeralStore,
  namespaces : Array[String]
) -> Array[(String, String, @ephemeral.EphemeralEntry)] {
  let result : Array[(String, String, @ephemeral.EphemeralEntry)] = []
  for ns in namespaces {
    let entries = store.get_all(ns)
    for key, entry in entries {
      result.push((ns, key, entry))
    }
  }
  result
}

///|
/// Pick `count` random distinct indices from 0..<total, excluding `exclude`.
pub fn pick_random_targets(
  rng : Rng,
  total : Int,
  exclude : Int,
  count : Int
) -> Array[Int] {
  let targets : Array[Int] = []
  // Build candidate list
  let candidates : Array[Int] = []
  for i in 0..<total {
    if i != exclude {
      candidates.push(i)
    }
  }
  // Fisher-Yates partial shuffle
  let n = candidates.length()
  let pick = if count < n { count } else { n }
  for i in 0..<pick {
    let j = i + rng.next_bound(n - i)
    // swap
    let tmp = candidates[i]
    candidates[i] = candidates[j]
    candidates[j] = tmp
    targets.push(candidates[i])
  }
  targets
}

///|
/// Count pairs of peers with inconsistent state.
/// Two peers are inconsistent if any (ns, key) entry differs.
pub fn count_inconsistent_pairs(
  nodes : Array[SimNode],
  namespaces : Array[String]
) -> Int {
  let n = nodes.length()
  let mut inconsistent = 0
  for i in 0..<n {
    for j = i + 1; j < n; j = j + 1 {
      let mut found_diff = false
      for ns in namespaces {
        if found_diff {
          break
        }
        let entries_i = nodes[i].store.get_all(ns)
        let entries_j = nodes[j].store.get_all(ns)
        // Check all keys in i
        for key, ei in entries_i {
          match entries_j.get(key) {
            Some(ej) =>
              if ei.value != ej.value || ei.timestamp != ej.timestamp {
                found_diff = true
              }
            None => found_diff = true
          }
          if found_diff {
            break
          }
        }
        if not(found_diff) {
          // Check keys in j not in i
          for key, _ej in entries_j {
            match entries_i.get(key) {
              Some(_) => () // already checked
              None => found_diff = true
            }
            if found_diff {
              break
            }
          }
        }
      }
      if found_diff {
        inconsistent += 1
      }
    }
  }
  inconsistent
}

///|
/// Count total entries across all nodes
pub fn count_total_entries(
  nodes : Array[SimNode],
  namespaces : Array[String]
) -> Int {
  let mut total = 0
  for node in nodes {
    for ns in namespaces {
      let entries = node.store.get_all(ns)
      for _key, _entry in entries {
        total += 1
      }
    }
  }
  total
}
