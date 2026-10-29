//! Local, user-restricted Windows named pipes. Overlapped I/O supplies bounded
//! reads/writes; waiting for the next command consumes no CPU.
use std::cell::Cell;
use std::io::{self, Read, Write};
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{
    ERROR_BROKEN_PIPE, ERROR_IO_PENDING, ERROR_PIPE_BUSY, ERROR_PIPE_CONNECTED, ERROR_SEM_TIMEOUT,
    GENERIC_READ, GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_FLAG_OVERLAPPED, OPEN_EXISTING,
    PIPE_ACCESS_DUPLEX, ReadFile, SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT, WriteFile,
};
use windows_sys::Win32::System::IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED};
use windows_sys::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_WAIT,
    WaitNamedPipeW,
};
use windows_sys::Win32::System::Threading::{CreateEventW, INFINITE, WaitForSingleObject};

use crate::security::{Descriptor, user_sid, wide};

pub fn pipe_path() -> Result<PathBuf, String> {
    Ok(PathBuf::from(format!(
        r"\\.\pipe\oliv-{}",
        user_sid().map_err(|e| e.to_string())?
    )))
}

fn owned(raw: HANDLE) -> io::Result<OwnedHandle> {
    if raw.is_null() || raw == INVALID_HANDLE_VALUE {
        Err(io::Error::last_os_error())
    } else {
        // SAFETY: the Win32 caller returned a new uniquely owned handle.
        Ok(unsafe { OwnedHandle::from_raw_handle(raw) })
    }
}

/// The OVERLAPPED and caller's buffer outlive completion, even on timeout.
fn operation(
    handle: HANDLE,
    timeout: Option<Duration>,
    start: impl FnOnce(*mut OVERLAPPED, *mut u32) -> i32,
) -> io::Result<usize> {
    let event = owned(unsafe { CreateEventW(null(), 1, 0, null()) })?;
    let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
    overlapped.hEvent = event.as_raw_handle();
    let mut bytes = 0;
    if start(&mut overlapped, &mut bytes) != 0 {
        return Ok(bytes as usize);
    } else {
        let error = io::Error::last_os_error();
        match error.raw_os_error().map(|n| n as u32) {
            Some(ERROR_PIPE_CONNECTED) => return Ok(0),
            Some(ERROR_BROKEN_PIPE) => return Ok(0),
            Some(ERROR_IO_PENDING) => {}
            _ => return Err(error),
        }
    }
    let ms = timeout.map_or(INFINITE, |d| {
        d.as_millis().min(u128::from(INFINITE - 1)) as u32
    });
    let wait = unsafe { WaitForSingleObject(event.as_raw_handle(), ms) };
    if wait != WAIT_OBJECT_0 {
        let error = if wait == WAIT_TIMEOUT {
            io::Error::new(io::ErrorKind::TimedOut, "oliv pipe timed out")
        } else {
            io::Error::last_os_error()
        };
        // Cancellation itself is asynchronous: wait before releasing memory.
        unsafe {
            CancelIoEx(handle, &overlapped);
            GetOverlappedResult(handle, &overlapped, &mut bytes, 1);
        }
        return Err(error);
    }
    if unsafe { GetOverlappedResult(handle, &overlapped, &mut bytes, 0) } == 0 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(ERROR_BROKEN_PIPE as i32) {
            return Ok(0);
        }
        return Err(error);
    }
    Ok(bytes as usize)
}

pub struct Stream {
    handle: OwnedHandle,
    read_timeout: Cell<Option<Duration>>,
    write_timeout: Cell<Option<Duration>>,
}

impl Stream {
    fn new(handle: OwnedHandle) -> Self {
        Self {
            handle,
            read_timeout: Cell::new(Some(Duration::from_secs(8))),
            write_timeout: Cell::new(Some(Duration::from_secs(5))),
        }
    }

    pub fn connect(path: &Path) -> io::Result<Self> {
        Self::connect_timeout(path, Duration::from_secs(5))
    }

    fn connect_timeout(path: &Path, timeout: Duration) -> io::Result<Self> {
        let deadline = Instant::now() + timeout;
        let path = wide(path.as_os_str());
        let open = || unsafe {
            CreateFileW(
                path.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                0,
                null(),
                OPEN_EXISTING,
                // The server needs command bytes, never the client's token.
                FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                null_mut(),
            )
        };
        let timed_out =
            || io::Error::new(io::ErrorKind::TimedOut, "oliv pipe connection timed out");
        loop {
            match owned(open()) {
                Ok(handle) => return Ok(Self::new(handle)),
                Err(e) if e.raw_os_error() == Some(ERROR_PIPE_BUSY as i32) => {
                    let remaining = deadline.saturating_duration_since(Instant::now());
                    if remaining.is_zero() {
                        return Err(timed_out());
                    }
                    // Zero has special default-timeout semantics to Win32;
                    // round a remaining fractional millisecond up to one.
                    let ms = remaining.as_millis().clamp(1, u128::from(INFINITE - 1)) as u32;
                    if unsafe { WaitNamedPipeW(path.as_ptr(), ms) } == 0 {
                        let error = io::Error::last_os_error();
                        return Err(if error.raw_os_error() == Some(ERROR_SEM_TIMEOUT as i32) {
                            timed_out()
                        } else {
                            error
                        });
                    }
                    // Another client can claim this instance before CreateFile
                    // opens it. Retry within the same overall deadline.
                }
                Err(e) => return Err(e),
            }
        }
    }

    pub fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.read_timeout.set(timeout);
        Ok(())
    }

    pub fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.write_timeout.set(timeout);
        Ok(())
    }
}

impl Read for Stream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let handle = self.handle.as_raw_handle();
        operation(
            handle,
            self.read_timeout.get(),
            |overlapped, bytes| unsafe {
                ReadFile(
                    handle,
                    buf.as_mut_ptr(),
                    buf.len().min(u32::MAX as usize) as u32,
                    bytes,
                    overlapped,
                )
            },
        )
    }
}

impl Write for Stream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let handle = self.handle.as_raw_handle();
        operation(
            handle,
            self.write_timeout.get(),
            |overlapped, bytes| unsafe {
                WriteFile(
                    handle,
                    buf.as_ptr(),
                    buf.len().min(u32::MAX as usize) as u32,
                    bytes,
                    overlapped,
                )
            },
        )
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

pub struct Listener {
    path: PathBuf,
    next: Option<Stream>,
}

fn create(path: &Path, first: bool) -> io::Result<Stream> {
    let descriptor = Descriptor::current_user()?;
    let attrs = descriptor.attributes();
    let path = wide(path.as_os_str());
    owned(unsafe {
        CreateNamedPipeW(
            path.as_ptr(),
            PIPE_ACCESS_DUPLEX
                | FILE_FLAG_OVERLAPPED
                | if first {
                    FILE_FLAG_FIRST_PIPE_INSTANCE
                } else {
                    0
                },
            PIPE_TYPE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            8,
            4096,
            4096,
            5000,
            &attrs,
        )
    })
    .map(Stream::new)
}

impl Listener {
    pub(crate) fn bind_at(path: PathBuf) -> io::Result<Self> {
        let next = Some(create(&path, true)?);
        Ok(Self { path, next })
    }

    pub fn incoming(self) -> Self {
        self
    }
}

impl Iterator for Listener {
    type Item = io::Result<Stream>;

    fn next(&mut self) -> Option<Self::Item> {
        self.accept(None)
    }
}

impl Listener {
    pub(crate) fn accept(&mut self, timeout: Option<Duration>) -> Option<io::Result<Stream>> {
        let stream = self.next.take()?;
        let result = operation(
            stream.handle.as_raw_handle(),
            timeout,
            |overlapped, _| unsafe { ConnectNamedPipe(stream.handle.as_raw_handle(), overlapped) },
        );
        // Reserve the next instance before releasing the connected one, so no
        // other daemon can claim this pipe between commands.
        match create(&self.path, false) {
            Ok(next) => self.next = Some(next),
            Err(e) => return Some(Err(e)),
        }
        Some(result.map(|_| stream))
    }
}

pub fn bind() -> Result<Listener, String> {
    Listener::bind_at(pipe_path()?)
        .map_err(|e| format!("cannot bind oliv pipe (is another daemon running?): {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn unique_path() -> PathBuf {
        static ID: AtomicU64 = AtomicU64::new(0);
        PathBuf::from(format!(
            r"\\.\pipe\oliv-test-{}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            ID.fetch_add(1, Ordering::Relaxed)
        ))
    }

    fn pair() -> (Stream, Stream, Listener) {
        let path = unique_path();
        let mut listener = Listener::bind_at(path.clone()).unwrap();
        let client = Stream::connect(&path).unwrap();
        let server = listener
            .accept(Some(Duration::from_secs(5)))
            .unwrap()
            .unwrap();
        (server, client, listener)
    }

    #[test]
    fn native_pipe_round_trip_and_single_instance() {
        let path = unique_path();
        let listener = Listener::bind_at(path.clone()).unwrap();
        assert!(Listener::bind_at(path.clone()).is_err());
        let worker = std::thread::spawn(move || {
            let mut conn = listener.incoming().next().unwrap().unwrap();
            let mut line = String::new();
            BufReader::new(&mut conn).read_line(&mut line).unwrap();
            assert_eq!(line, "status\n");
            conn.write_all("สวัสดี\n".as_bytes()).unwrap();
            conn.read_exact(&mut [0]).unwrap();
        });
        let mut conn = Stream::connect(&path).unwrap();
        conn.write_all(b"status\n").unwrap();
        let mut line = String::new();
        BufReader::new(&mut conn).read_line(&mut line).unwrap();
        assert_eq!(line, "สวัสดี\n");
        conn.write_all(&[1]).unwrap();
        worker.join().unwrap();
    }

    #[test]
    fn native_pipe_read_deadline_cancels_io() {
        let path = unique_path();
        let listener = Listener::bind_at(path.clone()).unwrap();
        let worker = std::thread::spawn(move || {
            let mut conn = listener.incoming().next().unwrap().unwrap();
            conn.set_read_timeout(Some(Duration::from_millis(30)))
                .unwrap();
            assert_eq!(
                conn.read(&mut [0]).unwrap_err().kind(),
                io::ErrorKind::TimedOut
            );
        });
        let _conn = Stream::connect(&path).unwrap();
        worker.join().unwrap();
    }

    #[test]
    fn native_pipe_busy_connection_has_a_deadline() {
        let path = unique_path();
        let _listener = Listener::bind_at(path.clone()).unwrap();
        // Occupy the only instance before the listener begins accepting.
        let _first = Stream::connect(&path).unwrap();
        let started = Instant::now();
        let error = match Stream::connect_timeout(&path, Duration::from_millis(30)) {
            Ok(_) => panic!("the sole pipe instance was already occupied"),
            Err(error) => error,
        };
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn native_pipe_read_cancellation_allows_subsequent_io_and_peer_close() {
        let (mut server, mut client, _listener) = pair();
        server
            .set_read_timeout(Some(Duration::from_millis(30)))
            .unwrap();
        assert_eq!(
            server.read(&mut [0]).unwrap_err().kind(),
            io::ErrorKind::TimedOut
        );
        client.write_all(b"after timeout").unwrap();
        let mut bytes = [0; 13];
        server.read_exact(&mut bytes).unwrap();
        assert_eq!(&bytes, b"after timeout");
        assert_eq!(server.read(&mut []).unwrap(), 0);
        assert_eq!(server.write(&[]).unwrap(), 0);
        drop(client);
        assert_eq!(server.read(&mut [0]).unwrap(), 0);
        assert!(server.write_all(b"closed").is_err());
    }

    #[test]
    fn native_pipe_blocked_write_is_cancelled_before_its_buffer_is_reused() {
        let (mut server, _client, _listener) = pair();
        server
            .set_write_timeout(Some(Duration::from_millis(30)))
            .unwrap();
        // Exceeds the 4 KiB pipe buffer; the peer deliberately does not read.
        let mut payload = vec![0x5a; 1024 * 1024];
        assert_eq!(
            server.write(&payload).unwrap_err().kind(),
            io::ErrorKind::TimedOut
        );
        // This is safe only if cancellation waited for completion of the I/O.
        payload.fill(0);
    }

    #[test]
    fn native_pipe_accept_cancellation_retains_reservation_and_recovers() {
        let path = unique_path();
        let mut listener = Listener::bind_at(path.clone()).unwrap();
        let error = match listener.accept(Some(Duration::from_millis(30))).unwrap() {
            Ok(_) => panic!("no client connected"),
            Err(error) => error,
        };
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(Listener::bind_at(path.clone()).is_err());
        let mut client = Stream::connect(&path).unwrap();
        client.write_all(b"ok").unwrap();
        let mut server = listener
            .accept(Some(Duration::from_secs(5)))
            .unwrap()
            .unwrap();
        let mut bytes = [0; 2];
        server.read_exact(&mut bytes).unwrap();
        assert_eq!(&bytes, b"ok");
        drop(server);
        drop(client);
        assert!(Listener::bind_at(path.clone()).is_err());
        drop(listener);
        assert!(Listener::bind_at(path).is_ok());
    }

    #[test]
    fn native_pipe_concurrent_clients_preserve_buffered_input_and_replies() {
        const CLIENTS: usize = 16;
        let path = unique_path();
        let mut listener = Listener::bind_at(path.clone()).unwrap();
        let worker = std::thread::spawn(move || {
            for _ in 0..CLIENTS {
                let conn = listener
                    .accept(Some(Duration::from_secs(10)))
                    .unwrap()
                    .unwrap();
                let mut reader = BufReader::new(conn);
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                // Clients pipeline an extra control byte with the line;
                // retain the reader so its buffered input is not discarded.
                reader.read_exact(&mut [0]).unwrap();
                reader.get_mut().write_all(line.as_bytes()).unwrap();
                // A separate ACK proves the reply was consumed before close.
                reader.read_exact(&mut [0]).unwrap();
            }
        });
        let clients: Vec<_> = (0..CLIENTS)
            .map(|i| {
                let path = path.clone();
                std::thread::spawn(move || {
                    let mut client = Stream::connect(&path).unwrap();
                    let expected = format!("synthetic-{i}-ไทย\n");
                    client
                        .write_all(format!("{expected}\x01").as_bytes())
                        .unwrap();
                    let mut line = String::new();
                    BufReader::new(&mut client).read_line(&mut line).unwrap();
                    assert_eq!(line, expected);
                    client.write_all(&[1]).unwrap();
                })
            })
            .collect();
        for client in clients {
            client.join().unwrap();
        }
        worker.join().unwrap();
    }

    #[test]
    fn native_pipe_acl_and_client_impersonation_level_are_restricted() {
        use windows_sys::Win32::Security::{
            GetTokenInformation, RevertToSelf, SecurityIdentification, TOKEN_QUERY,
            TokenImpersonationLevel,
        };
        use windows_sys::Win32::System::Pipes::ImpersonateNamedPipeClient;
        use windows_sys::Win32::System::Threading::{GetCurrentThread, OpenThreadToken};
        let (mut server, mut client, _listener) = pair();
        crate::security::tests::assert_pipe_acl(server.handle.as_raw_handle());
        client.write_all(&[1]).unwrap();
        server.read_exact(&mut [0]).unwrap();
        struct Revert;
        impl Drop for Revert {
            fn drop(&mut self) {
                unsafe {
                    RevertToSelf();
                }
            }
        }
        assert_ne!(
            unsafe { ImpersonateNamedPipeClient(server.handle.as_raw_handle()) },
            0
        );
        let _revert = Revert;
        let mut token = null_mut();
        assert_ne!(
            unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut token) },
            0
        );
        let token = owned(token).unwrap();
        let mut level = 0i32;
        let mut size = 0;
        assert_ne!(
            unsafe {
                GetTokenInformation(
                    token.as_raw_handle(),
                    TokenImpersonationLevel,
                    std::ptr::addr_of_mut!(level).cast(),
                    size_of::<i32>() as u32,
                    &mut size,
                )
            },
            0
        );
        assert_eq!(level, SecurityIdentification);
    }
}
