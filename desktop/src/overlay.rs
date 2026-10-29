//! The on-screen state pill: a layer-shell surface on the `overlay` layer that
//! takes no input and no focus. It lives on its own thread, which blocks in
//! `poll` while nothing is shown (no timers, no drawing). The surface, buffer
//! pool and fonts exist only while a view is visible.
//!
//! What to show is derived from three facts, highest priority first:
//! recording, jobs in flight, a notice that has not expired.

use std::collections::VecDeque;
use std::os::fd::{AsRawFd, RawFd};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, OnceLock, mpsc};
use std::time::{Duration, Instant};

use smithay_client_toolkit::compositor::{CompositorHandler, CompositorState, Region};
use smithay_client_toolkit::output::{OutputHandler, OutputState};
use smithay_client_toolkit::reexports::client::backend::WaylandError;
use smithay_client_toolkit::reexports::client::globals::registry_queue_init;
use smithay_client_toolkit::reexports::client::protocol::{wl_output, wl_shm, wl_surface};
use smithay_client_toolkit::reexports::client::{Connection, EventQueue, QueueHandle};
use smithay_client_toolkit::registry::{ProvidesRegistryState, RegistryState};
use smithay_client_toolkit::shell::WaylandSurface;
use smithay_client_toolkit::shell::wlr_layer::{
    Anchor, KeyboardInteractivity, Layer, LayerShell, LayerShellHandler, LayerSurface,
    LayerSurfaceConfigure,
};
use smithay_client_toolkit::shm::slot::SlotPool;
use smithay_client_toolkit::shm::{Shm, ShmHandler};
use smithay_client_toolkit::{delegate_registry, registry_handlers};

use crate::draw::{self, BARS, Fonts, Kind, Palette, View};

/// Animation frame interval while recording or processing (~25 fps).
const TICK: Duration = Duration::from_millis(40);
/// A notice stays up this long.
const NOTICE_FOR: Duration = Duration::from_millis(2500);
/// Gap between the pill and the bottom edge of the screen, in logical pixels.
const BOTTOM_MARGIN: i32 = 40;

enum Msg {
    RecStart(Arc<AtomicU32>),
    RecEnd,
    JobQueued,
    JobDone,
    Notice(Kind, String),
}

#[derive(Clone)]
struct Handle {
    tx: mpsc::Sender<Msg>,
    wake: RawFd,
}

static HANDLE: OnceLock<Handle> = OnceLock::new();

/// Connect to the compositor and start the overlay thread. On failure (no
/// Wayland, no layer-shell) notices keep going through `notify-send`.
pub fn spawn() -> Result<(), String> {
    let conn = Connection::connect_to_env().map_err(|e| format!("wayland: {e}"))?;
    let (globals, queue) = registry_queue_init::<Wl>(&conn).map_err(|e| format!("wayland: {e}"))?;
    let qh = queue.handle();
    let compositor =
        CompositorState::bind(&globals, &qh).map_err(|e| format!("wl_compositor: {e}"))?;
    let layer_shell = LayerShell::bind(&globals, &qh).map_err(|e| format!("layer-shell: {e}"))?;
    let shm = Shm::bind(&globals, &qh).map_err(|e| format!("wl_shm: {e}"))?;
    let wl = Wl {
        registry: RegistryState::new(&globals),
        output: OutputState::new(&globals, &qh),
        compositor,
        layer_shell,
        shm,
        model: Model::default(),
        surf: None,
    };
    let wake = unsafe { libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC) };
    if wake < 0 {
        return Err(format!("eventfd: {}", std::io::Error::last_os_error()));
    }
    let (tx, rx) = mpsc::channel();
    std::thread::Builder::new()
        .name("overlay".into())
        .spawn(move || {
            if let Err(e) = run(conn, queue, wl, rx, wake) {
                eprintln!("overlay stopped: {e}");
            }
        })
        .map_err(|e| format!("overlay thread: {e}"))?;
    let _ = HANDLE.set(Handle { tx, wake });
    Ok(())
}

impl Handle {
    fn send(&self, m: Msg) -> bool {
        if self.tx.send(m).is_err() {
            return false; // the thread is gone
        }
        let one = 1u64.to_ne_bytes();
        unsafe { libc::write(self.wake, one.as_ptr().cast(), one.len()) };
        true
    }
}

fn send(m: Msg) -> bool {
    HANDLE.get().is_some_and(|h| h.send(m))
}

/// The bars follow `level` (RMS, 0..1) until `rec_end`.
pub fn rec_start(level: Arc<AtomicU32>) {
    send(Msg::RecStart(level));
}

pub fn rec_end() {
    send(Msg::RecEnd);
}

/// A recording went to the worker; shows "processing" until `job_done`.
pub fn job_queued() {
    send(Msg::JobQueued);
}

pub fn job_done() {
    send(Msg::JobDone);
}

/// Show a short notice. False when there is no overlay to show it.
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

#[derive(Clone, Copy, PartialEq, Debug)]
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
        } else if self.jobs > 0 {
            Some(Want::Processing)
        } else if self.notice.is_some() {
            Some(Want::Notice)
        } else {
            None
        }
    }

    fn apply(&mut self, m: Msg, now: Instant) {
        match m {
            Msg::RecStart(l) => {
                self.bars = VecDeque::from(vec![0.0; BARS]);
                self.level = Some(l);
            }
            Msg::RecEnd => self.level = None,
            Msg::JobQueued => self.jobs += 1,
            Msg::JobDone => self.jobs = self.jobs.saturating_sub(1),
            Msg::Notice(k, t) => self.notice = Some((k, t, now + NOTICE_FOR)),
        }
    }

    /// Advance the animation by one frame.
    fn tick(&mut self) {
        self.phase = (self.phase + TICK.as_secs_f32() / 1.2).fract();
        if let Some(l) = &self.level {
            let next = draw::bar_height(f32::from_bits(l.load(Ordering::Relaxed)));
            let prev = self.bars.back().copied().unwrap_or(0.0);
            self.bars.pop_front();
            self.bars.push_back(draw::smooth(prev, next));
        }
    }
}

/// Everything that exists only while something is on screen.
struct Surf {
    layer: LayerSurface,
    pool: SlotPool,
    fonts: Option<Fonts>,
    pal: Palette,
    configured: bool,
    scale: i32,
    /// What was last painted; a change repaints at once instead of waiting for a tick.
    drawn: Option<(Want, Option<String>)>,
    next_tick: Instant,
}

struct Wl {
    registry: RegistryState,
    output: OutputState,
    compositor: CompositorState,
    layer_shell: LayerShell,
    shm: Shm,
    model: Model,
    surf: Option<Surf>,
}

impl Wl {
    fn show(&mut self, qh: &QueueHandle<Wl>) -> Result<(), String> {
        let surface = self.compositor.create_surface(qh);
        // Empty input region: the pill never catches the mouse.
        let empty = Region::new(&self.compositor).map_err(|e| format!("wl_region: {e}"))?;
        surface.set_input_region(Some(empty.wl_region()));
        let layer =
            self.layer_shell
                .create_layer_surface(qh, surface, Layer::Overlay, Some("oliv"), None);
        layer.set_anchor(Anchor::BOTTOM);
        layer.set_keyboard_interactivity(KeyboardInteractivity::None);
        layer.set_exclusive_zone(-1);
        layer.set_margin(0, 0, BOTTOM_MARGIN, 0);
        layer.set_size(draw::W, draw::H);
        layer.commit();
        let pool = SlotPool::new((draw::W * draw::H * 4 * 4) as usize, &self.shm)
            .map_err(|e| format!("shm pool: {e}"))?;
        self.surf = Some(Surf {
            layer,
            pool,
            fonts: Fonts::load(),
            pal: Palette::load(),
            configured: false,
            scale: 1,
            drawn: None,
            next_tick: Instant::now(),
        });
        Ok(())
    }

    /// Paint the current view if it changed or a tick is due.
    fn draw(&mut self, want: Want, now: Instant) {
        let Some(s) = self.surf.as_mut().filter(|s| s.configured) else {
            return;
        };
        let text = self.model.notice.as_ref().map(|(_, t, _)| t.clone());
        let key = (want, if want == Want::Notice { text } else { None });
        let animated = want != Want::Notice;
        if s.drawn.as_ref() == Some(&key) && !(animated && now >= s.next_tick) {
            return;
        }
        if animated && s.drawn.as_ref().is_some_and(|d| d.0 == want) {
            self.model.tick();
        }
        s.next_tick = now + TICK;
        let bars: Vec<f32> = self.model.bars.iter().copied().collect();
        let view = match (&want, &self.model.notice) {
            (Want::Recording, _) => View::Recording { bars: &bars },
            (Want::Processing, _) => View::Processing {
                phase: self.model.phase,
            },
            (Want::Notice, Some((kind, text, _))) => View::Notice { kind: *kind, text },
            (Want::Notice, None) => return,
        };
        let scale = s.scale.max(1);
        let (w, h) = (
            (draw::W as i32 * scale) as usize,
            (draw::H as i32 * scale) as usize,
        );
        let Ok((buffer, canvas)) =
            s.pool
                .create_buffer(w as i32, h as i32, (w * 4) as i32, wl_shm::Format::Argb8888)
        else {
            return;
        };
        let mut pixels = vec![0u8; w * h * 4];
        if let Some(mut pm) = tiny_skia::PixmapMut::from_bytes(&mut pixels, w as u32, h as u32) {
            draw::render(&mut pm, scale as f32, &s.pal, s.fonts.as_ref(), &view);
        }
        draw::to_argb8888(&pixels, canvas);
        let surface = s.layer.wl_surface();
        surface.set_buffer_scale(scale);
        surface.damage_buffer(0, 0, w as i32, h as i32);
        if buffer.attach_to(surface).is_ok() {
            s.layer.commit();
        }
        s.drawn = Some(key);
    }
}

impl CompositorHandler for Wl {
    fn scale_factor_changed(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_surface::WlSurface,
        new: i32,
    ) {
        if let Some(s) = self.surf.as_mut() {
            s.scale = new;
            s.drawn = None; // repaint at the new scale
        }
    }
    fn transform_changed(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_surface::WlSurface,
        _: wl_output::Transform,
    ) {
    }
    fn frame(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: u32) {}
    fn surface_enter(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_surface::WlSurface,
        _: &wl_output::WlOutput,
    ) {
    }
    fn surface_leave(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_surface::WlSurface,
        _: &wl_output::WlOutput,
    ) {
    }
}

impl OutputHandler for Wl {
    fn output_state(&mut self) -> &mut OutputState {
        &mut self.output
    }
    fn new_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
}

impl LayerShellHandler for Wl {
    fn closed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &LayerSurface) {
        // The compositor took the surface away; the next view creates a new one.
        self.surf = None;
    }
    fn configure(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &LayerSurface,
        _: LayerSurfaceConfigure,
        _: u32,
    ) {
        if let Some(s) = self.surf.as_mut() {
            s.configured = true;
            s.drawn = None;
        }
    }
}

impl ShmHandler for Wl {
    fn shm_state(&mut self) -> &mut Shm {
        &mut self.shm
    }
}

delegate_registry!(Wl);

impl ProvidesRegistryState for Wl {
    fn registry(&mut self) -> &mut RegistryState {
        &mut self.registry
    }
    registry_handlers![OutputState];
}

smithay_client_toolkit::delegate_dispatch2!(Wl);

/// Wait for the Wayland socket or the wake fd; `None` waits forever.
fn wait(
    guard: &smithay_client_toolkit::reexports::client::backend::ReadEventsGuard,
    wake: RawFd,
    timeout: Option<Duration>,
) -> (bool, bool) {
    let mut fds = [
        libc::pollfd {
            fd: guard.connection_fd().as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        },
        libc::pollfd {
            fd: wake,
            events: libc::POLLIN,
            revents: 0,
        },
    ];
    let ms = timeout.map_or(-1, |d| d.as_millis().min(i32::MAX as u128) as i32 + 1);
    unsafe { libc::poll(fds.as_mut_ptr(), 2, ms) };
    (
        fds[0].revents & libc::POLLIN != 0,
        fds[1].revents & libc::POLLIN != 0,
    )
}

fn run(
    _conn: Connection,
    mut queue: EventQueue<Wl>,
    mut wl: Wl,
    rx: mpsc::Receiver<Msg>,
    wake: RawFd,
) -> Result<(), String> {
    let qh = queue.handle();
    loop {
        let now = Instant::now();
        let want = wl.model.want(now);
        match (want, wl.surf.is_some()) {
            (Some(_), false) => {
                if let Err(e) = wl.show(&qh) {
                    eprintln!("overlay: {e}");
                    wl.model.notice = None;
                }
            }
            (None, true) => wl.surf = None, // dropping it destroys surface, pool and fonts
            _ => {}
        }
        if let Some(w) = want {
            wl.draw(w, now);
        }
        queue.dispatch_pending(&mut wl).map_err(|e| e.to_string())?;
        // A full socket buffer is not fatal: retry shortly instead of sleeping on it.
        let backed_up = match queue.flush() {
            Ok(()) => false,
            Err(WaylandError::Io(e)) if e.kind() == std::io::ErrorKind::WouldBlock => true,
            Err(e) => return Err(e.to_string()),
        };
        let Some(guard) = queue.prepare_read() else {
            continue;
        };
        // Sleep until the next frame or the notice's end; hidden means no deadline at all.
        let timeout = match (want, &wl.surf) {
            _ if backed_up => Some(Duration::from_millis(10)),
            (Some(Want::Notice), _) => wl
                .model
                .notice
                .as_ref()
                .map(|(_, _, u)| u.saturating_duration_since(now)),
            (Some(_), Some(s)) => Some(s.next_tick.saturating_duration_since(now)),
            _ => None,
        };
        let (wayland, woken) = wait(&guard, wake, timeout);
        if wayland {
            match guard.read() {
                Ok(_) => {}
                // The socket was readable but another reader got there first.
                Err(WaylandError::Io(e)) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(e) => return Err(e.to_string()),
            }
        } else {
            drop(guard);
        }
        if woken {
            let mut buf = [0u8; 8];
            unsafe { libc::read(wake, buf.as_mut_ptr().cast(), 8) };
        }
        let now = Instant::now();
        while let Ok(m) = rx.try_recv() {
            wl.model.apply(m, now);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn level() -> Arc<AtomicU32> {
        Arc::new(AtomicU32::new(0))
    }

    #[test]
    fn recording_beats_processing_beats_notice() {
        let t0 = Instant::now();
        let mut m = Model::default();
        assert_eq!(m.want(t0), None);
        m.apply(Msg::Notice(Kind::Info, "x".into()), t0);
        assert_eq!(m.want(t0), Some(Want::Notice));
        m.apply(Msg::JobQueued, t0);
        assert_eq!(m.want(t0), Some(Want::Processing));
        m.apply(Msg::RecStart(level()), t0);
        assert_eq!(m.want(t0), Some(Want::Recording));
        m.apply(Msg::RecEnd, t0);
        m.apply(Msg::JobDone, t0);
        assert_eq!(m.want(t0), Some(Want::Notice), "notice waited its turn");
    }

    #[test]
    fn notice_expires() {
        let t0 = Instant::now();
        let mut m = Model::default();
        m.apply(Msg::Notice(Kind::Error, "x".into()), t0);
        assert_eq!(
            m.want(t0 + NOTICE_FOR - Duration::from_millis(1)),
            Some(Want::Notice)
        );
        assert_eq!(m.want(t0 + NOTICE_FOR), None);
    }

    #[test]
    fn job_count_never_underflows() {
        let t0 = Instant::now();
        let mut m = Model::default();
        m.apply(Msg::JobDone, t0);
        m.apply(Msg::JobQueued, t0);
        m.apply(Msg::JobQueued, t0);
        m.apply(Msg::JobDone, t0);
        assert_eq!(m.want(t0), Some(Want::Processing));
    }

    #[test]
    fn bars_scroll_left_and_follow_level() {
        let t0 = Instant::now();
        let mut m = Model::default();
        let l = level();
        m.apply(Msg::RecStart(Arc::clone(&l)), t0);
        assert_eq!(m.bars.len(), BARS);
        l.store(0.3f32.to_bits(), Ordering::Relaxed);
        m.tick();
        m.tick();
        assert_eq!(m.bars.len(), BARS);
        assert!(m.bars[BARS - 1] > 0.0 && m.bars[BARS - 2] > 0.0 && m.bars[BARS - 3] == 0.0);
    }
}
