//! Windows microphone capture through CPAL's native WASAPI backend.
//! The default input device is opened only during a recording; its native
//! format is downmixed and resampled into the existing 16 kHz mono PCM API.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

#[path = "audio.rs"]
mod audio;
use audio::Converter;
#[allow(unused_imports)]
pub use audio::{Buf, MAX_SAMPLES, RATE};

enum Event {
    Stop,
    Full,
    Error(String),
}

pub struct Recording {
    stop: mpsc::SyncSender<Event>,
    thread: Option<JoinHandle<Vec<i16>>>,
    level: Arc<AtomicU32>,
    pub started: Instant,
}

impl Recording {
    /// Open the default microphone. `on_end` runs once for an automatic stop:
    /// None means the two-minute limit; Some contains the device error.
    pub fn start(on_end: Box<dyn FnOnce(Option<String>) + Send>) -> Result<Recording, String> {
        let started = Instant::now();
        let (stop_tx, stop_rx) = mpsc::sync_channel(1);
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        let level = Arc::new(AtomicU32::new(0));
        let lv = Arc::clone(&level);
        let events = stop_tx.clone();
        let thread = std::thread::Builder::new()
            .name("capture".into())
            .spawn(move || match run(stop_rx, events, &ready_tx, lv, on_end) {
                Ok(samples) => samples,
                Err(error) => {
                    let _ = ready_tx.try_send(Err(error));
                    Vec::new()
                }
            })
            .map_err(|e| format!("capture thread: {e}"))?;
        match ready_rx.recv_timeout(Duration::from_secs(5)) {
            Ok(Ok(())) => Ok(Recording {
                stop: stop_tx,
                thread: Some(thread),
                level,
                started,
            }),
            Ok(Err(error)) => {
                let _ = thread.join();
                Err(error)
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                // Do not block the daemon if a device driver hangs while
                // opening. If it returns later, the queued stop closes it.
                let _ = stop_tx.try_send(Event::Stop);
                Err("Windows microphone did not respond within 5 seconds".into())
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                let _ = thread.join();
                Err("Windows microphone capture thread stopped during startup".into())
            }
        }
    }

    pub fn level_handle(&self) -> Arc<AtomicU32> {
        Arc::clone(&self.level)
    }

    pub fn level(&self) -> f32 {
        f32::from_bits(self.level.load(Ordering::Relaxed))
    }

    /// Release the microphone, then return the bounded 16 kHz mono PCM data.
    pub fn stop(mut self) -> Vec<i16> {
        let _ = self.stop.try_send(Event::Stop);
        self.thread
            .take()
            .and_then(|thread| thread.join().ok())
            .unwrap_or_default()
    }
}

impl Drop for Recording {
    fn drop(&mut self) {
        if let Some(thread) = self.thread.take() {
            let _ = self.stop.try_send(Event::Stop);
            let _ = thread.join();
        }
    }
}

fn run(
    stop: mpsc::Receiver<Event>,
    events: mpsc::SyncSender<Event>,
    ready: &mpsc::SyncSender<Result<(), String>>,
    level: Arc<AtomicU32>,
    on_end: Box<dyn FnOnce(Option<String>) + Send>,
) -> Result<Vec<i16>, String> {
    let host = cpal::default_host();
    let device = host.default_input_device().ok_or(
        "No Windows microphone found. Connect a microphone and enable microphone access in Settings.",
    )?;
    let supported = device
        .default_input_config()
        .map_err(|e| format!("Windows microphone format: {e}"))?;
    let format = supported.sample_format();
    let config = supported.config();
    // Validate before building the stream, rather than discovering an
    // unsupported type in a realtime callback.
    if !matches!(
        format,
        cpal::SampleFormat::I8
            | cpal::SampleFormat::I16
            | cpal::SampleFormat::I24
            | cpal::SampleFormat::I32
            | cpal::SampleFormat::I64
            | cpal::SampleFormat::U8
            | cpal::SampleFormat::U16
            | cpal::SampleFormat::U32
            | cpal::SampleFormat::U64
            | cpal::SampleFormat::F32
            | cpal::SampleFormat::F64
    ) {
        return Err(format!(
            "Unsupported Windows microphone sample format: {format}"
        ));
    }
    let audio = Arc::new(Mutex::new(Converter::new(
        config.sample_rate.0,
        usize::from(config.channels),
        MAX_SAMPLES,
    )?));
    let callback_audio = Arc::clone(&audio);
    let callback_events = events.clone();
    let stream = device
        .build_input_stream_raw(
            &config,
            format,
            move |data, _| {
                let Ok(mut audio) = callback_audio.lock() else {
                    let _ = callback_events.try_send(Event::Error("audio buffer poisoned".into()));
                    return;
                };
                let filled = match data.sample_format() {
                    cpal::SampleFormat::I8 => collect::<i8>(data, &mut audio),
                    cpal::SampleFormat::I16 => collect::<i16>(data, &mut audio),
                    cpal::SampleFormat::I24 => collect::<cpal::I24>(data, &mut audio),
                    cpal::SampleFormat::I32 => collect::<i32>(data, &mut audio),
                    cpal::SampleFormat::I64 => collect::<i64>(data, &mut audio),
                    cpal::SampleFormat::U8 => collect::<u8>(data, &mut audio),
                    cpal::SampleFormat::U16 => collect::<u16>(data, &mut audio),
                    cpal::SampleFormat::U32 => collect::<u32>(data, &mut audio),
                    cpal::SampleFormat::U64 => collect::<u64>(data, &mut audio),
                    cpal::SampleFormat::F32 => collect::<f32>(data, &mut audio),
                    cpal::SampleFormat::F64 => collect::<f64>(data, &mut audio),
                    _ => false,
                };
                level.store(audio.output.level.to_bits(), Ordering::Relaxed);
                if filled {
                    let _ = callback_events.try_send(Event::Full);
                }
            },
            move |error| {
                let _ = events.try_send(Event::Error(error.to_string()));
            },
            None,
        )
        .map_err(|e| format!("Open Windows microphone: {e}"))?;
    stream
        .play()
        .map_err(|e| format!("Start Windows microphone: {e}"))?;
    if ready.send(Ok(())).is_err() {
        // The startup caller timed out or was dropped.
        drop(stream);
        return Ok(Vec::new());
    }

    // This thread sleeps until a stop/error/cap event. The wall-clock deadline
    // also stops broken drivers that stop delivering audio callbacks.
    let event = stop.recv_timeout(Duration::from_secs(120));
    drop(stream); // CPAL joins its callback thread before we take the buffer.
    notify_completion(event, on_end);
    let mut audio = audio.lock().map_err(|_| "audio buffer poisoned")?;
    Ok(std::mem::take(&mut audio.output.samples))
}

fn notify_completion(
    event: Result<Event, mpsc::RecvTimeoutError>,
    on_end: Box<dyn FnOnce(Option<String>) + Send>,
) {
    match event {
        Ok(Event::Stop) | Err(mpsc::RecvTimeoutError::Disconnected) => {}
        Ok(Event::Full) | Err(mpsc::RecvTimeoutError::Timeout) => on_end(None),
        Ok(Event::Error(error)) => on_end(Some(error)),
    }
}

fn collect<T>(data: &cpal::Data, audio: &mut Converter) -> bool
where
    T: cpal::SizedSample,
    f32: cpal::FromSample<T>,
{
    data.as_slice::<T>()
        .is_some_and(|samples| collect_samples(samples, audio))
}

fn collect_samples<T>(samples: &[T], audio: &mut Converter) -> bool
where
    T: cpal::SizedSample,
    f32: cpal::FromSample<T>,
{
    audio.push(samples.iter().map(|sample| sample.to_sample::<f32>()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn automatic_completion_preserves_reason_and_explicit_stop_does_not_notify() {
        for (event, expected) in [
            (Ok(Event::Full), vec![None]),
            (Err(mpsc::RecvTimeoutError::Timeout), vec![None]),
            (
                Ok(Event::Error("device disconnected".into())),
                vec![Some("device disconnected".into())],
            ),
            (Ok(Event::Stop), vec![]),
            (Err(mpsc::RecvTimeoutError::Disconnected), vec![]),
        ] {
            let callbacks = Arc::new(Mutex::new(Vec::new()));
            let captured = Arc::clone(&callbacks);
            notify_completion(
                event,
                Box::new(move |error| captured.lock().unwrap().push(error)),
            );
            assert_eq!(*callbacks.lock().unwrap(), expected);
        }
    }

    #[test]
    fn every_supported_device_sample_type_converts_its_endpoints() {
        fn check<T>(samples: &[T], expected: &[i16])
        where
            T: cpal::SizedSample,
            f32: cpal::FromSample<T>,
        {
            let mut c = Converter::new(RATE, 1, samples.len()).unwrap();
            assert!(collect_samples(samples, &mut c));
            assert_eq!(c.output.samples, expected);
        }
        check(&[i8::MIN, 0, i8::MAX], &[i16::MIN, 0, 32512]);
        check(&[i16::MIN, 0, i16::MAX], &[i16::MIN, 0, i16::MAX]);
        check(
            &[
                cpal::I24::new(-8_388_608).unwrap(),
                cpal::I24::new(0).unwrap(),
                cpal::I24::new(8_388_607).unwrap(),
            ],
            &[i16::MIN, 0, i16::MAX],
        );
        check(&[i32::MIN, 0, i32::MAX], &[i16::MIN, 0, i16::MAX]);
        check(&[i64::MIN, 0, i64::MAX], &[i16::MIN, 0, i16::MAX]);
        check(&[u8::MIN, 128, u8::MAX], &[i16::MIN, 0, 32512]);
        check(&[u16::MIN, 32768, u16::MAX], &[i16::MIN, 0, i16::MAX]);
        check(&[u32::MIN, 1 << 31, u32::MAX], &[i16::MIN, 0, i16::MAX]);
        check(&[u64::MIN, 1 << 63, u64::MAX], &[i16::MIN, 0, i16::MAX]);
        check(
            &[-1.0f32, 0.0, 1.0, f32::NAN, f32::INFINITY],
            &[i16::MIN, 0, i16::MAX, 0, 0],
        );
        check(
            &[-1.0f64, 0.0, 1.0, f64::NAN, f64::NEG_INFINITY],
            &[i16::MIN, 0, i16::MAX, 0, 0],
        );
    }

    #[test]
    fn wasapi_probe_and_missing_microphone_error_do_not_record_audio() {
        let host = cpal::default_host();
        assert_eq!(host.id(), cpal::HostId::Wasapi);
        if let Some(device) = host.default_input_device() {
            // Query only. Tests never open a real microphone on a developer's PC.
            match device.default_input_config() {
                Ok(config) => {
                    assert!(config.channels() > 0 && config.sample_rate().0 > 0);
                    eprintln!(
                        "WASAPI default input format available; live capture intentionally not tested"
                    );
                }
                Err(error) => eprintln!("WASAPI default input format unavailable: {error}"),
            }
        } else {
            for _ in 0..3 {
                match Recording::start(Box::new(|_| panic!("no input device cannot reach the cap")))
                {
                    Ok(_) => panic!("a microphone appeared during the missing-device test"),
                    Err(error) => assert!(error.contains("No Windows microphone found"), "{error}"),
                }
            }
        }
    }
}
