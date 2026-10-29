//! Small-group limits, shared across every HTTP connection. Counters are
//! process-local UTC fixed windows, not persistent billing quotas.
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::auth::Principal;

pub const MAX_ADMITTED: usize = 8; // bounded across active, queued and uploading requests
const MAX_COUNTERS: usize = 1024;

#[derive(Default)]
struct Bucket {
    minute: u64,
    day: u64,
    minute_count: u32,
    day_count: u32,
    active: bool,
}

#[derive(Default)]
struct State {
    admitted: usize,
    users: HashMap<String, Bucket>,
}

#[derive(Default)]
pub struct Admission(Mutex<State>);

#[derive(Debug, PartialEq)]
pub enum Rejected {
    Rate,
    Active,
    Full,
}

pub struct Permit {
    admission: Arc<Admission>,
    id: String,
}

impl Admission {
    pub fn reserve(self: &Arc<Self>, user: &Principal) -> Result<Permit, Rejected> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        self.reserve_observed_at(user, now).0
    }

    pub fn reserve_observed(
        self: &Arc<Self>,
        user: &Principal,
    ) -> (Result<Permit, Rejected>, bool) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        self.reserve_observed_at(user, now)
    }

    #[cfg(test)]
    fn reserve_at(self: &Arc<Self>, user: &Principal, now: u64) -> Result<Permit, Rejected> {
        self.reserve_observed_at(user, now).0
    }

    fn reserve_observed_at(
        self: &Arc<Self>,
        user: &Principal,
        now: u64,
    ) -> (Result<Permit, Rejected>, bool) {
        let mut state = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let (minute, day) = (now / 60, now / 86400);
        state.users.retain(|_, b| b.active || b.day >= day);
        if !state.users.contains_key(&user.id) && state.users.len() >= MAX_COUNTERS {
            return (Err(Rejected::Full), false);
        }
        let b = state.users.entry(user.id.clone()).or_default();
        if minute > b.minute {
            b.minute = minute;
            b.minute_count = 0;
        }
        if day > b.day {
            b.day = day;
            b.day_count = 0;
        }
        if b.minute_count >= user.requests_per_minute || b.day_count >= user.daily_requests {
            return (Err(Rejected::Rate), false);
        }
        b.minute_count += 1;
        b.day_count += 1;
        if b.active {
            return (Err(Rejected::Active), true);
        }
        if state.admitted >= MAX_ADMITTED {
            return (Err(Rejected::Full), true);
        }
        state.users.get_mut(&user.id).unwrap().active = true;
        state.admitted += 1;
        (
            Ok(Permit {
                admission: Arc::clone(self),
                id: user.id.clone(),
            }),
            true,
        )
    }
}

impl Drop for Permit {
    fn drop(&mut self) {
        let mut state = self.admission.0.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(b) = state.users.get_mut(&self.id) {
            b.active = false;
        }
        state.admitted = state.admitted.saturating_sub(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn user(id: &str) -> Principal {
        Principal {
            id: id.into(),
            requests_per_minute: 10,
            daily_requests: 12,
        }
    }
    #[test]
    fn capacity_is_global_and_released_by_drop() {
        let a = Arc::new(Admission::default());
        let p = a.reserve_at(&user("a"), 100).unwrap();
        assert!(matches!(
            a.reserve_at(&user("a"), 100),
            Err(Rejected::Active)
        ));
        let _q = a.reserve_at(&user("b"), 100).unwrap();
        let _rest: Vec<_> = (2..MAX_ADMITTED)
            .map(|i| a.reserve_at(&user(&format!("queued-{i}")), 100).unwrap())
            .collect();
        assert!(matches!(a.reserve_at(&user("d"), 100), Err(Rejected::Full)));
        drop(p);
        assert!(a.reserve_at(&user("d"), 100).is_ok());
    }
    #[test]
    fn minute_and_day_quotas_are_separate_and_clock_rollback_does_not_reset() {
        let a = Arc::new(Admission::default());
        for _ in 0..10 {
            drop(a.reserve_at(&user("a"), 100).unwrap());
        }
        assert!(matches!(a.reserve_at(&user("a"), 100), Err(Rejected::Rate)));
        assert!(matches!(a.reserve_at(&user("a"), 59), Err(Rejected::Rate)));
        for _ in 0..2 {
            drop(a.reserve_at(&user("a"), 120).unwrap());
        }
        assert!(matches!(a.reserve_at(&user("a"), 180), Err(Rejected::Rate)));
        assert!(a.reserve_at(&user("a"), 86400).is_ok());
        assert!(a.reserve_at(&user("b"), 100).is_ok());
    }
}
