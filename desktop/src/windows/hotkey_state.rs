//! Pure push-to-talk state machine, testable without a Windows desktop.

use crate::ipc::Command;

const VK_RSHIFT: u32 = 0xA1;
const VK_ESCAPE: u32 = 0x1B;

#[derive(Default)]
pub(super) struct Keys {
    pub(super) held: bool,
    pub(super) cancelled: bool,
    escape: bool,
}

impl Keys {
    /// Returns (command, suppress). Repeats never trigger a second recording.
    pub(super) fn event(
        &mut self,
        key: u32,
        down: bool,
        injected: bool,
    ) -> (Option<Command>, bool) {
        if injected {
            return (None, false);
        }
        if key == VK_RSHIFT {
            if !down && !self.held {
                return (None, false);
            }
            let command = if down && !self.held {
                self.held = true;
                self.cancelled = false;
                Some(Command::Start)
            } else if !down && self.held {
                self.held = false;
                if self.cancelled {
                    None
                } else {
                    Some(Command::Stop)
                }
            } else {
                None
            };
            return (command, true);
        }
        if key == VK_ESCAPE {
            if down && self.held {
                self.escape = true;
                let command = if self.cancelled {
                    None
                } else {
                    Some(Command::Cancel)
                };
                self.cancelled = true;
                return (command, true);
            }
            if self.escape {
                if !down {
                    self.escape = false;
                }
                return (None, true);
            }
        }
        (None, false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repeats_produce_one_start_and_one_stop() {
        let mut keys = Keys::default();
        assert_eq!(
            keys.event(VK_RSHIFT, true, false),
            (Some(Command::Start), true)
        );
        assert_eq!(keys.event(VK_RSHIFT, true, false), (None, true));
        assert_eq!(
            keys.event(VK_RSHIFT, false, false),
            (Some(Command::Stop), true)
        );
        assert_eq!(keys.event(VK_RSHIFT, false, false), (None, false));
    }

    #[test]
    fn escape_cancels_once_and_swallows_its_release() {
        let mut keys = Keys::default();
        assert_eq!(keys.event(VK_ESCAPE, true, false), (None, false));
        keys.event(VK_RSHIFT, true, false);
        assert_eq!(
            keys.event(VK_ESCAPE, true, false),
            (Some(Command::Cancel), true)
        );
        assert_eq!(keys.event(VK_ESCAPE, true, false), (None, true));
        assert_eq!(keys.event(VK_RSHIFT, false, false), (None, true));
        assert_eq!(keys.event(VK_ESCAPE, false, false), (None, true));
        assert_eq!(keys.event(VK_ESCAPE, true, false), (None, false));
        assert_eq!(
            keys.event(VK_RSHIFT, true, false),
            (Some(Command::Start), true)
        );
    }

    #[test]
    fn injected_keys_and_left_shift_pass_through() {
        let mut keys = Keys::default();
        assert_eq!(keys.event(VK_RSHIFT, true, true), (None, false));
        assert_eq!(keys.event(0xA0, true, false), (None, false));
        assert!(!keys.held);
    }
}
