//! `oliv daemon`: owns the mic and the paste. It blocks on its unix socket
//! while idle (no timers, no polling). Commands run one at a time on the main
//! thread; finished recordings queue up for a single worker thread, so only one
//! request is ever in flight and pastes land in the order they were spoken.

use std::io::{BufRead, BufReader, Read, Write};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::api::{self, Action};
use crate::capture::{RATE, Recording};
use crate::ipc::Command;
use crate::notify::{alert, notify};
use crate::store::{self, Stamp};
use crate::transport::{self, Listener, Stream};
use crate::{config, overlay, paste, wav};

/// Presses shorter than this are dropped without a word.
pub const MIN_HOLD: Duration = Duration::from_millis(300);
/// A long enough press that captured less than this means the mic gave nothing.
const MIN_SAMPLES: usize = RATE as usize / 10;
const COMMAND_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug, PartialEq)]
pub enum Verdict {
    /// Too short a press: drop quietly.
    Drop,
    /// The mic produced (almost) nothing.
    Silent,
    Send,
}

pub fn verdict(held: Duration, samples: usize) -> Verdict {
    if held < MIN_HOLD {
        Verdict::Drop
    } else if samples < MIN_SAMPLES {
        Verdict::Silent
    } else {
        Verdict::Send
    }
}

enum Event {
    Cmd(Command, mpsc::Sender<Value>),
    /// Capture ended automatically: None is the cap, Some is a device error.
    CaptureEnded(u64, Option<String>),
}

struct Job {
    wav: Vec<u8>,
    stamp: Stamp,
}

fn read_command(reader: &mut impl BufRead) -> std::io::Result<Option<Command>> {
    let mut line = String::new();
    // A truncated valid prefix is not a command. Require the terminating newline.
    reader.take(256).read_line(&mut line)?;
    Ok(line
        .ends_with('\n')
        .then(|| Command::parse(&line))
        .flatten())
}

/// Keep one deadline across buffered reads: trickled bytes must not restart it.
struct DeadlineReader<'a> {
    stream: &'a mut Stream,
    deadline: Instant,
}

impl Read for DeadlineReader<'_> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let timeout = self.deadline.saturating_duration_since(Instant::now());
        let expired =
            || std::io::Error::new(std::io::ErrorKind::TimedOut, "oliv command read timed out");
        if timeout.is_zero() {
            return Err(expired());
        }
        self.stream.set_read_timeout(Some(timeout))?;
        self.stream.read(buf).map_err(|error| match error.kind() {
            // Unix sockets report a read timeout as WouldBlock; named pipes
            // report TimedOut. Both have the same protocol meaning here.
            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut => expired(),
            _ => error,
        })
    }
}

fn serve_conn(mut conn: Stream, events: &mpsc::Sender<Event>) -> std::io::Result<()> {
    conn.set_write_timeout(Some(Duration::from_secs(2)))?;
    let mut reader = BufReader::new(DeadlineReader {
        stream: &mut conn,
        deadline: Instant::now() + COMMAND_TIMEOUT,
    });
    let reply = match read_command(&mut reader)? {
        None => json!({"ok": false, "error": "unknown command"}),
        Some(cmd) => {
            let (tx, rx) = mpsc::channel();
            let _ = events.send(Event::Cmd(cmd, tx));
            rx.recv_timeout(Duration::from_secs(5))
                .unwrap_or_else(|_| json!({"ok": false, "error": "daemon busy"}))
        }
    };
    writeln!(reader.get_mut().stream, "{reply}")?;
    // Keep the Windows pipe alive until its buffered reply has been consumed.
    #[cfg(windows)]
    {
        reader.get_mut().deadline = Instant::now() + COMMAND_TIMEOUT;
        reader.read_exact(&mut [0u8])?;
    }
    Ok(())
}

fn accept_loop(listener: Listener, events: mpsc::Sender<Event>) {
    for conn in listener.incoming() {
        match conn {
            Ok(c) => {
                if let Err(e) = serve_conn(c, &events) {
                    eprintln!("socket: {e}");
                }
            }
            Err(e) => eprintln!("accept: {e}"),
        }
    }
}

/// Where the daemon's stderr ends up: the user journal (systemd) on Linux,
/// `daemon.stderr.log` (install-client.ps1) on Windows.
#[cfg(windows)]
const CONFIG_NOTICE: &str = "config ใช้ไม่ได้ เก็บเสียงแล้ว ตรวจ daemon.stderr.log";
#[cfg(not(windows))]
const CONFIG_NOTICE: &str = "config ใช้ไม่ได้ เก็บเสียงแล้ว ตรวจ journal";

/// Keep a WAV the server did not turn into text, and say so.
fn keep(job: &Job, why: &str, notice: &str) {
    eprintln!("{} dictate failed: {why}", job.stamp.iso());
    match store::save_pending(&job.wav, &job.stamp) {
        Ok(p) => {
            eprintln!("kept {}", p.display());
            alert(notice);
        }
        Err(e) => {
            eprintln!("could not keep the audio: {e}");
            alert("ส่งไม่สำเร็จ และเก็บเสียงไม่ได้");
        }
    }
}

fn work(job: Job) {
    let audio_s = wav::seconds(&job.wav);
    let cfg = match config::load() {
        Ok(c) => c,
        Err(e) => return keep(&job, &e, CONFIG_NOTICE),
    };
    let (res, t_total) = api::dictate_locked(&cfg, &job.wav);
    let reply = match res {
        Ok(r) => r,
        Err(e) => return keep(&job, &e, e.notice),
    };
    let pasted = match api::action(&reply) {
        Action::Paste(text) => match paste::paste(text) {
            Ok(()) => true,
            Err(e) => {
                eprintln!("paste: {e}");
                alert("วางข้อความไม่สำเร็จ ดูได้ด้วย oliv last");
                false
            }
        },
        Action::Notice(msg) => {
            notify(msg);
            false
        }
    };
    // Timings only: transcripts stay out of the journal.
    eprintln!(
        "{} audio={audio_s:.1}s total={t_total:.2}s stt={:.2}s cleanup={:.2}s redecoded={} gate={} no_speech={} pasted={pasted}",
        job.stamp.iso(),
        reply.t_stt,
        reply.t_cleanup,
        reply.stt_redecoded,
        reply.gate_reason,
        reply.no_speech,
    );
    let entry = api::history_entry(
        &job.stamp.iso(),
        "dictate",
        audio_s,
        &reply,
        t_total,
        pasted,
    );
    if let Err(e) = store::append_history(&entry) {
        eprintln!("history: {e}");
    }
}

fn spawn_worker(queued: Arc<AtomicUsize>) -> Result<mpsc::Sender<Job>, String> {
    let (tx, rx) = mpsc::channel::<Job>();
    std::thread::Builder::new()
        .name("worker".into())
        .spawn(move || {
            for job in rx {
                // A panic in one job must not take the queue (and later recordings) with it.
                let stamp = job.stamp.iso();
                if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| work(job))).is_err() {
                    eprintln!("{stamp} worker panicked on this recording");
                }
                overlay::job_done();
                queued.fetch_sub(1, Ordering::SeqCst);
            }
        })
        .map_err(|e| format!("worker thread: {e}"))?;
    Ok(tx)
}

struct Daemon {
    events: mpsc::Sender<Event>,
    jobs: mpsc::Sender<Job>,
    queued: Arc<AtomicUsize>,
    rec: Option<(u64, Recording)>,
    next_id: u64,
}

impl Daemon {
    fn start(&mut self) -> Value {
        if self.rec.is_some() {
            return json!({"ok": false, "error": "already recording"});
        }
        let id = self.next_id;
        self.next_id += 1;
        let events = self.events.clone();
        match Recording::start(Box::new(move |error| {
            let _ = events.send(Event::CaptureEnded(id, error));
        })) {
            Ok(r) => {
                overlay::rec_start(r.level_handle());
                self.rec = Some((id, r));
                json!({"ok": true})
            }
            Err(e) => {
                eprintln!("capture: {e}");
                alert("เปิดไมค์ไม่ได้");
                json!({"ok": false, "error": e})
            }
        }
    }

    /// Stop recording and queue it, unless the press was too short.
    fn stop(&mut self) -> Value {
        let Some((_, rec)) = self.rec.take() else {
            return json!({"ok": true, "result": "not_recording"});
        };
        let held = rec.started.elapsed();
        let samples = rec.stop();
        let verdict = verdict(held, samples.len());
        // Queue first, so the overlay goes from recording straight to processing.
        if verdict == Verdict::Send {
            overlay::job_queued();
        }
        overlay::rec_end();
        let result = match verdict {
            Verdict::Drop => "too_short",
            Verdict::Silent => {
                notify(api::NO_SPEECH);
                "silent"
            }
            Verdict::Send => {
                self.queued.fetch_add(1, Ordering::SeqCst);
                let job = Job {
                    wav: wav::encode(&samples, RATE),
                    stamp: Stamp::now(),
                };
                if let Err(mpsc::SendError(job)) = self.jobs.send(job) {
                    self.queued.fetch_sub(1, Ordering::SeqCst);
                    overlay::job_done();
                    keep(
                        &job,
                        "worker is gone",
                        "ส่งไม่สำเร็จ เก็บเสียงแล้ว ลอง oliv retry",
                    );
                    return json!({"ok": false, "error": "worker is gone"});
                }
                "queued"
            }
        };
        json!({"ok": true, "result": result, "held_s": held.as_secs_f64()})
    }

    fn cancel(&mut self) -> Value {
        match self.rec.take() {
            Some((_, rec)) => {
                drop(rec.stop());
                overlay::rec_end();
                notify("ยกเลิกแล้ว");
                json!({"ok": true, "result": "cancelled"})
            }
            None => json!({"ok": true, "result": "not_recording"}),
        }
    }

    fn status(&self) -> Value {
        let queued = self.queued.load(Ordering::SeqCst);
        match &self.rec {
            Some((_, r)) => json!({
                "ok": true,
                "state": "recording",
                "recording_s": r.started.elapsed().as_secs_f64(),
                "level": r.level(),
                "queued": queued,
            }),
            None => json!({"ok": true, "state": "idle", "queued": queued}),
        }
    }
}

pub fn run() -> Result<(), String> {
    config::load()?;
    let listener = transport::bind()?;
    if let Err(e) = overlay::spawn() {
        eprintln!("overlay unavailable: {e}");
    }
    let queued = Arc::new(AtomicUsize::new(0));
    let jobs = spawn_worker(Arc::clone(&queued))?;
    let (events, rx) = mpsc::channel();
    #[cfg(windows)]
    {
        let hotkey_events = events.clone();
        crate::hotkey::spawn(move |cmd| {
            let (reply, _) = mpsc::channel();
            let _ = hotkey_events.send(Event::Cmd(cmd, reply));
        })?;
    }
    let ev = events.clone();
    std::thread::Builder::new()
        .name("socket".into())
        .spawn(move || accept_loop(listener, ev))
        .map_err(|e| format!("socket thread: {e}"))?;
    eprintln!(
        "oliv {} daemon on {}",
        env!("CARGO_PKG_VERSION"),
        store::socket_path()?.display()
    );
    let mut d = Daemon {
        events,
        jobs,
        queued,
        rec: None,
        next_id: 0,
    };
    for ev in rx {
        match ev {
            Event::Cmd(cmd, reply) => {
                let v = match cmd {
                    Command::Start => d.start(),
                    Command::Stop => d.stop(),
                    Command::Cancel => d.cancel(),
                    Command::Status => d.status(),
                };
                let _ = reply.send(v);
            }
            Event::CaptureEnded(id, error) if d.rec.as_ref().is_some_and(|(n, _)| *n == id) => {
                if let Some(error) = &error {
                    eprintln!("capture stopped after microphone error: {error}");
                } else {
                    eprintln!("recording hit the 2-minute cap, sending");
                }
                d.stop();
                if error.is_some() {
                    alert("ไมโครโฟนขัดข้อง กรุณาตรวจสอบไมค์แล้วลองอีกครั้ง");
                }
            }
            Event::CaptureEnded(_, _) => {}
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn accept_test_client(listener: &mut Listener) -> std::io::Result<Stream> {
        #[cfg(windows)]
        {
            listener
                .accept(Some(Duration::from_secs(5)))
                .expect("test listener remains open")
        }
        #[cfg(unix)]
        {
            listener.set_nonblocking(true)?;
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                match listener.accept() {
                    Ok((stream, _)) => return Ok(stream),
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        if Instant::now() >= deadline {
                            return Err(std::io::Error::new(
                                std::io::ErrorKind::TimedOut,
                                "test accept timed out",
                            ));
                        }
                        std::thread::sleep(Duration::from_millis(5));
                    }
                    Err(error) => return Err(error),
                }
            }
        }
    }

    #[test]
    fn slow_command_has_one_deadline_and_next_client_recovers() {
        let unique = format!(
            "oliv-command-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        #[cfg(windows)]
        let path = std::path::PathBuf::from(format!(r"\\.\pipe\{unique}"));
        #[cfg(unix)]
        let path = std::env::temp_dir().join(unique);
        #[cfg(windows)]
        let mut listener = Listener::bind_at(path.clone()).unwrap();
        #[cfg(unix)]
        let mut listener = Listener::bind(&path).unwrap();
        let (events, received) = mpsc::channel();
        let responder = std::thread::spawn(move || {
            match received.recv_timeout(Duration::from_secs(5)).unwrap() {
                Event::Cmd(Command::Status, reply) => {
                    reply.send(json!({"ok": true, "state": "idle"})).unwrap();
                }
                _ => panic!("only the subsequent complete status may execute"),
            }
        });
        let (timed_out, observed_timeout) = mpsc::channel();
        let server = std::thread::spawn(move || {
            let slow = accept_test_client(&mut listener).unwrap();
            let started = Instant::now();
            let error = serve_conn(slow, &events).unwrap_err();
            assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
            assert!(started.elapsed() >= Duration::from_millis(1800));
            assert!(started.elapsed() < Duration::from_secs(3));
            timed_out.send(()).unwrap();
            let healthy = accept_test_client(&mut listener).unwrap();
            serve_conn(healthy, &events).unwrap();
        });
        let mut slow = Stream::connect(&path).unwrap();
        slow.set_write_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        let sender = std::thread::spawn(move || {
            for byte in b"status\n" {
                if slow.write_all(&[*byte]).is_err() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(500));
            }
        });
        observed_timeout
            .recv_timeout(Duration::from_secs(4))
            .unwrap();
        let mut healthy = Stream::connect(&path).unwrap();
        healthy
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        healthy
            .set_write_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        healthy.write_all(b"status\n").unwrap();
        let mut response = String::new();
        BufReader::new(&mut healthy)
            .read_line(&mut response)
            .unwrap();
        #[cfg(windows)]
        healthy.write_all(&[1]).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&response).unwrap(),
            json!({"ok": true, "state": "idle"})
        );
        server.join().unwrap();
        sender.join().unwrap();
        responder.join().unwrap();
        #[cfg(unix)]
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn command_requires_a_complete_bounded_line() {
        for text in ["status\n", "status\r\n"] {
            assert_eq!(
                read_command(&mut text.as_bytes()).unwrap(),
                Some(Command::Status)
            );
        }
        for text in [
            "status".to_string(),
            format!("start{}\n", " ".repeat(300)),
            "bogus\n".into(),
            "\n".into(),
        ] {
            assert_eq!(read_command(&mut text.as_bytes()).unwrap(), None);
        }
        assert!(read_command(&mut &b"\xff\n"[..]).is_err());
        let mut buffered = BufReader::new(&b"status\n\x01"[..]);
        assert_eq!(read_command(&mut buffered).unwrap(), Some(Command::Status));
        let mut ack = [0];
        buffered.read_exact(&mut ack).unwrap();
        assert_eq!(ack, [1]);
    }

    #[test]
    fn short_presses_drop() {
        let ok = MIN_SAMPLES;
        assert_eq!(verdict(Duration::from_millis(0), ok), Verdict::Drop);
        assert_eq!(verdict(Duration::from_millis(299), ok * 10), Verdict::Drop);
        assert_eq!(verdict(Duration::from_millis(300), ok), Verdict::Send);
        assert_eq!(verdict(Duration::from_secs(120), ok * 1000), Verdict::Send);
    }

    #[test]
    fn empty_capture_is_silent() {
        assert_eq!(verdict(Duration::from_secs(2), 0), Verdict::Silent);
        assert_eq!(
            verdict(Duration::from_secs(2), MIN_SAMPLES - 1),
            Verdict::Silent
        );
    }
}
