///|
/// Lamport logical clock
pub(all) struct LamportClock {
  mut counter : Int
}

///|
pub fn LamportClock::new() -> LamportClock {
  { counter: 0 }
}

///|
/// Increment and return the new counter value
pub fn LamportClock::tick(self : LamportClock) -> Int {
  self.counter += 1
  self.counter
}

///|
/// Merge with a remote timestamp: max(local, remote) + 1
pub fn LamportClock::merge(self : LamportClock, remote : Int) -> Unit {
  if remote > self.counter {
    self.counter = remote
  }
  self.counter += 1
}
