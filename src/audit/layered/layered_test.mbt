///|
fn test_policy() -> @audit.VerifiedCheckpointPolicy {
  match
    @audit.open_checkpoint_policy({
      event_interval_ms: 10,
      micro_checkpoint_interval_ms: 100,
      macro_checkpoint_interval_ms: 250,
      event_retention_ms: 1000,
      micro_checkpoint_retention_ms: 2000,
      macro_checkpoint_retention_ms: 4000,
    }) {
    @audit.CheckpointPolicyOpenResult::Opened(policy) => policy
    @audit.CheckpointPolicyOpenResult::Refused(_) =>
      abort("test policy must be valid")
  }
}

///|
fn test_builder(max_pending_events? : Int = 16) -> LayeredCheckpointBuilder {
  match
    LayeredCheckpointBuilder::open(
      @bft.FnvHasher::new(),
      test_policy(),
      scope_id="scope-a",
      origin_ms=0,
      previous_macro_digest=@bft.Digest("genesis"),
      max_pending_events~,
    ) {
    LayeredBuilderReady(builder) => builder
    LayeredBuilderRefused(_) => abort("test builder must open")
  }
}

///|
fn refused(result : AdvanceWatermarkResult) -> AdvanceWatermarkError {
  match result {
    WatermarkRefused(error) => error
    WatermarkAdvanced(_) => abort("watermark must be refused")
  }
}

///|
fn open_refusal(result : LayeredBuilderOpenResult) -> LayeredBuilderOpenError {
  match result {
    LayeredBuilderRefused(error) => error
    LayeredBuilderReady(_) => abort("builder must be refused")
  }
}

///|
fn advanced(result : AdvanceWatermarkResult) -> LayeredCheckpointEmission {
  match result {
    WatermarkAdvanced(emission) => emission
    WatermarkRefused(_) => abort("watermark must advance")
  }
}

///|
test "layered checkpoint root ignores arrival order and exact retries" {
  let first = test_builder()
  assert_eq(first.append_event(90, "event-b"), AuditEventAppended)
  assert_eq(first.append_event(10, "event-a"), AuditEventAppended)
  assert_eq(first.append_event(10, "event-a"), AuditEventDuplicate)
  let first_emission = advanced(first.advance_watermark(100, max_windows=1))
  let first_micros = first_emission.micro_checkpoints()
  assert_eq(first_micros.length(), 1)
  let first_sealed = first_micros[0]
  debug_inspect(
    first_sealed.checkpoint(),
    content=(
      #|{
      #|  scope_id: "scope-a",
      #|  macro_epoch: 0,
      #|  micro_index: 0,
      #|  starts_at_ms: 0,
      #|  ends_at_ms: 100,
      #|  event_count: 2,
      #|  event_root: Digest("3582862e"),
      #|  digest: Digest("7c03b489"),
      #|}
    ),
  )

  let second = test_builder()
  assert_eq(second.append_event(10, "event-a"), AuditEventAppended)
  assert_eq(second.append_event(90, "event-b"), AuditEventAppended)
  let second_sealed = advanced(second.advance_watermark(100, max_windows=1)).micro_checkpoints()[0]
  assert_eq(
    first_sealed.checkpoint().event_root,
    second_sealed.checkpoint().event_root,
  )
  assert_eq(first_sealed.checkpoint().digest, second_sealed.checkpoint().digest)

  let proof = match first_sealed.event_proof("event-a") {
    Some(proof) => proof
    None => abort("event proof must exist")
  }
  assert_true(
    verify_micro_checkpoint_event(
      @bft.FnvHasher::new(),
      first_sealed.checkpoint(),
      "event-a",
      proof,
    ),
  )
  assert_false(
    verify_micro_checkpoint_event(
      @bft.FnvHasher::new(),
      first_sealed.checkpoint(),
      "event-tampered",
      proof,
    ),
  )
}

///|
test "macro checkpoint force-closes a partial micro window and chains epochs" {
  let builder = test_builder()
  assert_eq(builder.append_event(10, "event-a"), AuditEventAppended)
  ignore(advanced(builder.advance_watermark(100, max_windows=1)))
  assert_eq(builder.append_event(220, "event-c"), AuditEventAppended)
  let emission = advanced(builder.advance_watermark(250, max_windows=2))
  let micros = emission.micro_checkpoints()
  assert_eq(micros.length(), 2)
  assert_eq(micros[0].checkpoint().starts_at_ms, 100)
  assert_eq(micros[0].checkpoint().ends_at_ms, 200)
  assert_eq(micros[1].checkpoint().starts_at_ms, 200)
  assert_eq(micros[1].checkpoint().ends_at_ms, 250)

  let macros = emission.macro_checkpoints()
  assert_eq(macros.length(), 1)
  let first_macro = macros[0]
  let first_checkpoint = first_macro.checkpoint()
  assert_eq(first_checkpoint.epoch, 0)
  assert_eq(first_checkpoint.starts_at_ms, 0)
  assert_eq(first_checkpoint.ends_at_ms, 250)
  assert_eq(first_checkpoint.micro_checkpoint_count, 3)
  assert_eq(first_checkpoint.event_count, 2)
  assert_eq(first_checkpoint.previous_macro_digest, @bft.Digest("genesis"))

  let micro_zero = match first_macro.micro_checkpoint(0) {
    Some(checkpoint) => checkpoint
    None => abort("first micro checkpoint must exist")
  }
  let micro_proof = match first_macro.micro_proof(0) {
    Some(proof) => proof
    None => abort("first micro proof must exist")
  }
  assert_true(
    verify_macro_checkpoint_micro(
      @bft.FnvHasher::new(),
      first_checkpoint,
      micro_zero,
      micro_proof,
    ),
  )
  let layered_proof = match first_macro.event_proof("event-a") {
    Some(proof) => proof
    None => abort("layered event proof must exist")
  }
  assert_true(
    verify_macro_checkpoint_event(
      @bft.FnvHasher::new(),
      first_checkpoint,
      "event-a",
      layered_proof,
    ),
  )
  assert_false(
    verify_macro_checkpoint_event(
      @bft.FnvHasher::new(),
      first_checkpoint,
      "event-tampered",
      layered_proof,
    ),
  )

  let next = advanced(builder.advance_watermark(500, max_windows=3))
  let next_macro = next.macro_checkpoints()[0].checkpoint()
  assert_eq(next_macro.epoch, 1)
  assert_eq(next_macro.previous_macro_digest, first_checkpoint.digest)
}

///|
test "watermark rejects late events without rejecting future pending events" {
  let builder = test_builder()
  assert_eq(builder.append_event(220, "future"), AuditEventAppended)
  let emission = advanced(builder.advance_watermark(100, max_windows=1))
  assert_eq(emission.micro_checkpoints()[0].checkpoint().event_count, 0)
  assert_eq(builder.pending_event_count(), 1)
  assert_eq(
    builder.append_event(99, "late"),
    AuditEventRefused(EventBehindWatermark),
  )
  assert_eq(builder.append_event(100, "at-watermark"), AuditEventAppended)
}

///|
test "catchup budget refusal is atomic and retryable" {
  let builder = test_builder()
  assert_eq(builder.append_event(10, "event-a"), AuditEventAppended)
  assert_eq(
    refused(builder.advance_watermark(1000, max_windows=2)),
    CheckpointWindowBudgetExceeded(3, 2),
  )
  assert_eq(builder.watermark_ms(), 0)
  assert_eq(builder.pending_event_count(), 1)
  let emission = advanced(builder.advance_watermark(1000, max_windows=12))
  assert_eq(emission.micro_checkpoints().length(), 12)
  assert_eq(emission.macro_checkpoints().length(), 4)
  assert_eq(builder.watermark_ms(), 1000)
  assert_eq(builder.pending_event_count(), 0)
}

///|
test "builder and event admission fail closed at declared budgets" {
  assert_eq(
    open_refusal(
      LayeredCheckpointBuilder::open(
        @bft.FnvHasher::new(),
        test_policy(),
        scope_id="",
        origin_ms=0,
        previous_macro_digest=@bft.Digest("genesis"),
        max_pending_events=1,
      ),
    ),
    EmptyScopeId,
  )
  assert_eq(
    open_refusal(
      LayeredCheckpointBuilder::open(
        @bft.FnvHasher::new(),
        test_policy(),
        scope_id="scope-a",
        origin_ms=0,
        previous_macro_digest=@bft.Digest("genesis"),
        max_pending_events=0,
      ),
    ),
    NonPositivePendingEventLimit,
  )
  let builder = test_builder(max_pending_events=1)
  assert_eq(
    builder.append_event(-1, "before-origin"),
    AuditEventRefused(EventBeforeOrigin),
  )
  assert_eq(builder.append_event(0, ""), AuditEventRefused(EmptyCanonicalEvent))
  assert_eq(builder.append_event(10, "first"), AuditEventAppended)
  assert_eq(
    builder.append_event(20, "second"),
    AuditEventRefused(PendingEventLimitReached),
  )
  assert_eq(
    refused(builder.advance_watermark(-1, max_windows=1)),
    WatermarkBeforeOrigin,
  )
  let no_change = advanced(builder.advance_watermark(0, max_windows=1))
  assert_eq(no_change.micro_checkpoints().length(), 0)
  assert_eq(no_change.macro_checkpoints().length(), 0)
  ignore(advanced(builder.advance_watermark(100, max_windows=1)))
  assert_eq(
    refused(builder.advance_watermark(99, max_windows=1)),
    WatermarkMovedBackward,
  )
}
