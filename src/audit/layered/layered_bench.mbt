///|
fn benchmark_policy() -> @audit.VerifiedCheckpointPolicy {
  match
    @audit.open_checkpoint_policy({
      event_interval_ms: 1,
      micro_checkpoint_interval_ms: 1000,
      macro_checkpoint_interval_ms: 15000,
      event_retention_ms: 30000,
      micro_checkpoint_retention_ms: 120000,
      macro_checkpoint_retention_ms: 600000,
    }) {
    @audit.CheckpointPolicyOpenResult::Opened(policy) => policy
    @audit.CheckpointPolicyOpenResult::Refused(_) =>
      abort("benchmark policy must be valid")
  }
}

///|
fn benchmark_builder() -> LayeredCheckpointBuilder {
  match
    LayeredCheckpointBuilder::open(
      @bft.FnvHasher::new(),
      benchmark_policy(),
      scope_id="benchmark",
      origin_ms=0,
      previous_macro_digest=@bft.Digest("genesis"),
      max_pending_events=1000,
    ) {
    LayeredBuilderReady(builder) => builder
    LayeredBuilderRefused(_) => abort("benchmark builder must open")
  }
}

///|
fn append_benchmark_events(builder : LayeredCheckpointBuilder) -> Unit {
  for index in 0..<1000 {
    ignore(builder.append_event(index * 15, "event-" + index.to_string()))
  }
}

///|
test "bench: seal 1000 events into one micro checkpoint" (b : @bench.T) {
  b.bench(fn() {
    let builder = benchmark_builder()
    for index in 0..<1000 {
      ignore(builder.append_event(index, "event-" + index.to_string()))
    }
    match builder.advance_watermark(1000, max_windows=1) {
      WatermarkAdvanced(emission) =>
        b.keep(emission.micro_checkpoints()[0].checkpoint().digest)
      WatermarkRefused(_) => abort("benchmark watermark must advance")
    }
  })
}

///|
test "bench: seal 1000 events through 15 micro windows into one macro" (
  b : @bench.T,
) {
  b.bench(fn() {
    let builder = benchmark_builder()
    append_benchmark_events(builder)
    match builder.advance_watermark(15000, max_windows=15) {
      WatermarkAdvanced(emission) =>
        b.keep(emission.macro_checkpoints()[0].checkpoint().digest)
      WatermarkRefused(_) => abort("benchmark watermark must advance")
    }
  })
}
