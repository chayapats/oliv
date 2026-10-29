//! Microphone capture through PipeWire, 16 kHz mono 16-bit (PipeWire converts).
//! The stream exists only while recording, so the mic is released on stop.
//! Each recording runs its own PipeWire main loop on a `capture` thread.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use pipewire as pw;
use pw::properties::properties;
use pw::spa;

pub const RATE: u32 = 16_000;
/// Recordings stop by themselves at 2 minutes.
pub const MAX_SAMPLES: usize = RATE as usize * 120;
/// The overlay's level meter updates ~24 times a second.
const LEVEL_WINDOW: usize = RATE as usize / 24;

/// Collects samples up to a cap and keeps a running RMS level.
pub struct Buf {
    pub samples: Vec<i16>,
    cap: usize,
    sum_sq: f64,
    n: usize,
    /// Last full window's RMS, 0.0..=1.0.
    pub level: f32,
}

impl Buf {
    pub fn new(cap: usize) -> Buf {
        Buf {
            samples: Vec::with_capacity(RATE as usize * 10),
            cap,
            sum_sq: 0.0,
            n: 0,
            level: 0.0,
        }
    }

    pub fn full(&self) -> bool {
        self.samples.len() >= self.cap
    }

    /// Append what fits. Returns true when this call filled the buffer.
    pub fn push(&mut self, new: &[i16]) -> bool {
        if self.full() {
            return false;
        }
        let take = new.len().min(self.cap - self.samples.len());
        for &s in &new[..take] {
            let x = f64::from(s) / 32768.0;
            self.sum_sq += x * x;
            self.n += 1;
            if self.n == LEVEL_WINDOW {
                self.level = (self.sum_sq / self.n as f64).sqrt() as f32;
                self.sum_sq = 0.0;
                self.n = 0;
            }
        }
        self.samples.extend_from_slice(&new[..take]);
        self.full()
    }
}

/// Little-endian 16-bit samples from raw bytes (a trailing odd byte is dropped).
pub fn samples_from_le(bytes: &[u8]) -> impl Iterator<Item = i16> + '_ {
    bytes
        .as_chunks::<2>()
        .0
        .iter()
        .map(|c| i16::from_le_bytes(*c))
}

pub struct Recording {
    stop: pw::channel::Sender<()>,
    thread: Option<JoinHandle<Vec<i16>>>,
    level: Arc<AtomicU32>,
    pub started: Instant,
}

impl Recording {
    /// Open the default source. `on_end` runs once for an automatic stop:
    /// None means the two-minute limit; Some contains the device error.
    pub fn start(on_end: Box<dyn FnOnce(Option<String>) + Send>) -> Result<Recording, String> {
        let started = Instant::now();
        let (stop_tx, stop_rx) = pw::channel::channel::<()>();
        let (ready_tx, ready_rx) = mpsc::sync_channel::<Result<(), String>>(1);
        let level = Arc::new(AtomicU32::new(0));
        let lv = Arc::clone(&level);
        let thread = std::thread::Builder::new()
            .name("capture".into())
            .spawn(move || match run(stop_rx, &ready_tx, lv, on_end) {
                Ok(s) => s,
                Err(e) => {
                    let _ = ready_tx.try_send(Err(e));
                    Vec::new()
                }
            })
            .map_err(|e| format!("capture thread: {e}"))?;
        match ready_rx.recv_timeout(Duration::from_secs(3)) {
            Ok(Ok(())) => Ok(Recording {
                stop: stop_tx,
                thread: Some(thread),
                level,
                started,
            }),
            Ok(Err(e)) => {
                let _ = thread.join();
                Err(e)
            }
            Err(_) => {
                let _ = stop_tx.send(());
                Err("pipewire did not answer".into())
            }
        }
    }

    /// The live level as shared bits of an `f32`, for the overlay to sample.
    pub fn level_handle(&self) -> Arc<AtomicU32> {
        Arc::clone(&self.level)
    }

    /// RMS of the last ~40 ms, 0.0..=1.0.
    pub fn level(&self) -> f32 {
        f32::from_bits(self.level.load(Ordering::Relaxed))
    }

    /// Close the stream (releasing the mic) and return what was recorded.
    pub fn stop(mut self) -> Vec<i16> {
        let _ = self.stop.send(());
        self.thread
            .take()
            .and_then(|t| t.join().ok())
            .unwrap_or_default()
    }
}

impl Drop for Recording {
    fn drop(&mut self) {
        if let Some(t) = self.thread.take() {
            let _ = self.stop.send(());
            let _ = t.join();
        }
    }
}

fn pw_err(e: pw::Error) -> String {
    format!("pipewire: {e}")
}

/// The capture thread: connect, report ready, run until told to stop.
fn run(
    stop_rx: pw::channel::Receiver<()>,
    ready: &mpsc::SyncSender<Result<(), String>>,
    level: Arc<AtomicU32>,
    on_end: Box<dyn FnOnce(Option<String>) + Send>,
) -> Result<Vec<i16>, String> {
    pw::init();
    let mainloop = pw::main_loop::MainLoopRc::new(None).map_err(pw_err)?;
    let context = pw::context::ContextRc::new(&mainloop, None).map_err(pw_err)?;
    let core = context.connect_rc(None).map_err(pw_err)?;
    let props = properties! {
        *pw::keys::MEDIA_TYPE => "Audio",
        *pw::keys::MEDIA_CATEGORY => "Capture",
        *pw::keys::MEDIA_ROLE => "Communication",
        *pw::keys::APP_NAME => "oliv",
        *pw::keys::NODE_NAME => "oliv",
    };
    let stream = pw::stream::StreamBox::new(&core, "oliv", props).map_err(pw_err)?;

    let buf = Rc::new(RefCell::new(Buf::new(MAX_SAMPLES)));
    let on_end = Rc::new(RefCell::new(Some(on_end)));
    let on_error = Rc::clone(&on_end);
    let b = Rc::clone(&buf);
    let ml = mainloop.clone();
    let _listener = stream
        .add_local_listener_with_user_data(())
        .state_changed(move |_, _, _, new| {
            if let pw::stream::StreamState::Error(e) = new {
                if let Some(f) = on_error.borrow_mut().take() {
                    f(Some(format!("pipewire: {e}")));
                }
                ml.quit();
            }
        })
        .process(move |stream, _| {
            let Some(mut buffer) = stream.dequeue_buffer() else {
                return;
            };
            let Some(data) = buffer.datas_mut().first_mut() else {
                return;
            };
            let (off, size) = (data.chunk().offset() as usize, data.chunk().size() as usize);
            let Some(bytes) = data.data() else { return };
            let Some(bytes) = bytes.get(off..off + size) else {
                return;
            };
            let chunk: Vec<i16> = samples_from_le(bytes).collect();
            let mut buf = b.borrow_mut();
            let filled = buf.push(&chunk);
            level.store(buf.level.to_bits(), Ordering::Relaxed);
            if filled && let Some(f) = on_end.borrow_mut().take() {
                f(None);
            }
        })
        .register()
        .map_err(pw_err)?;

    let mut info = spa::param::audio::AudioInfoRaw::new();
    info.set_format(spa::param::audio::AudioFormat::S16LE);
    info.set_rate(RATE);
    info.set_channels(1);
    let obj = spa::pod::Object {
        type_: spa::utils::SpaTypes::ObjectParamFormat.as_raw(),
        id: spa::param::ParamType::EnumFormat.as_raw(),
        properties: info.into(),
    };
    let pod = spa::pod::serialize::PodSerializer::serialize(
        std::io::Cursor::new(Vec::new()),
        &spa::pod::Value::Object(obj),
    )
    .map_err(|e| format!("pipewire format: {e:?}"))?
    .0
    .into_inner();
    let mut params = [spa::pod::Pod::from_bytes(&pod).ok_or("pipewire format pod")?];
    stream
        .connect(
            spa::utils::Direction::Input,
            None,
            pw::stream::StreamFlags::AUTOCONNECT | pw::stream::StreamFlags::MAP_BUFFERS,
            &mut params,
        )
        .map_err(pw_err)?;

    let ml = mainloop.clone();
    let _stop = stop_rx.attach(mainloop.loop_(), move |()| ml.quit());
    let _ = ready.send(Ok(()));
    mainloop.run();
    let _ = stream.disconnect();
    let samples = std::mem::take(&mut buf.borrow_mut().samples);
    Ok(samples)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cap_fills_once() {
        let mut b = Buf::new(10);
        assert!(!b.push(&[1; 6]));
        assert!(b.push(&[2; 6]));
        assert_eq!(b.samples.len(), 10);
        assert_eq!(&b.samples[4..], &[1, 1, 2, 2, 2, 2]);
        assert!(!b.push(&[3; 6]), "already full: no second signal");
        assert_eq!(b.samples.len(), 10);
    }

    #[test]
    fn two_minute_cap() {
        assert_eq!(MAX_SAMPLES, 1_920_000);
    }

    #[test]
    fn level_is_rms_per_window() {
        let mut b = Buf::new(MAX_SAMPLES);
        b.push(&vec![0; LEVEL_WINDOW]);
        assert_eq!(b.level, 0.0);
        b.push(&vec![16384; LEVEL_WINDOW - 1]);
        assert_eq!(b.level, 0.0, "window not complete yet");
        b.push(&[16384]);
        assert!((b.level - 0.5).abs() < 1e-6, "{}", b.level);
        // Full scale: RMS 1.0.
        b.push(&vec![i16::MIN; LEVEL_WINDOW]);
        assert!((b.level - 1.0).abs() < 1e-6);
    }

    #[test]
    fn le_samples() {
        let s: Vec<i16> = samples_from_le(&[1, 0, 0xff, 0xff, 0x00, 0x80, 7]).collect();
        assert_eq!(s, [1, -1, i16::MIN]);
    }
}
