// Topology simulation tests

///|
test "star: 5 peers converge after drain phase" {
  // ticks=50: first 25 writes, then 25 drain
  let config : @topology.SimConfig = {
    num_peers: 5,
    ticks: 50,
    ping_config: [{ ping_ms: 30, count: 5 }],
    write_interval: 1,
    namespaces: ["state"],
  }
  let result = @topology.run_star(config, 42)
  // Should have converged during drain phase
  inspect(result.convergence_tick >= 0, content="true")
  inspect(result.total_messages > 0, content="true")
  // Last tick should have 0 inconsistent pairs
  let last = result.per_tick[result.per_tick.length() - 1]
  inspect(last.inconsistent_pairs, content="0")
}

///|
test "star: 5 peers mixed latency converge" {
  let config : @topology.SimConfig = {
    num_peers: 5,
    ticks: 80,
    ping_config: [{ ping_ms: 30, count: 2 }, { ping_ms: 200, count: 3 }],
    write_interval: 1,
    namespaces: ["state"],
  }
  let result = @topology.run_star(config, 123)
  let last = result.per_tick[result.per_tick.length() - 1]
  inspect(last.inconsistent_pairs, content="0")
}

///|
test "gossip: 10 peers (fanout=3) converge after drain" {
  // ticks=100: first 50 writes, then 50 drain
  let config : @topology.GossipConfig = {
    base: {
      num_peers: 10,
      ticks: 100,
      ping_config: [{ ping_ms: 30, count: 10 }],
      write_interval: 1,
      namespaces: ["state"],
    },
    fanout: 3,
    max_hops: 3,
  }
  let result = @topology.run_gossip(config, 42)
  inspect(result.convergence_tick >= 0, content="true")
  inspect(result.total_messages > 0, content="true")
  let last = result.per_tick[result.per_tick.length() - 1]
  inspect(last.inconsistent_pairs, content="0")
}

///|
test "gossip vs star: both converge" {
  let star_config : @topology.SimConfig = {
    num_peers: 8,
    ticks: 60,
    ping_config: [{ ping_ms: 30, count: 8 }],
    write_interval: 3,
    namespaces: ["data"],
  }
  let gossip_config : @topology.GossipConfig = {
    base: {
      num_peers: 8,
      ticks: 60,
      ping_config: [{ ping_ms: 30, count: 8 }],
      write_interval: 3,
      namespaces: ["data"],
    },
    fanout: 3,
    max_hops: 3,
  }
  let star_result = @topology.run_star(star_config, 99)
  let gossip_result = @topology.run_gossip(gossip_config, 99)
  println(
    "star messages: \{star_result.total_messages}, gossip messages: \{gossip_result.total_messages}",
  )
  // Both should converge
  let star_last = star_result.per_tick[star_result.per_tick.length() - 1]
  let gossip_last = gossip_result.per_tick[gossip_result.per_tick.length() - 1]
  inspect(star_last.inconsistent_pairs, content="0")
  inspect(gossip_last.inconsistent_pairs, content="0")
}

///|
test "star: convergence report" {
  let config : @topology.SimConfig = {
    num_peers: 5,
    ticks: 60,
    ping_config: [{ ping_ms: 30, count: 3 }, { ping_ms: 200, count: 2 }],
    write_interval: 2,
    namespaces: ["pos", "hp"],
  }
  let result = @topology.run_star(config, 42)
  let buf = StringBuilder::new()
  buf.write_string("=== Star Relay Report ===\n")
  buf.write_string(
    "convergence_tick: \{result.convergence_tick}, total_messages: \{result.total_messages}\n",
  )
  // Show last 10 ticks
  let start = if result.per_tick.length() > 10 {
    result.per_tick.length() - 10
  } else {
    0
  }
  buf.write_string("tick | messages | inconsistent | entries\n")
  for i = start; i < result.per_tick.length(); i = i + 1 {
    let m = result.per_tick[i]
    buf.write_string(
      "\{m.tick}    | \{m.total_messages_sent}        | \{m.inconsistent_pairs}            | \{m.total_entries}\n",
    )
  }
  println(buf.to_string())
  inspect(result.total_messages > 0, content="true")
}
