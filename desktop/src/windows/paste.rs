//! Native Unicode clipboard paste. Snapshot every advertised format before
//! replacing anything, including HTML, images and file lists. A format we
//! cannot safely duplicate aborts the paste and leaves the clipboard intact.

use std::mem::size_of;
use std::ptr::{null, null_mut};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use windows_sys::Win32::Foundation::{GetLastError, GlobalFree, HANDLE, HWND, SetLastError};
use windows_sys::Win32::Graphics::Gdi::{
    CopyEnhMetaFileW, DeleteEnhMetaFile, DeleteMetaFile, DeleteObject,
};
use windows_sys::Win32::System::DataExchange::*;
use windows_sys::Win32::System::Memory::{
    GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock,
};
use windows_sys::Win32::System::Ole::*;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::*;
use windows_sys::Win32::UI::WindowsAndMessaging::*;

const SETTLE: Duration = Duration::from_millis(400);
const MAX_BACKUP: usize = 256 * 1024 * 1024;
static SERIAL: Mutex<()> = Mutex::new(());
static GENERATION: AtomicU64 = AtomicU64::new(0);

struct Owner(HWND);

impl Owner {
    fn new() -> Result<Self, String> {
        // OpenClipboard(NULL) cannot become clipboard owner. A message-only
        // STATIC window provides a real owner without ever appearing on screen.
        let class: Vec<u16> = "STATIC\0".encode_utf16().collect();
        let hwnd = unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                null(),
                0,
                0,
                0,
                0,
                0,
                HWND_MESSAGE,
                null_mut(),
                null_mut(),
                null(),
            )
        };
        if hwnd.is_null() {
            return Err(format!(
                "clipboard owner: {}",
                std::io::Error::last_os_error()
            ));
        }
        Ok(Self(hwnd))
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        unsafe { DestroyWindow(self.0) };
    }
}

struct Open;
impl Open {
    fn new(owner: &Owner) -> Result<Self, String> {
        let start = Instant::now();
        loop {
            if unsafe { OpenClipboard(owner.0) } != 0 {
                return Ok(Self);
            }
            if start.elapsed() >= Duration::from_millis(500) {
                return Err(format!(
                    "clipboard is busy: {}",
                    std::io::Error::last_os_error()
                ));
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}
impl Drop for Open {
    fn drop(&mut self) {
        unsafe { CloseClipboard() };
    }
}

struct Data {
    format: u16,
    handle: HANDLE,
}

impl Drop for Data {
    fn drop(&mut self) {
        if self.handle.is_null() {
            return;
        }
        unsafe {
            match self.format {
                CF_BITMAP | CF_DSPBITMAP | CF_PALETTE => {
                    DeleteObject(self.handle);
                }
                CF_ENHMETAFILE | CF_DSPENHMETAFILE => {
                    DeleteEnhMetaFile(self.handle);
                }
                CF_METAFILEPICT | CF_DSPMETAFILEPICT => {
                    let picture = GlobalLock(self.handle).cast::<METAFILEPICT>();
                    if !picture.is_null() {
                        DeleteMetaFile((*picture).hMF);
                        GlobalUnlock(self.handle);
                    }
                    GlobalFree(self.handle);
                }
                _ => {
                    GlobalFree(self.handle);
                }
            }
        }
    }
}

impl Data {
    fn text(text: &str) -> Result<Self, String> {
        let units = clipboard_text(text)?;
        let handle = unsafe { GlobalAlloc(GMEM_MOVEABLE, units.len() * size_of::<u16>()) };
        if handle.is_null() {
            return Err("clipboard allocation failed".into());
        }
        let data = Self {
            format: CF_UNICODETEXT,
            handle,
        };
        let buffer = unsafe { GlobalLock(handle) }.cast::<u16>();
        if buffer.is_null() {
            return Err("clipboard memory lock failed".into());
        }
        unsafe {
            std::ptr::copy_nonoverlapping(units.as_ptr(), buffer, units.len());
            GlobalUnlock(handle);
        }
        Ok(data)
    }

    /// Caller keeps the clipboard open throughout snapshot and replacement.
    fn duplicate(format: u16, total: &mut usize) -> Result<Self, String> {
        if format == CF_OWNERDISPLAY || (CF_PRIVATEFIRST..=CF_GDIOBJLAST).contains(&format) {
            return Err(format!(
                "clipboard format {format} cannot be safely restored; copy the dictation from history"
            ));
        }
        let source = unsafe { GetClipboardData(format as u32) };
        if source.is_null() {
            return Err(format!(
                "cannot read clipboard format {format}; clipboard kept unchanged"
            ));
        }
        let handle = unsafe {
            match format {
                CF_BITMAP | CF_DSPBITMAP => {
                    CopyImage(source, IMAGE_BITMAP, 0, 0, LR_CREATEDIBSECTION)
                }
                CF_ENHMETAFILE | CF_DSPENHMETAFILE => CopyEnhMetaFileW(source, null()),
                CF_PALETTE => OleDuplicateData(source, CF_PALETTE, GMEM_MOVEABLE),
                CF_METAFILEPICT | CF_DSPMETAFILEPICT => {
                    OleDuplicateData(source, CF_METAFILEPICT, GMEM_MOVEABLE)
                }
                _ => {
                    let size = GlobalSize(source);
                    *total = total.saturating_add(size);
                    if *total > MAX_BACKUP {
                        return Err(
                            "clipboard backup exceeds 256 MiB; clipboard kept unchanged".into()
                        );
                    }
                    // Registered formats must be backed by movable global memory.
                    // Never try to reinterpret an app-private pointer as bytes.
                    if size == 0 {
                        return Err(format!(
                            "cannot duplicate clipboard format {format}; clipboard kept unchanged"
                        ));
                    }
                    OleDuplicateData(source, format, GMEM_MOVEABLE)
                }
            }
        };
        if handle.is_null() {
            return Err(format!(
                "cannot duplicate clipboard format {format}; clipboard kept unchanged"
            ));
        }
        Ok(Self { format, handle })
    }

    fn put(&mut self) -> Result<(), String> {
        if unsafe { SetClipboardData(self.format as u32, self.handle) }.is_null() {
            return Err(format!(
                "set clipboard format {}: {}",
                self.format,
                std::io::Error::last_os_error()
            ));
        }
        self.handle = null_mut(); // Ownership transferred to Windows.
        Ok(())
    }
}

fn clipboard_text(text: &str) -> Result<Vec<u16>, String> {
    if text.contains('\0') {
        return Err("clipboard text contains a NUL character".into());
    }
    // CF_UNICODETEXT specifies CRLF line endings; preserve existing CRLF.
    Ok(text
        .replace("\r\n", "\n")
        .replace('\n', "\r\n")
        .encode_utf16()
        .chain([0])
        .collect())
}

/// Sequence numbers also change when Windows synthesizes ANSI/OEM text after
/// CloseClipboard. A unique registered marker identifies this paste across
/// those conversions. The marker alone is insufficient: clipboard managers
/// can replace/add data without clearing the clipboard or changing its owner.
struct PasteStamp {
    data: Data,
    marker: Data,
    text: Vec<u16>,
    marker_text: Vec<u16>,
    sequence: u32,
}

impl PasteStamp {
    fn new(text: &str) -> Result<Self, String> {
        let name: Vec<u16> = "Oliv.Paste.Transaction.v1\0".encode_utf16().collect();
        let format = unsafe { RegisterClipboardFormatW(name.as_ptr()) } as u16;
        if format == 0 {
            return Err("register clipboard transaction format failed".into());
        }
        let token = format!(
            "{}:{}:{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos(),
            GENERATION.fetch_add(1, Ordering::Relaxed)
        );
        let mut marker = Data::text(&token)?;
        marker.format = format;
        Ok(Self {
            data: Data::text(text)?,
            marker,
            text: clipboard_text(text)?,
            marker_text: clipboard_text(&token)?,
            sequence: 0,
        })
    }

    fn put(&mut self) -> Result<(), String> {
        self.data.put()?;
        self.marker.put()?;
        self.sequence = unsafe { GetClipboardSequenceNumber() };
        Ok(())
    }

    fn matches(&self, owner: &Owner) -> bool {
        if unsafe { GetClipboardOwner() } != owner.0 {
            return false;
        }
        if unsafe { GetClipboardSequenceNumber() } == self.sequence {
            return true;
        }
        if !same_clipboard_text(self.marker.format, &self.marker_text)
            || !same_clipboard_text(CF_UNICODETEXT, &self.text)
        {
            return false;
        }
        // Only Windows' text-conversion formats may have appeared. Preserve
        // any newly copied HTML, image, or other registered format instead.
        let mut format = 0;
        loop {
            unsafe { SetLastError(0) };
            format = unsafe { EnumClipboardFormats(format) };
            if format == 0 {
                return unsafe { GetLastError() } == 0;
            }
            if format != self.marker.format as u32
                && ![CF_UNICODETEXT, CF_TEXT, CF_OEMTEXT, CF_LOCALE]
                    .into_iter()
                    .any(|allowed| format == allowed as u32)
            {
                return false;
            }
        }
    }
}

/// Caller holds the clipboard open. Compare the complete NUL-terminated
/// logical string, allowing GlobalAlloc's unused allocation padding.
fn same_clipboard_text(format: u16, expected: &[u16]) -> bool {
    let handle = unsafe { GetClipboardData(format as u32) };
    if handle.is_null() || unsafe { GlobalSize(handle) } < std::mem::size_of_val(expected) {
        return false;
    }
    let memory = unsafe { GlobalLock(handle) }.cast::<u16>();
    if memory.is_null() {
        return false;
    }
    let same = unsafe { std::slice::from_raw_parts(memory, expected.len()) } == expected;
    unsafe { GlobalUnlock(handle) };
    same
}

struct Snapshot(Vec<Data>);
impl Snapshot {
    fn take() -> Result<Self, String> {
        let mut data = Vec::new();
        let mut format = 0;
        let mut total = 0;
        loop {
            unsafe { SetLastError(0) };
            format = unsafe { EnumClipboardFormats(format) };
            if format == 0 {
                if unsafe { GetLastError() } != 0 {
                    return Err(format!(
                        "enumerate clipboard: {}",
                        std::io::Error::last_os_error()
                    ));
                }
                return Ok(Self(data));
            }
            if data.len() >= 256 || format > u16::MAX as u32 {
                return Err("too many clipboard formats; clipboard kept unchanged".into());
            }
            data.push(Data::duplicate(format as u16, &mut total)?);
        }
    }

    fn restore(&mut self) -> Result<(), String> {
        empty()?;
        let mut failed = Vec::new();
        // Try every format even if one fails, to restore as much as possible.
        for data in &mut self.0 {
            if let Err(error) = data.put() {
                failed.push(error);
            }
        }
        if failed.is_empty() {
            Ok(())
        } else {
            Err(failed.join("; "))
        }
    }

    /// Must be called with the clipboard open: the check and restore are atomic
    /// with respect to another application's clipboard replacement.
    fn restore_if_current(&mut self, owner: &Owner, stamp: &PasteStamp) -> Result<bool, String> {
        if !stamp.matches(owner) {
            return Ok(false);
        }
        self.restore()?;
        Ok(true)
    }
}

fn empty() -> Result<(), String> {
    if unsafe { EmptyClipboard() } == 0 {
        return Err(format!(
            "empty clipboard: {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(())
}

/// Explicitly copy UTF-8 text (used by the shared retry command).
pub fn copy(data: &[u8], mime: &str) -> Result<(), String> {
    if !matches!(
        mime,
        "text/plain" | "text/plain;charset=utf-8" | "UTF8_STRING"
    ) {
        return Err(format!("Windows copy requires UTF-8 text, received {mime}"));
    }
    let text = std::str::from_utf8(data).map_err(|error| format!("clipboard text: {error}"))?;
    let mut data = Data::text(text)?;
    let _serial = SERIAL.lock().unwrap_or_else(|error| error.into_inner());
    let owner = Owner::new()?;
    let _open = Open::new(&owner)?;
    empty()?;
    data.put()
}

fn key(key: u16, up: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: key,
                dwFlags: (if up { KEYEVENTF_KEYUP } else { 0 })
                    | (if key == VK_INSERT {
                        KEYEVENTF_EXTENDEDKEY
                    } else {
                        0
                    }),
                dwExtraInfo: 0x4F4C4956,
                ..KEYBDINPUT::default()
            },
        },
    }
}

fn chord(window: HWND) -> (u16, u16) {
    let mut class = [0u16; 128];
    let length = unsafe { GetClassNameW(window, class.as_mut_ptr(), class.len() as i32) };
    let class = String::from_utf16_lossy(&class[..length.max(0) as usize]);
    if class == "ConsoleWindowClass" {
        (VK_LSHIFT, VK_INSERT)
    } else {
        (VK_LCONTROL, 0x56)
    }
}

fn modifiers_up() -> bool {
    [
        VK_LSHIFT,
        VK_RSHIFT,
        VK_LCONTROL,
        VK_RCONTROL,
        VK_LMENU,
        VK_RMENU,
        VK_LWIN,
        VK_RWIN,
        0x56,
        VK_INSERT,
    ]
    .into_iter()
    .all(|key| unsafe { GetAsyncKeyState(key as i32) } >= 0)
}

fn inject(window: HWND) -> Result<(), String> {
    if unsafe { GetForegroundWindow() } != window {
        return Err("focused window changed before paste; retrieve text with oliv last".into());
    }
    if !modifiers_up() {
        return Err("a modifier key is held; retrieve text with oliv last".into());
    }
    let (modifier, letter) = chord(window);
    let keys = [
        key(modifier, false),
        key(letter, false),
        key(letter, true),
        key(modifier, true),
    ];
    let count = unsafe { SendInput(keys.len() as u32, keys.as_ptr(), size_of::<INPUT>() as i32) };
    if count != keys.len() as u32 {
        if count > 0 {
            let release = [key(letter, true), key(modifier, true)];
            unsafe {
                SendInput(
                    release.len() as u32,
                    release.as_ptr(),
                    size_of::<INPUT>() as i32,
                )
            };
        }
        return Err("Windows blocked the paste keys (possibly an elevated app); retrieve text with oliv last".into());
    }
    Ok(())
}

/// Paste into the focused app, then restore the exact supported clipboard
/// formats only if no other application changed the clipboard in the meantime.
/// Windows UIPI forbids sending keys to an app elevated above this process.
pub fn paste(text: &str) -> Result<(), String> {
    let mut stamp = PasteStamp::new(text)?;
    let _serial = SERIAL.lock().unwrap_or_else(|error| error.into_inner());
    let window = unsafe { GetForegroundWindow() };
    if window.is_null() {
        return Err("no focused window for paste".into());
    }
    let start = Instant::now();
    while !modifiers_up() {
        if start.elapsed() >= Duration::from_secs(2) {
            return Err("release modifier keys, then retrieve text with oliv last".into());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let owner = Owner::new()?;
    let mut old = {
        let _open = Open::new(&owner)?;
        let mut old = Snapshot::take()?;
        empty()?;
        if let Err(error) = stamp.put() {
            if let Err(restore) = old.restore() {
                eprintln!("paste: clipboard restore failed: {restore}");
            }
            return Err(error);
        }
        old
    };
    let result = inject(window);
    if result.is_ok() {
        std::thread::sleep(SETTLE);
    }
    match Open::new(&owner) {
        Ok(_open) => {
            if let Err(error) = old.restore_if_current(&owner, &stamp) {
                eprintln!("paste: clipboard restore failed: {error}");
            }
        }
        Err(error) => eprintln!("paste: clipboard restore failed: {error}"),
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::thread::JoinHandle;
    use windows_sys::Win32::Graphics::Gdi::{
        BI_RGB, BITMAPINFO, BITMAPINFOHEADER, CreateCompatibleDC, CreateDIBSection, DIB_RGB_COLORS,
        DeleteDC, GetDIBits,
    };
    use windows_sys::Win32::System::Threading::GetCurrentThreadId;

    // Separate from SERIAL: the end-to-end test calls public paste(), which
    // takes the production mutex itself.
    static DESKTOP_TEST: Mutex<()> = Mutex::new(());

    struct NativeEdit {
        window: usize,
        edit: usize,
        thread_id: u32,
        thread: Option<JoinHandle<()>>,
    }

    impl NativeEdit {
        fn new() -> Self {
            let (ready_tx, ready_rx) = mpsc::sync_channel(1);
            let thread = std::thread::spawn(move || {
                let wide = |s: &str| s.encode_utf16().chain([0]).collect::<Vec<_>>();
                let window = unsafe {
                    CreateWindowExW(
                        0,
                        wide("STATIC").as_ptr(),
                        wide("Oliv native paste acceptance").as_ptr(),
                        WS_OVERLAPPEDWINDOW,
                        80,
                        80,
                        700,
                        400,
                        null_mut(),
                        null_mut(),
                        null_mut(),
                        null(),
                    )
                };
                assert!(!window.is_null(), "create native target window");
                let _window = Owner(window);
                let edit = unsafe {
                    CreateWindowExW(
                        0,
                        wide("EDIT").as_ptr(),
                        null(),
                        WS_CHILD
                            | WS_VISIBLE
                            | WS_VSCROLL
                            | ES_MULTILINE as u32
                            | ES_AUTOVSCROLL as u32
                            | ES_WANTRETURN as u32,
                        10,
                        10,
                        650,
                        330,
                        window,
                        null_mut(),
                        null_mut(),
                        null(),
                    )
                };
                assert!(!edit.is_null(), "create native EDIT control");
                unsafe {
                    ShowWindow(window, SW_SHOW);
                    SetForegroundWindow(window);
                    SetActiveWindow(window);
                    SetFocus(edit);
                }
                ready_tx
                    .send((window as usize, edit as usize, unsafe {
                        GetCurrentThreadId()
                    }))
                    .unwrap();
                let mut message = MSG::default();
                loop {
                    let result = unsafe { GetMessageW(&mut message, null_mut(), 0, 0) };
                    assert!(result >= 0, "native target message loop");
                    if result == 0 {
                        break;
                    }
                    unsafe {
                        TranslateMessage(&message);
                        DispatchMessageW(&message);
                    }
                }
            });
            let (window, edit, thread_id) = ready_rx
                .recv_timeout(Duration::from_secs(5))
                .expect("native window thread startup");
            let target = Self {
                window,
                edit,
                thread_id,
                thread: Some(thread),
            };
            let start = Instant::now();
            loop {
                let mut info = GUITHREADINFO {
                    cbSize: size_of::<GUITHREADINFO>() as u32,
                    ..GUITHREADINFO::default()
                };
                if unsafe { GetGUIThreadInfo(thread_id, &mut info) } != 0
                    && info.hwndFocus as usize == edit
                    && unsafe { GetForegroundWindow() } as usize == window
                {
                    break;
                }
                assert!(
                    start.elapsed() < Duration::from_secs(3),
                    "Windows did not grant EDIT foreground/focus; this test requires an interactive desktop"
                );
                std::thread::sleep(Duration::from_millis(10));
            }
            target
        }

        fn text(&self) -> String {
            let count = unsafe { SendMessageW(self.edit as HWND, WM_GETTEXTLENGTH, 0, 0) };
            assert!(count >= 0);
            let mut units = vec![0u16; count as usize + 1];
            let read = unsafe {
                SendMessageW(
                    self.edit as HWND,
                    WM_GETTEXT,
                    units.len(),
                    units.as_mut_ptr() as isize,
                )
            };
            String::from_utf16(&units[..read as usize]).unwrap()
        }
    }

    impl Drop for NativeEdit {
        fn drop(&mut self) {
            unsafe { PostThreadMessageW(self.thread_id, WM_QUIT, 0, 0) };
            if let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
        }
    }

    struct HeldKey(u16);
    impl HeldKey {
        fn down(code: u16) -> Self {
            let input = key(code, false);
            assert_eq!(
                unsafe { SendInput(1, &input, size_of::<INPUT>() as i32) },
                1
            );
            let held = Self(code);
            let start = Instant::now();
            while unsafe { GetAsyncKeyState(code as i32) } >= 0 {
                assert!(
                    start.elapsed() < Duration::from_secs(2),
                    "injected modifier did not go down"
                );
                std::thread::sleep(Duration::from_millis(5));
            }
            held
        }
    }
    impl Drop for HeldKey {
        fn drop(&mut self) {
            let input = key(self.0, true);
            unsafe { SendInput(1, &input, size_of::<INPUT>() as i32) };
        }
    }

    fn global_test_data(format: u16, bytes: &[u8]) -> Data {
        let handle = unsafe { GlobalAlloc(GMEM_MOVEABLE, bytes.len()) };
        assert!(!handle.is_null());
        let data = Data { format, handle };
        let target = unsafe { GlobalLock(handle) }.cast::<u8>();
        assert!(!target.is_null());
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), target, bytes.len());
            GlobalUnlock(handle);
        }
        data
    }

    fn dib_info() -> BITMAPINFO {
        BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: 2,
                biHeight: -2,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB,
                ..BITMAPINFOHEADER::default()
            },
            ..BITMAPINFO::default()
        }
    }

    fn bitmap_test_data() -> Data {
        let mut pixels = null_mut();
        let bitmap = unsafe {
            CreateDIBSection(
                null_mut(),
                &dib_info(),
                DIB_RGB_COLORS,
                &mut pixels,
                null_mut(),
                0,
            )
        };
        assert!(!bitmap.is_null());
        let data = Data {
            format: CF_BITMAP,
            handle: bitmap,
        };
        assert!(!pixels.is_null());
        let colors = [0x000000ffu32, 0x0000ff00, 0x00ff0000, 0x00abcdef];
        unsafe {
            std::ptr::copy_nonoverlapping(colors.as_ptr(), pixels.cast(), colors.len());
        }
        data
    }

    fn assert_bitmap_restored() {
        let bitmap = unsafe { GetClipboardData(CF_BITMAP as u32) };
        assert!(!bitmap.is_null());
        let dc = unsafe { CreateCompatibleDC(null_mut()) };
        assert!(!dc.is_null());
        let mut colors = [0u32; 4];
        let lines = unsafe {
            GetDIBits(
                dc,
                bitmap,
                0,
                2,
                colors.as_mut_ptr().cast(),
                &mut dib_info(),
                DIB_RGB_COLORS,
            )
        };
        unsafe { DeleteDC(dc) };
        assert_eq!(lines, 2);
        assert_eq!(
            colors.map(|color| color & 0x00ffffff),
            [0x000000ff, 0x0000ff00, 0x00ff0000, 0x00abcdef]
        );
    }

    fn drop_files_test_data() -> Vec<u8> {
        // DROPFILES is DWORD pFiles, POINT pt, BOOL fNC, BOOL fWide (20 bytes).
        // Follow it with a UTF-16 MULTI_SZ, exactly as the shell specifies.
        let mut bytes = vec![0u8; 20];
        bytes[..4].copy_from_slice(&20u32.to_le_bytes());
        bytes[16..20].copy_from_slice(&1u32.to_le_bytes());
        for unit in
            "C:\\OlivNativeTest\\ภาษาไทย one.txt\0C:\\OlivNativeTest\\second.txt\0\0".encode_utf16()
        {
            bytes.extend_from_slice(&unit.to_le_bytes());
        }
        bytes
    }

    fn assert_global_data(format: u16, expected: &[u8]) {
        let handle = unsafe { GetClipboardData(format as u32) };
        assert!(!handle.is_null());
        assert!(unsafe { GlobalSize(handle) } >= expected.len());
        let memory = unsafe { GlobalLock(handle) }.cast::<u8>();
        assert!(!memory.is_null());
        let equal = unsafe { std::slice::from_raw_parts(memory, expected.len()) } == expected;
        unsafe { GlobalUnlock(handle) };
        assert!(equal, "clipboard format {format} changed");
    }

    // Each test releases the clipboard between producer and consumer calls,
    // just like the real paste path. Reopen before restoring on a panic too.
    struct RestoreOnDrop<'a> {
        old: Option<Snapshot>,
        owner: &'a Owner,
    }

    impl<'a> RestoreOnDrop<'a> {
        fn save(owner: &'a Owner) -> Self {
            let _open = Open::new(owner).unwrap();
            Self {
                old: Some(Snapshot::take().unwrap()),
                owner,
            }
        }

        fn restore(mut self) {
            let _open = Open::new(self.owner).unwrap();
            self.old.take().unwrap().restore().unwrap();
        }
    }

    impl Drop for RestoreOnDrop<'_> {
        fn drop(&mut self) {
            if let Some(mut old) = self.old.take()
                && let Err(error) = Open::new(self.owner).and_then(|_open| old.restore())
            {
                eprintln!("native test clipboard restore failed: {error}");
            }
        }
    }

    fn read_test_text(format: u16) -> String {
        let handle = unsafe { GetClipboardData(format as u32) };
        assert!(!handle.is_null());
        let size = unsafe { GlobalSize(handle) } / size_of::<u16>();
        let ptr = unsafe { GlobalLock(handle) }.cast::<u16>();
        assert!(!ptr.is_null());
        let units = unsafe { std::slice::from_raw_parts(ptr, size) };
        let length = units.iter().position(|unit| *unit == 0).unwrap_or(size);
        let result = String::from_utf16(&units[..length]);
        unsafe { GlobalUnlock(handle) };
        result.unwrap()
    }

    #[test]
    fn unicode_clipboard_preserves_thai_surrogates_and_line_breaks() {
        let result = clipboard_text("ภาษาไทย 🫒\nnext\r\nlast").unwrap();
        assert_eq!(result.last(), Some(&0));
        assert_eq!(
            String::from_utf16(&result[..result.len() - 1]).unwrap(),
            "ภาษาไทย 🫒\r\nnext\r\nlast"
        );
        assert!(clipboard_text("hidden\0suffix").is_err());
    }

    #[test]
    #[ignore = "requires an interactive Windows desktop; temporarily writes the clipboard"]
    fn native_unicode_and_registered_formats_survive_snapshot_restore() {
        let _serial = DESKTOP_TEST.lock().unwrap();
        let owner = Owner::new().unwrap();
        let reader = Owner::new().unwrap();
        let original = RestoreOnDrop::save(&owner);
        let mut text = Data::text("ทดสอบ Oliv 🫒").unwrap();
        let format_name: Vec<u16> = "Oliv.IntegrationTest.UnicodePayload\0"
            .encode_utf16()
            .collect();
        let format = unsafe { RegisterClipboardFormatW(format_name.as_ptr()) } as u16;
        assert_ne!(format, 0);
        let mut custom = Data::text("structured clipboard 🔹").unwrap();
        custom.format = format;
        {
            let _open = Open::new(&owner).unwrap();
            empty().unwrap();
            text.put().unwrap();
            custom.put().unwrap();
        }
        let (mut snapshot, stamp) = {
            let _open = Open::new(&owner).unwrap();
            let snapshot = Snapshot::take().unwrap();
            empty().unwrap();
            let mut stamp = PasteStamp::new("temporary dictated text").unwrap();
            stamp.put().unwrap();
            eprintln!("paste sequence before CloseClipboard: {}", stamp.sequence);
            (snapshot, stamp)
        };
        eprintln!("paste sequence after CloseClipboard: {}", unsafe {
            GetClipboardSequenceNumber()
        });
        {
            let _open = Open::new(&reader).unwrap();
            assert_eq!(read_test_text(CF_UNICODETEXT), "temporary dictated text");
            // A destination may ask Windows to synthesize ANSI text instead of
            // reading CF_UNICODETEXT. This must not break clipboard restoration.
            assert!(!unsafe { GetClipboardData(CF_TEXT as u32) }.is_null());
            assert!(!unsafe { GetClipboardData(CF_OEMTEXT as u32) }.is_null());
            eprintln!("paste sequence after text synthesis: {}", unsafe {
                GetClipboardSequenceNumber()
            });
        }
        {
            let _open = Open::new(&owner).unwrap();
            assert!(snapshot.restore_if_current(&owner, &stamp).unwrap());
        }
        {
            let _open = Open::new(&reader).unwrap();
            assert_eq!(read_test_text(CF_UNICODETEXT), "ทดสอบ Oliv 🫒");
            assert_eq!(read_test_text(format), "structured clipboard 🔹");
        }
        original.restore();
    }

    #[test]
    #[ignore = "requires an interactive Windows desktop; temporarily writes the clipboard"]
    fn native_restore_does_not_overwrite_a_newer_copy() {
        let _serial = DESKTOP_TEST.lock().unwrap();
        let owner = Owner::new().unwrap();
        let outsider = Owner::new().unwrap();
        let original = RestoreOnDrop::save(&owner);
        {
            let _open = Open::new(&owner).unwrap();
            empty().unwrap();
            Data::text("old clipboard").unwrap().put().unwrap();
        }
        let (mut snapshot, mut stamp) = {
            let _open = Open::new(&owner).unwrap();
            let snapshot = Snapshot::take().unwrap();
            empty().unwrap();
            let mut stamp = PasteStamp::new("temporary dictated text").unwrap();
            stamp.put().unwrap();
            eprintln!("paste sequence before CloseClipboard: {}", stamp.sequence);
            (snapshot, stamp)
        };
        {
            let _open = Open::new(&outsider).unwrap();
            // Clipboard managers can append/replace formats without EmptyClipboard,
            // which changes the sequence but keeps the original owner HWND.
            Data::text("new clipboard from manager")
                .unwrap()
                .put()
                .unwrap();
        }
        {
            let _open = Open::new(&owner).unwrap();
            assert_eq!(unsafe { GetClipboardOwner() }, owner.0);
            assert!(!snapshot.restore_if_current(&owner, &stamp).unwrap());
            assert_eq!(read_test_text(CF_UNICODETEXT), "new clipboard from manager");
        }
        {
            let _open = Open::new(&outsider).unwrap();
            // Keeping both our marker and our exact text is still insufficient
            // when a manager has appended new non-synthesized clipboard data.
            Data::text("temporary dictated text")
                .unwrap()
                .put()
                .unwrap();
            let name: Vec<u16> = "Oliv.IntegrationTest.AddedFormat\0"
                .encode_utf16()
                .collect();
            let mut added = Data::text("new app-specific data").unwrap();
            added.format = unsafe { RegisterClipboardFormatW(name.as_ptr()) } as u16;
            assert_ne!(added.format, 0);
            added.put().unwrap();
        }
        {
            let _open = Open::new(&owner).unwrap();
            assert!(!snapshot.restore_if_current(&owner, &stamp).unwrap());
            assert_eq!(read_test_text(CF_UNICODETEXT), "temporary dictated text");
        }
        {
            let _open = Open::new(&outsider).unwrap();
            empty().unwrap();
            Data::text("new clipboard from user")
                .unwrap()
                .put()
                .unwrap();
        }
        {
            let _open = Open::new(&owner).unwrap();
            // Even a matching sequence is insufficient when another window owns it.
            stamp.sequence = unsafe { GetClipboardSequenceNumber() };
            assert!(!snapshot.restore_if_current(&owner, &stamp).unwrap());
            assert_eq!(read_test_text(CF_UNICODETEXT), "new clipboard from user");
        }
        original.restore();
    }

    #[test]
    #[ignore = "requires an interactive Windows desktop; sends keys only to its own EDIT control"]
    fn native_sendinput_pastes_unicode_into_edit_and_restores_text_bitmap_files() {
        let _test = DESKTOP_TEST.lock().unwrap();
        let owner = Owner::new().unwrap();
        let original = RestoreOnDrop::save(&owner);
        let files = drop_files_test_data();
        {
            let _open = Open::new(&owner).unwrap();
            empty().unwrap();
            Data::text("original clipboard ข้อความ 🫒")
                .unwrap()
                .put()
                .unwrap();
            bitmap_test_data().put().unwrap();
            global_test_data(CF_HDROP, &files).put().unwrap();
        }
        let target = NativeEdit::new();
        let text = "ภาษาไทย Hello OLIV 🫒🚀\nบรรทัดสอง English\r\nthird line";
        // Exercise the production function, including SendInput and its restore
        // delay. Never send WM_PASTE or WM_SETTEXT to manufacture a passing result.
        paste(text).unwrap();
        assert_eq!(
            target.text(),
            text.replace("\r\n", "\n").replace('\n', "\r\n")
        );
        assert_eq!(unsafe { GetForegroundWindow() } as usize, target.window);
        {
            let _open = Open::new(&owner).unwrap();
            assert_eq!(
                read_test_text(CF_UNICODETEXT),
                "original clipboard ข้อความ 🫒"
            );
            assert_bitmap_restored();
            assert_global_data(CF_HDROP, &files);
        }

        let prior = target.text();
        let held = HeldKey::down(VK_LCONTROL);
        assert!(
            inject(target.window as HWND)
                .unwrap_err()
                .contains("modifier key")
        );
        drop(held);
        assert_eq!(
            target.text(),
            prior,
            "refused modifier chord must not alter the EDIT control"
        );

        let other = NativeEdit::new();
        assert!(
            inject(target.window as HWND)
                .unwrap_err()
                .contains("focused window changed")
        );
        assert!(
            other.text().is_empty(),
            "refused focus change must not paste into the new window"
        );
        assert_eq!(target.text(), prior);
        drop(other);
        drop(target);
        original.restore();
    }
}
