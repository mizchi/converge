///|
test "LamportClock::new starts at 0" {
  let clock = @clock.LamportClock::new()
  assert_eq(clock.counter, 0)
}

///|
test "LamportClock::tick increments" {
  let clock = @clock.LamportClock::new()
  assert_eq(clock.tick(), 1)
  assert_eq(clock.tick(), 2)
  assert_eq(clock.tick(), 3)
}

///|
test "LamportClock::merge with larger remote" {
  let clock = @clock.LamportClock::new()
  ignore(clock.tick()) // counter = 1
  clock.merge(5) // max(1, 5) + 1 = 6
  assert_eq(clock.counter, 6)
}

///|
test "LamportClock::merge with smaller remote" {
  let clock = @clock.LamportClock::new()
  ignore(clock.tick()) // 1
  ignore(clock.tick()) // 2
  ignore(clock.tick()) // 3
  clock.merge(1) // max(3, 1) + 1 = 4
  assert_eq(clock.counter, 4)
}

///|
test "LamportClock::merge then tick" {
  let clock = @clock.LamportClock::new()
  clock.merge(10) // 11
  assert_eq(clock.tick(), 12)
}
