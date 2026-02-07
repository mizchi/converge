///|
test "set and get" {
  let store = @ephemeral.EphemeralStore::new()
  let peer = @types.PeerId("alice")
  store.set("players", "p1", @types.Value::Str("hello"), 1.0, peer)
  let entry = store.get("players", "p1")
  inspect(not(entry is None), content="true")
  let e = entry.unwrap()
  inspect(e.value, content="Str(\"hello\")")
  inspect(e.timestamp, content="1")
  inspect(e.peer, content="PeerId(\"alice\")")
}

///|
test "get nonexistent returns None" {
  let store = @ephemeral.EphemeralStore::new()
  let entry = store.get("players", "p1")
  inspect(entry is None, content="true")
}

///|
test "get_all returns namespace entries" {
  let store = @ephemeral.EphemeralStore::new()
  let peer = @types.PeerId("alice")
  store.set("players", "p1", @types.Value::Int(10), 1.0, peer)
  store.set("players", "p2", @types.Value::Int(20), 2.0, peer)
  let all = store.get_all("players")
  inspect(all.length(), content="2")
}

///|
test "get_all empty namespace returns empty map" {
  let store = @ephemeral.EphemeralStore::new()
  let all = store.get_all("nonexistent")
  inspect(all.length(), content="0")
}

///|
test "merge: newer timestamp wins" {
  let store = @ephemeral.EphemeralStore::new()
  let alice = @types.PeerId("alice")
  let bob = @types.PeerId("bob")
  store.set("pos", "x", @types.Value::Int(10), 1.0, alice)
  let changed = store.merge("pos", "x", {
    value: @types.Value::Int(20),
    timestamp: 2.0,
    peer: bob,
  })
  inspect(changed, content="true")
  let e = store.get("pos", "x").unwrap()
  inspect(e.value, content="Int(20)")
  inspect(e.peer, content="PeerId(\"bob\")")
}

///|
test "merge: older timestamp loses" {
  let store = @ephemeral.EphemeralStore::new()
  let alice = @types.PeerId("alice")
  let bob = @types.PeerId("bob")
  store.set("pos", "x", @types.Value::Int(10), 5.0, alice)
  let changed = store.merge("pos", "x", {
    value: @types.Value::Int(20),
    timestamp: 3.0,
    peer: bob,
  })
  inspect(changed, content="false")
  let e = store.get("pos", "x").unwrap()
  inspect(e.value, content="Int(10)")
}

///|
test "merge: same timestamp, peer_id tiebreak (z > a wins)" {
  let store = @ephemeral.EphemeralStore::new()
  let peer_a = @types.PeerId("aaa")
  let peer_z = @types.PeerId("zzz")
  store.set("pos", "x", @types.Value::Int(10), 1.0, peer_a)
  let changed = store.merge("pos", "x", {
    value: @types.Value::Int(20),
    timestamp: 1.0,
    peer: peer_z,
  })
  inspect(changed, content="true")
  let e = store.get("pos", "x").unwrap()
  inspect(e.value, content="Int(20)")
  inspect(e.peer, content="PeerId(\"zzz\")")
}

///|
test "merge: same timestamp, peer_id tiebreak (a < z loses)" {
  let store = @ephemeral.EphemeralStore::new()
  let peer_z = @types.PeerId("zzz")
  let peer_a = @types.PeerId("aaa")
  store.set("pos", "x", @types.Value::Int(10), 1.0, peer_z)
  let changed = store.merge("pos", "x", {
    value: @types.Value::Int(20),
    timestamp: 1.0,
    peer: peer_a,
  })
  inspect(changed, content="false")
  let e = store.get("pos", "x").unwrap()
  inspect(e.value, content="Int(10)")
}

///|
test "merge into empty store" {
  let store = @ephemeral.EphemeralStore::new()
  let bob = @types.PeerId("bob")
  let changed = store.merge("pos", "x", {
    value: @types.Value::Int(42),
    timestamp: 1.0,
    peer: bob,
  })
  inspect(changed, content="true")
  let e = store.get("pos", "x").unwrap()
  inspect(e.value, content="Int(42)")
}

///|
test "remove entry" {
  let store = @ephemeral.EphemeralStore::new()
  let alice = @types.PeerId("alice")
  store.set("players", "p1", @types.Value::Str("alive"), 1.0, alice)
  store.remove("players", "p1")
  let entry = store.get("players", "p1")
  inspect(entry is None, content="true")
}

///|
test "remove from nonexistent namespace is no-op" {
  let store = @ephemeral.EphemeralStore::new()
  store.remove("nonexistent", "key") // should not panic
}

///|
test "overwrite with set" {
  let store = @ephemeral.EphemeralStore::new()
  let alice = @types.PeerId("alice")
  store.set("pos", "x", @types.Value::Int(10), 1.0, alice)
  store.set("pos", "x", @types.Value::Int(99), 2.0, alice)
  let e = store.get("pos", "x").unwrap()
  inspect(e.value, content="Int(99)")
  inspect(e.timestamp, content="2")
}
