//! FIFO admission for a model stage. HTTP admission bounds total waiters.
//! A permit lives with the actual blocking inference, even after disconnect.
use std::collections::VecDeque;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

#[derive(Default)]
struct State {
    active: usize,
    next: u64,
    waiting: VecDeque<u64>,
}

pub struct StageGate {
    capacity: usize,
    state: Mutex<State>,
    changed: Condvar,
}

pub struct StagePermit<'a>(&'a StageGate);

impl StageGate {
    pub fn new(capacity: usize) -> Self {
        assert!((1..=4).contains(&capacity));
        Self {
            capacity,
            state: Mutex::new(State::default()),
            changed: Condvar::new(),
        }
    }

    pub fn capacity(&self) -> usize {
        self.capacity
    }

    pub fn acquire(&self, timeout: Duration) -> Result<StagePermit<'_>, &'static str> {
        let deadline = Instant::now() + timeout;
        let mut state = self.state.lock().map_err(|_| "ASR admission unavailable")?;
        let ticket = state.next;
        state.next = state.next.wrapping_add(1);
        state.waiting.push_back(ticket);
        let mut first_attempt = true;
        loop {
            if !first_attempt && Instant::now() >= deadline {
                state.waiting.retain(|id| *id != ticket);
                self.changed.notify_all();
                return Err("inference queue wait exceeded");
            }
            first_attempt = false;
            if state.waiting.front() == Some(&ticket) && state.active < self.capacity {
                state.waiting.pop_front();
                state.active += 1;
                self.changed.notify_all();
                return Ok(StagePermit(self));
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                state.waiting.retain(|id| *id != ticket);
                self.changed.notify_all();
                return Err("inference queue wait exceeded");
            }
            state = self
                .changed
                .wait_timeout(state, remaining)
                .map_err(|_| "ASR admission unavailable")?
                .0;
        }
    }
}

impl Drop for StagePermit<'_> {
    fn drop(&mut self) {
        let mut state = self
            .0
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        state.active = state.active.saturating_sub(1);
        self.0.changed.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, mpsc};
    use std::thread;

    #[test]
    fn capacity_is_shared_and_drop_releases_it() {
        let gate = StageGate::new(2);
        let one = gate.acquire(Duration::ZERO).unwrap();
        let _two = gate.acquire(Duration::ZERO).unwrap();
        assert!(gate.acquire(Duration::ZERO).is_err());
        drop(one);
        assert!(gate.acquire(Duration::ZERO).is_ok());
    }

    #[test]
    fn expired_waiter_never_runs_after_permit_is_released() {
        let gate = Arc::new(StageGate::new(1));
        let held = gate.acquire(Duration::ZERO).unwrap();
        let other = Arc::clone(&gate);
        let waiter = thread::spawn(move || other.acquire(Duration::from_millis(10)).is_ok());
        assert!(!waiter.join().unwrap());
        drop(held);
        assert!(gate.acquire(Duration::ZERO).is_ok());
    }

    #[test]
    fn waiting_clients_run_in_fifo_order() {
        let gate = Arc::new(StageGate::new(1));
        let held = gate.acquire(Duration::ZERO).unwrap();
        let (send, receive) = mpsc::channel();
        let mut workers = Vec::new();
        for id in 0..3 {
            let other = Arc::clone(&gate);
            let send = send.clone();
            workers.push(thread::spawn(move || {
                let _permit = other.acquire(Duration::from_secs(2)).unwrap();
                send.send(id).unwrap();
            }));
            let deadline = Instant::now() + Duration::from_secs(1);
            while gate.state.lock().unwrap().waiting.len() != id + 1 {
                assert!(Instant::now() < deadline);
                thread::yield_now();
            }
        }
        drop(held);
        assert_eq!(
            (0..3)
                .map(|_| receive.recv_timeout(Duration::from_secs(2)).unwrap())
                .collect::<Vec<_>>(),
            vec![0, 1, 2]
        );
        for worker in workers {
            worker.join().unwrap();
        }
    }
}
