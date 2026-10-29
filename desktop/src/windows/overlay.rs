//! The shared Oliv pill rendered into a native transparent Win32 window.
//! WS_EX_NOACTIVATE and WS_EX_TRANSPARENT keep focus and mouse input in the
//! destination application. The message loop sleeps when the pill is hidden.

use std::collections::VecDeque;
use std::mem::size_of;
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, OnceLock, mpsc};
use std::time::{Duration, Instant};

use tiny_skia::Pixmap;
use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, SIZE, WPARAM};
use windows_sys::Win32::Graphics::Gdi::*;
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::HiDpi::{
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, GetDpiForWindow, SetThreadDpiAwarenessContext,
};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

use crate::draw::{self, BARS, Fonts, Kind, Palette, View};

const TICK: Duration = Duration::from_millis(40);
const NOTICE_FOR: Duration = Duration::from_millis(2500);
const WAKE: u32 = WM_APP + 1;
const RECONFIGURE: u32 = WM_APP + 2;
const CLASS: &[u16] = &[
    79, 108, 105, 118, 87, 105, 110, 100, 111, 119, 115, 79, 118, 101, 114, 108, 97, 121, 0,
];

enum Msg {
    RecStart(Arc<AtomicU32>),
    RecEnd,
    JobQueued,
    JobDone,
    Notice(Kind, String),
}

struct Handle {
    tx: mpsc::Sender<Msg>,
    // HWND is used only for the thread-safe PostMessageW call, never dereferenced.
    hwnd: usize,
}

static HANDLE: OnceLock<Handle> = OnceLock::new();
static STARTED: AtomicBool = AtomicBool::new(false);

fn send(message: Msg) -> bool {
    HANDLE.get().is_some_and(|handle| {
        handle.tx.send(message).is_ok()
            && unsafe { PostMessageW(handle.hwnd as HWND, WAKE, 0, 0) != 0 }
    })
}

pub fn rec_start(level: Arc<AtomicU32>) {
    send(Msg::RecStart(level));
}
pub fn rec_end() {
    send(Msg::RecEnd);
}
pub fn job_queued() {
    send(Msg::JobQueued);
}
pub fn job_done() {
    send(Msg::JobDone);
}
pub fn notice(kind: Kind, text: &str) -> bool {
    send(Msg::Notice(kind, text.to_string()))
}

#[derive(Default)]
struct Model {
    level: Option<Arc<AtomicU32>>,
    jobs: usize,
    notice: Option<(Kind, String, Instant)>,
    bars: VecDeque<f32>,
    phase: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Want {
    Recording,
    Processing,
    Notice,
}

impl Model {
    fn want(&mut self, now: Instant) -> Option<Want> {
        if self
            .notice
            .as_ref()
            .is_some_and(|(_, _, until)| now >= *until)
        {
            self.notice = None;
        }
        if self.level.is_some() {
            Some(Want::Recording)
        } else if self
            .notice
            .as_ref()
            .is_some_and(|(kind, _, _)| *kind == Kind::Error)
        {
            // Capture failures can still queue the audio collected before the
            // error. Keep that error visible while the partial clip processes.
            Some(Want::Notice)
        } else if self.jobs > 0 {
            Some(Want::Processing)
        } else if self.notice.is_some() {
            Some(Want::Notice)
        } else {
            None
        }
    }

    fn apply(&mut self, message: Msg, now: Instant) {
        match message {
            Msg::RecStart(level) => {
                self.bars = VecDeque::from(vec![0.0; BARS]);
                self.level = Some(level);
            }
            Msg::RecEnd => self.level = None,
            Msg::JobQueued => self.jobs = self.jobs.saturating_add(1),
            Msg::JobDone => self.jobs = self.jobs.saturating_sub(1),
            Msg::Notice(kind, text) => {
                let active_error = self
                    .notice
                    .as_ref()
                    .is_some_and(|(previous, _, until)| *previous == Kind::Error && now < *until);
                // A quick no-speech/result notice must not erase the capture
                // error before the user can read it. New errors replace errors.
                if kind == Kind::Error || !active_error {
                    self.notice = Some((kind, text, now + NOTICE_FOR));
                }
            }
        }
    }

    fn tick(&mut self) {
        self.phase = (self.phase + TICK.as_secs_f32() / 1.2).fract();
        if let Some(level) = &self.level {
            let rms = f32::from_bits(level.load(Ordering::Relaxed));
            let next = draw::bar_height(if rms.is_finite() { rms.max(0.0) } else { 0.0 });
            let prev = self.bars.back().copied().unwrap_or(0.0);
            self.bars.pop_front();
            self.bars.push_back(draw::smooth(prev, next));
        }
    }
}

unsafe extern "system" fn window_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match message {
        WM_NCHITTEST => HTTRANSPARENT as LRESULT,
        WM_MOUSEACTIVATE => MA_NOACTIVATE as LRESULT,
        WM_ERASEBKGND => 1,
        WM_DPICHANGED | WM_DISPLAYCHANGE => {
            // These are sent directly to the window procedure, so GetMessage
            // never returns them as queued MSGs. Post a wake for the render
            // loop, where rebuilding GDI buffers is safe and non-reentrant.
            unsafe { PostMessageW(hwnd, RECONFIGURE, 0, 0) };
            0
        }
        WM_DESTROY => {
            unsafe { PostQuitMessage(0) };
            0
        }
        _ => unsafe { DefWindowProcW(hwnd, message, wparam, lparam) },
    }
}

struct Window(HWND);
impl Drop for Window {
    fn drop(&mut self) {
        unsafe { DestroyWindow(self.0) };
    }
}

fn create_window() -> Result<Window, String> {
    unsafe {
        // Windows 10 1703+; only this thread's DPI context is changed.
        SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let instance = GetModuleHandleW(null());
        let class = WNDCLASSW {
            lpfnWndProc: Some(window_proc),
            hInstance: instance,
            lpszClassName: CLASS.as_ptr(),
            ..WNDCLASSW::default()
        };
        if RegisterClassW(&class) == 0 {
            return Err(format!(
                "overlay window class: {}",
                std::io::Error::last_os_error()
            ));
        }
        let hwnd = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
            CLASS.as_ptr(),
            CLASS.as_ptr(),
            WS_POPUP,
            0,
            0,
            draw::W as i32,
            draw::H as i32,
            null_mut(),
            null_mut(),
            instance,
            null(),
        );
        if hwnd.is_null() {
            return Err(format!(
                "overlay window: {}",
                std::io::Error::last_os_error()
            ));
        }
        Ok(Window(hwnd))
    }
}

/// GDI objects kept only while the pill is visible. The DIB uses exactly the
/// premultiplied BGRA layout required by UpdateLayeredWindow / AC_SRC_ALPHA.
struct Surface {
    monitor: HMONITOR,
    dc: HDC,
    bitmap: HBITMAP,
    old_bitmap: HGDIOBJ,
    pixels: *mut u8,
    pixmap: Pixmap,
    origin: POINT,
    scale: f32,
    fonts: Option<Fonts>,
    palette: Palette,
}

impl Drop for Surface {
    fn drop(&mut self) {
        unsafe {
            SelectObject(self.dc, self.old_bitmap);
            DeleteObject(self.bitmap);
            DeleteDC(self.dc);
        }
    }
}

impl Surface {
    fn new(hwnd: HWND) -> Result<Self, String> {
        unsafe {
            let monitor = MonitorFromWindow(GetForegroundWindow(), MONITOR_DEFAULTTONEAREST);
            let mut info = MONITORINFO {
                cbSize: size_of::<MONITORINFO>() as u32,
                ..MONITORINFO::default()
            };
            if GetMonitorInfoW(monitor, &mut info) == 0 {
                return Err(format!(
                    "overlay monitor: {}",
                    std::io::Error::last_os_error()
                ));
            }
            // Move onto the destination monitor first so GetDpiForWindow uses
            // this overlay's per-monitor-aware context, not the target app's.
            if SetWindowPos(
                hwnd,
                HWND_TOPMOST,
                info.rcWork.left,
                info.rcWork.top,
                0,
                0,
                SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOOWNERZORDER,
            ) == 0
            {
                return Err(format!(
                    "overlay position: {}",
                    std::io::Error::last_os_error()
                ));
            }
            let scale = (GetDpiForWindow(hwnd).max(96) as f32 / 96.0).min(4.0);
            let width = (draw::W as f32 * scale).round() as u32;
            let height = (draw::H as f32 * scale).round() as u32;
            let origin = POINT {
                x: info.rcWork.left + (info.rcWork.right - info.rcWork.left - width as i32) / 2,
                y: info.rcWork.bottom - height as i32 - (40.0 * scale) as i32,
            };
            let pixmap = Pixmap::new(width, height).ok_or("overlay pixel allocation failed")?;
            let dc = CreateCompatibleDC(null_mut());
            if dc.is_null() {
                return Err("overlay memory DC allocation failed".into());
            }
            let bitmap_info = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: width as i32,
                    biHeight: -(height as i32),
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB,
                    ..BITMAPINFOHEADER::default()
                },
                ..BITMAPINFO::default()
            };
            let mut pixels = null_mut();
            let bitmap =
                CreateDIBSection(dc, &bitmap_info, DIB_RGB_COLORS, &mut pixels, null_mut(), 0);
            if bitmap.is_null() {
                DeleteDC(dc);
                return Err("overlay bitmap allocation failed".into());
            }
            let old_bitmap = SelectObject(dc, bitmap);
            if old_bitmap.is_null() || old_bitmap as isize == -1 {
                DeleteObject(bitmap);
                DeleteDC(dc);
                return Err("overlay bitmap selection failed".into());
            }
            Ok(Self {
                monitor,
                dc,
                bitmap,
                old_bitmap,
                pixels: pixels.cast(),
                pixmap,
                origin,
                scale,
                fonts: Fonts::load(),
                palette: Palette::load(),
            })
        }
    }

    fn draw(&mut self, hwnd: HWND, model: &Model, want: Want) -> Result<(), String> {
        let bars: Vec<f32> = model.bars.iter().copied().collect();
        let view = match (want, model.notice.as_ref()) {
            (Want::Recording, _) => View::Recording { bars: &bars },
            (Want::Processing, _) => View::Processing { phase: model.phase },
            (Want::Notice, Some((kind, text, _))) => View::Notice { kind: *kind, text },
            _ => return Ok(()),
        };
        draw::render(
            &mut self.pixmap.as_mut(),
            self.scale,
            &self.palette,
            self.fonts.as_ref(),
            &view,
        );
        unsafe {
            let dest = std::slice::from_raw_parts_mut(self.pixels, self.pixmap.data().len());
            draw::to_argb8888(self.pixmap.data(), dest);
            let size = SIZE {
                cx: self.pixmap.width() as i32,
                cy: self.pixmap.height() as i32,
            };
            let blend = BLENDFUNCTION {
                BlendOp: AC_SRC_OVER as u8,
                BlendFlags: 0,
                SourceConstantAlpha: 255,
                AlphaFormat: AC_SRC_ALPHA as u8,
            };
            if UpdateLayeredWindow(
                hwnd,
                null_mut(),
                &self.origin,
                &size,
                self.dc,
                &POINT::default(),
                0,
                &blend,
                ULW_ALPHA,
            ) == 0
            {
                return Err(format!(
                    "overlay painting: {}",
                    std::io::Error::last_os_error()
                ));
            }
            ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        }
        Ok(())
    }
}

fn run(window: Window, rx: mpsc::Receiver<Msg>) -> Result<(), String> {
    let mut message = MSG::default();
    let mut model = Model::default();
    let mut surface: Option<Surface> = None;
    loop {
        let result = unsafe { GetMessageW(&mut message, null_mut(), 0, 0) };
        if result == 0 {
            return Ok(());
        }
        if result == -1 {
            return Err(format!(
                "overlay message loop: {}",
                std::io::Error::last_os_error()
            ));
        }
        unsafe {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        // Painting a layered window itself generates window-position messages.
        // They must not recursively trigger more painting or the loop will spin.
        if !matches!(message.message, WAKE | WM_TIMER | RECONFIGURE) {
            continue;
        }
        let now = Instant::now();
        for event in rx.try_iter() {
            model.apply(event, now);
        }
        let Some(want) = model.want(now) else {
            if surface.take().is_some() {
                unsafe {
                    ShowWindow(window.0, SW_HIDE);
                    KillTimer(window.0, 1);
                }
            }
            continue;
        };
        // The foreground window can move to another monitor while an older
        // dictation is still processing. That does not send a DPI notification
        // to our stationary overlay, so check the destination on visible ticks.
        let foreground_monitor =
            unsafe { MonitorFromWindow(GetForegroundWindow(), MONITOR_DEFAULTTONEAREST) };
        if message.message == RECONFIGURE
            || surface
                .as_ref()
                .is_some_and(|surface| surface.monitor != foreground_monitor)
        {
            surface = None;
        }
        if surface.is_none() {
            surface = Some(Surface::new(window.0)?);
            if unsafe { SetTimer(window.0, 1, TICK.as_millis() as u32, None) } == 0 {
                return Err("overlay animation timer failed".into());
            }
        }
        if message.message == WM_TIMER {
            model.tick();
        }
        if let Some(surface) = surface.as_mut() {
            surface.draw(window.0, &model, want)?;
        }
    }
}

pub fn spawn() -> Result<(), String> {
    if STARTED.swap(true, Ordering::AcqRel) {
        return Err("overlay already started".into());
    }
    let (tx, rx) = mpsc::channel();
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    let thread = std::thread::Builder::new()
        .name("overlay".into())
        .spawn(move || match create_window() {
            Ok(window) => {
                let _ = ready_tx.send(Ok(window.0 as usize));
                if let Err(error) = run(window, rx) {
                    eprintln!("overlay stopped: {error}");
                }
            }
            Err(error) => {
                let _ = ready_tx.send(Err(error));
            }
        });
    if let Err(error) = thread {
        STARTED.store(false, Ordering::Release);
        return Err(format!("overlay thread: {error}"));
    }
    let hwnd = ready_rx
        .recv()
        .map_err(|_| "overlay thread exited during startup".to_string())??;
    HANDLE
        .set(Handle { tx, hwnd })
        .map_err(|_| "overlay already registered".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recording_then_jobs_then_notice_and_expiry() {
        let now = Instant::now();
        let mut model = Model::default();
        model.apply(Msg::Notice(Kind::Info, "ทดสอบ".into()), now);
        model.apply(Msg::JobQueued, now);
        model.apply(Msg::RecStart(Arc::new(AtomicU32::new(0))), now);
        assert_eq!(model.want(now), Some(Want::Recording));
        model.apply(Msg::RecEnd, now);
        assert_eq!(model.want(now), Some(Want::Processing));
        model.apply(Msg::JobDone, now);
        assert_eq!(model.want(now), Some(Want::Notice));
        assert_eq!(model.want(now + NOTICE_FOR), None);
        model.apply(Msg::JobDone, now);
        assert_eq!(model.want(now), None);
    }

    #[test]
    fn bars_follow_audio_and_reject_nan() {
        let level = Arc::new(AtomicU32::new(0.1f32.to_bits()));
        let mut model = Model::default();
        model.apply(Msg::RecStart(Arc::clone(&level)), Instant::now());
        model.tick();
        assert!(model.bars.back().copied().unwrap() > 0.0);
        level.store(f32::NAN.to_bits(), Ordering::Relaxed);
        model.tick();
        assert_eq!(model.bars.len(), BARS);
        assert!(model.bars.iter().all(|bar| bar.is_finite()));
    }

    #[test]
    fn capture_error_is_visible_while_partial_audio_processes_then_processing_resumes() {
        let now = Instant::now();
        let mut model = Model::default();
        model.apply(Msg::RecStart(Arc::new(AtomicU32::new(0))), now);
        model.apply(Msg::JobQueued, now);
        model.apply(Msg::Notice(Kind::Error, "ไมโครโฟนถูกถอด".into()), now);
        assert_eq!(model.want(now), Some(Want::Recording));
        model.apply(Msg::RecEnd, now);
        assert_eq!(model.want(now), Some(Want::Notice));
        assert_eq!(
            model.want(now + NOTICE_FOR - Duration::from_millis(1)),
            Some(Want::Notice)
        );
        assert_eq!(model.want(now + NOTICE_FOR), Some(Want::Processing));
        model.apply(Msg::JobDone, now + NOTICE_FOR);
        assert_eq!(model.want(now + NOTICE_FOR), None);
    }

    #[test]
    fn fast_info_cannot_replace_or_extend_an_active_error() {
        let now = Instant::now();
        let mut model = Model::default();
        model.apply(Msg::JobQueued, now);
        model.apply(
            Msg::Notice(Kind::Error, "microphone disconnected".into()),
            now,
        );
        model.apply(
            Msg::Notice(Kind::Info, "no speech".into()),
            now + Duration::from_millis(50),
        );
        let (kind, text, until) = model.notice.as_ref().unwrap();
        assert_eq!(*kind, Kind::Error);
        assert_eq!(text, "microphone disconnected");
        assert_eq!(*until, now + NOTICE_FOR);
        assert_eq!(
            model.want(now + Duration::from_millis(50)),
            Some(Want::Notice)
        );
        assert_eq!(model.want(now + NOTICE_FOR), Some(Want::Processing));
    }

    #[test]
    fn new_error_replaces_error_and_expired_error_allows_info() {
        let now = Instant::now();
        let mut model = Model::default();
        model.apply(Msg::Notice(Kind::Error, "first error".into()), now);
        let later = now + Duration::from_secs(1);
        model.apply(Msg::Notice(Kind::Error, "second error".into()), later);
        assert_eq!(model.notice.as_ref().unwrap().1, "second error");
        assert_eq!(model.notice.as_ref().unwrap().2, later + NOTICE_FOR);
        // Apply without first calling want(): expiry must be checked by apply.
        model.apply(Msg::Notice(Kind::Info, "ready".into()), later + NOTICE_FOR);
        assert_eq!(model.notice.as_ref().unwrap().0, Kind::Info);
        assert_eq!(model.notice.as_ref().unwrap().1, "ready");
    }

    #[test]
    #[ignore = "requires a Windows desktop; briefly creates a non-activating overlay window"]
    fn native_overlay_renders_without_activation_and_queues_display_changes() {
        let foreground = unsafe { GetForegroundWindow() };
        let window = create_window().unwrap();
        let mut surface = Surface::new(window.0).unwrap();
        assert!(
            surface.fonts.is_some(),
            "Windows Thai and Latin fonts are required"
        );
        let mut model = Model::default();
        model.apply(Msg::Notice(Kind::Info, "ทดสอบ Oliv".into()), Instant::now());
        surface.draw(window.0, &model, Want::Notice).unwrap();
        assert_ne!(unsafe { IsWindowVisible(window.0) }, 0);
        assert_eq!(unsafe { GetForegroundWindow() }, foreground);
        assert!(
            surface
                .pixmap
                .data()
                .as_chunks::<4>()
                .0
                .iter()
                .any(|pixel| pixel[3] > 0)
        );

        // Isolate the explicit sent-message regression from any DPI message
        // Windows emitted while initially positioning the test window.
        let mut message = MSG::default();
        while unsafe { PeekMessageW(&mut message, window.0, RECONFIGURE, RECONFIGURE, PM_REMOVE) }
            != 0
        {}
        for kind in [WM_DPICHANGED, WM_DISPLAYCHANGE] {
            unsafe { SendMessageW(window.0, kind, 0, 0) };
            assert_ne!(
                unsafe {
                    PeekMessageW(&mut message, window.0, RECONFIGURE, RECONFIGURE, PM_REMOVE)
                },
                0
            );
            assert_eq!(message.message, RECONFIGURE);
        }
    }
}
