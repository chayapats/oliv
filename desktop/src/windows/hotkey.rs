//! Global push-to-talk on a dedicated Win32 hook thread. The hook only updates
//! key state and sends a command; capture, HTTP and IPC never run inside it.

use std::cell::RefCell;
use std::ptr::null_mut;
#[cfg(test)]
use std::sync::atomic::AtomicUsize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;

use windows_sys::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::WindowsAndMessaging::*;

use crate::ipc::Command;

static RUNNING: AtomicBool = AtomicBool::new(false);
#[cfg(test)]
static INJECTED_EVENTS: AtomicUsize = AtomicUsize::new(0);

thread_local! {
    static HOOK: RefCell<Option<(Keys, mpsc::Sender<Command>)>> = const { RefCell::new(None) };
}

#[path = "hotkey_state.rs"]
mod state;
use state::Keys;

unsafe extern "system" fn keyboard(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let down = matches!(wparam as u32, WM_KEYDOWN | WM_SYSKEYDOWN);
        let up = matches!(wparam as u32, WM_KEYUP | WM_SYSKEYUP);
        if down || up {
            // Win32 guarantees KBDLLHOOKSTRUCT for HC_ACTION keyboard messages.
            let key = unsafe { &*(lparam as *const KBDLLHOOKSTRUCT) };
            #[cfg(test)]
            if key.flags & LLKHF_INJECTED != 0
                && key.vkCode == 0xA1
                && key.dwExtraInfo == 0x4F4C4956
            {
                INJECTED_EVENTS.fetch_add(1, Ordering::Relaxed);
            }
            let suppress = HOOK.with(|hook| {
                let mut hook = hook.borrow_mut();
                let Some((keys, tx)) = hook.as_mut() else {
                    return false;
                };
                let (command, suppress) =
                    keys.event(key.vkCode, down, key.flags & LLKHF_INJECTED != 0);
                if let Some(command) = command
                    && tx.send(command).is_err()
                {
                    *hook = None;
                    return false;
                }
                suppress
            });
            if suppress {
                return 1;
            }
        }
    }
    unsafe { CallNextHookEx(null_mut(), code, wparam, lparam) }
}

/// Reserve physical Right Shift for dictation; Left Shift remains untouched.
/// `callback` runs serially on a separate worker thread, outside the hook.
pub fn spawn(callback: impl Fn(Command) + Send + 'static) -> Result<(), String> {
    if RUNNING.swap(true, Ordering::AcqRel) {
        return Err("Right Shift hook is already running".into());
    }
    let (tx, rx) = mpsc::channel();
    if let Err(e) = std::thread::Builder::new()
        .name("hotkey-commands".into())
        .spawn(move || {
            for command in rx {
                callback(command);
            }
        })
    {
        RUNNING.store(false, Ordering::Release);
        return Err(format!("hotkey command thread: {e}"));
    }
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    if let Err(e) = std::thread::Builder::new()
        .name("hotkey".into())
        .spawn(move || {
            HOOK.with(|hook| *hook.borrow_mut() = Some((Keys::default(), tx)));
            let hook = unsafe {
                SetWindowsHookExW(
                    WH_KEYBOARD_LL,
                    Some(keyboard),
                    GetModuleHandleW(std::ptr::null()),
                    0,
                )
            };
            if hook.is_null() {
                let _ = ready_tx.send(Err(format!(
                    "Right Shift hook: {}",
                    std::io::Error::last_os_error()
                )));
            } else {
                let _ = ready_tx.send(Ok(()));
                let mut message = MSG::default();
                loop {
                    let result = unsafe { GetMessageW(&mut message, null_mut(), 0, 0) };
                    if result <= 0 {
                        if result == -1 {
                            eprintln!("hotkey message loop: {}", std::io::Error::last_os_error());
                        }
                        break;
                    }
                    unsafe {
                        TranslateMessage(&message);
                        DispatchMessageW(&message);
                    }
                }
                unsafe { UnhookWindowsHookEx(hook) };
            }
            HOOK.with(|hook| {
                if let Some((keys, tx)) = hook.borrow_mut().take()
                    && keys.held
                    && !keys.cancelled
                {
                    let _ = tx.send(Command::Cancel);
                }
            });
            RUNNING.store(false, Ordering::Release);
        })
    {
        RUNNING.store(false, Ordering::Release);
        return Err(format!("hotkey thread: {e}"));
    }
    ready_rx
        .recv()
        .map_err(|_| "hotkey thread exited during startup".to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::size_of;
    use std::time::{Duration, Instant};
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
        INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, SendInput, VK_RSHIFT,
    };

    struct InstalledHook(HHOOK);
    impl Drop for InstalledHook {
        fn drop(&mut self) {
            unsafe { UnhookWindowsHookEx(self.0) };
            HOOK.with(|hook| *hook.borrow_mut() = None);
        }
    }

    #[test]
    fn injected_release_and_escape_cannot_end_a_physical_recording() {
        let mut keys = Keys::default();
        assert_eq!(
            keys.event(VK_RSHIFT as u32, true, false),
            (Some(Command::Start), true)
        );
        assert_eq!(keys.event(VK_RSHIFT as u32, false, true), (None, false));
        assert_eq!(keys.event(0x1B, true, true), (None, false));
        assert!(keys.held);
        assert!(!keys.cancelled);
        assert_eq!(
            keys.event(VK_RSHIFT as u32, false, false),
            (Some(Command::Stop), true)
        );
    }

    struct ReleaseShiftOnDrop;
    impl Drop for ReleaseShiftOnDrop {
        fn drop(&mut self) {
            let input = INPUT {
                r#type: INPUT_KEYBOARD,
                Anonymous: INPUT_0 {
                    ki: KEYBDINPUT {
                        wVk: VK_RSHIFT,
                        dwFlags: KEYEVENTF_KEYUP,
                        ..KEYBDINPUT::default()
                    },
                },
            };
            unsafe { SendInput(1, &input, size_of::<INPUT>() as i32) };
        }
    }

    #[test]
    #[ignore = "requires an interactive Windows desktop; injects a balanced Right Shift press/release"]
    fn native_keyboard_hook_observes_and_ignores_injected_right_shift() {
        let (tx, rx) = mpsc::channel();
        HOOK.with(|hook| *hook.borrow_mut() = Some((Keys::default(), tx)));
        let raw = unsafe {
            SetWindowsHookExW(
                WH_KEYBOARD_LL,
                Some(keyboard),
                GetModuleHandleW(std::ptr::null()),
                0,
            )
        };
        assert!(
            !raw.is_null(),
            "install native low-level hook: {}",
            std::io::Error::last_os_error()
        );
        let _hook = InstalledHook(raw);
        let before = INJECTED_EVENTS.load(Ordering::Relaxed);
        let input = |up| INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: VK_RSHIFT,
                    dwFlags: if up { KEYEVENTF_KEYUP } else { 0 },
                    dwExtraInfo: 0x4F4C4956,
                    ..KEYBDINPUT::default()
                },
            },
        };
        let inputs = [input(false), input(true)];
        // A partial SendInput failure or assertion must never leave Shift held.
        let _release = ReleaseShiftOnDrop;
        assert_eq!(
            unsafe { SendInput(2, inputs.as_ptr(), size_of::<INPUT>() as i32) },
            2
        );
        let start = Instant::now();
        let mut message = MSG::default();
        while INJECTED_EVENTS
            .load(Ordering::Relaxed)
            .saturating_sub(before)
            < 2
        {
            while unsafe { PeekMessageW(&mut message, null_mut(), 0, 0, PM_REMOVE) } != 0 {
                unsafe {
                    TranslateMessage(&message);
                    DispatchMessageW(&message);
                }
            }
            assert!(
                start.elapsed() < Duration::from_secs(3),
                "native hook did not receive injected events"
            );
            std::thread::sleep(Duration::from_millis(1));
        }
        assert!(
            matches!(rx.try_recv(), Err(mpsc::TryRecvError::Empty)),
            "software-generated Shift must not trigger dictation"
        );
        HOOK.with(|hook| assert!(!hook.borrow().as_ref().unwrap().0.held));
    }
}
