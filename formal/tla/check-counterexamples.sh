#!/usr/bin/env sh
set -eu

check_expected_failure() {
  config="$1"
  expected="$2"
  log_file="$3"
  module="${4:-formal/tla/CheckpointDelivery.tla}"
  if tlc -cleanup -metadir target/tla/counterexamples -workers auto \
    -config "$config" "$module" >"$log_file" 2>&1; then
    echo "expected TLC to reject $config" >&2
    return 1
  fi
  if ! grep -F "$expected" "$log_file" >/dev/null; then
    echo "TLC rejected $config for an unexpected reason" >&2
    sed -n '1,220p' "$log_file" >&2
    return 1
  fi
  echo "detected expected counterexample: $config"
}

audit_tla_tmp="$(mktemp -d "${TMPDIR:-/tmp}/converge-tla.XXXXXX")"
trap 'rm -rf -- "$audit_tla_tmp"' EXIT HUP INT TERM

check_expected_failure \
  formal/tla/CheckpointDeliveryBrokenCompleteness.cfg \
  "Invariant CheckpointCompleteness is violated" \
  "$audit_tla_tmp/completeness.log"
check_expected_failure \
  formal/tla/CheckpointDeliveryBrokenOutbox.cfg \
  "Invariant NoLostSealedCheckpoint is violated" \
  "$audit_tla_tmp/outbox.log"
check_expected_failure \
  formal/tla/CheckpointDeliveryBrokenParent.cfg \
  "Invariant HeadLogsAreExactChains is violated" \
  "$audit_tla_tmp/parent.log"
check_expected_failure \
  formal/tla/CheckpointDeliveryBrokenRetry.cfg \
  "Temporal properties were violated" \
  "$audit_tla_tmp/retry.log"
check_expected_failure \
  formal/tla/CheckpointDeliveryBrokenBackpressure.cfg \
  "Invariant OutboxWithinCapacity is violated" \
  "$audit_tla_tmp/backpressure.log"
check_expected_failure \
  formal/tla/WitnessQuorumBrokenProducer.cfg \
  "Invariant ReadyRequiresAuthenticatedDistinctRosterQuorum is violated" \
  "$audit_tla_tmp/witness-producer.log" \
  formal/tla/WitnessQuorum.tla
check_expected_failure \
  formal/tla/WitnessQuorumBrokenRoster.cfg \
  "Invariant ReadyRequiresAuthenticatedDistinctRosterQuorum is violated" \
  "$audit_tla_tmp/witness-roster.log" \
  formal/tla/WitnessQuorum.tla
