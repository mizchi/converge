///|
/// 10000 sequential sets in the same namespace
test "bench: EphemeralStore 10000 sets" (b : @bench.T) {
  b.bench(fn() {
    let store = EphemeralStore::new()
    let peer = @types.PeerId("alice")
    for i in 0..<10000 {
      store.set("pos", "key\{i}", @types.Value::Int(i), i.to_double(), peer)
    }
    b.keep(store)
  })
}

///|
/// 10000 overwrites on the same key
test "bench: EphemeralStore 10000 overwrites same key" (b : @bench.T) {
  b.bench(fn() {
    let store = EphemeralStore::new()
    let peer = @types.PeerId("alice")
    for i in 0..<10000 {
      store.set("pos", "x", @types.Value::Int(i), i.to_double(), peer)
    }
    b.keep(store)
  })
}

///|
/// 10000 LWW merges (all winning — ascending timestamps)
test "bench: EphemeralStore 10000 merges winning" (b : @bench.T) {
  b.bench(fn() {
    let store = EphemeralStore::new()
    let peer = @types.PeerId("alice")
    for i in 0..<10000 {
      let entry : EphemeralEntry = {
        value: @types.Value::Int(i),
        timestamp: i.to_double(),
        peer,
      }
      ignore(store.merge("pos", "x", entry))
    }
    b.keep(store)
  })
}

///|
/// 10000 LWW merges (all losing — descending timestamps)
test "bench: EphemeralStore 10000 merges losing" (b : @bench.T) {
  let store = EphemeralStore::new()
  let peer = @types.PeerId("alice")
  store.set("pos", "x", @types.Value::Int(0), 99999.0, peer)
  let loser = @types.PeerId("bob")
  b.bench(fn() {
    for i in 0..<10000 {
      let entry : EphemeralEntry = {
        value: @types.Value::Int(i),
        timestamp: i.to_double(),
        peer: loser,
      }
      ignore(store.merge("pos", "x", entry))
    }
    b.keep(store)
  })
}

///|
/// get_all with 1000 entries in namespace
test "bench: EphemeralStore get_all 1000 entries" (b : @bench.T) {
  let store = EphemeralStore::new()
  let peer = @types.PeerId("alice")
  for i in 0..<1000 {
    store.set("players", "p\{i}", @types.Value::Int(i), i.to_double(), peer)
  }
  b.bench(fn() { b.keep(store.get_all("players")) })
}

///|
/// Multi-peer merge simulation: 100 peers x 10 keys each
test "bench: EphemeralStore multi-peer merge 100x10" (b : @bench.T) {
  b.bench(fn() {
    let store = EphemeralStore::new()
    for p in 0..<100 {
      let peer = @types.PeerId("peer\{p}")
      for k in 0..<10 {
        let entry : EphemeralEntry = {
          value: @types.Value::Int(p * 10 + k),
          timestamp: (p * 10 + k).to_double(),
          peer,
        }
        ignore(store.merge("game", "obj\{k}", entry))
      }
    }
    b.keep(store)
  })
}
