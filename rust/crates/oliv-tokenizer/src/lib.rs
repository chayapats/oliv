//! Small C ABI for the native MLX helper. Hugging Face's Rust tokenizer handles
//! byte fallback and pretokenization exactly as the model's tokenizer.json.
use std::ffi::{CStr, c_char, c_void};
use std::ptr;
use tokenizers::Tokenizer;

// Pointers are private to Swift's owning wrapper; arrays are immutable across
// the boundary. All allocations have matching free functions in this library.
#[unsafe(no_mangle)]
unsafe extern "C" fn oliv_tokenizer_open(filename: *const c_char) -> *mut c_void {
    let Ok(filename) = (unsafe { CStr::from_ptr(filename) }).to_str() else {
        return ptr::null_mut();
    };
    Tokenizer::from_file(filename)
        .ok()
        .map(|t| Box::into_raw(Box::new(t)).cast())
        .unwrap_or(ptr::null_mut())
}
#[unsafe(no_mangle)]
unsafe extern "C" fn oliv_tokenizer_close(handle: *mut c_void) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle.cast::<Tokenizer>()) });
    }
}
#[unsafe(no_mangle)]
unsafe extern "C" fn oliv_tokenizer_encode(
    handle: *const c_void,
    text: *const u8,
    len: usize,
    special: bool,
    out_len: *mut usize,
) -> *mut u32 {
    unsafe {
        *out_len = 0;
    }
    let bytes = unsafe { std::slice::from_raw_parts(text, len) };
    let Ok(text) = std::str::from_utf8(bytes) else {
        return ptr::null_mut();
    };
    let tokenizer = unsafe { &*handle.cast::<Tokenizer>() };
    let Ok(encoded) = tokenizer.encode(text, special) else {
        return ptr::null_mut();
    };
    let tokens = encoded.get_ids().to_vec().into_boxed_slice();
    unsafe {
        *out_len = tokens.len();
    }
    Box::into_raw(tokens).cast()
}
#[unsafe(no_mangle)]
unsafe extern "C" fn oliv_tokenizer_decode(
    handle: *const c_void,
    tokens: *const u32,
    len: usize,
    special: bool,
    out_len: *mut usize,
) -> *mut u8 {
    unsafe {
        *out_len = 0;
    }
    let tokenizer = unsafe { &*handle.cast::<Tokenizer>() };
    let ids = unsafe { std::slice::from_raw_parts(tokens, len) };
    let Ok(text) = tokenizer.decode(ids, special) else {
        return ptr::null_mut();
    };
    let bytes = text.into_bytes().into_boxed_slice();
    unsafe {
        *out_len = bytes.len();
    }
    Box::into_raw(bytes).cast()
}
#[unsafe(no_mangle)]
unsafe extern "C" fn oliv_tokenizer_free_tokens(tokens: *mut u32, len: usize) {
    if !tokens.is_null() {
        drop(unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(tokens, len)) });
    }
}
#[unsafe(no_mangle)]
unsafe extern "C" fn oliv_tokenizer_free_bytes(bytes: *mut u8, len: usize) {
    if !bytes.is_null() {
        drop(unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(bytes, len)) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn whisper_unicode_matches_reference_across_the_c_abi() {
        // Synthetic public text; IDs produced by mlx-whisper 0.4.3/tiktoken.
        let cases: serde_json::Value =
            serde_json::from_str(include_str!("../tests/whisper.json")).unwrap();
        let filename = CString::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../macos/OLIVInference/Resources/whisper-tokenizer/tokenizer.json"
        ))
        .unwrap();
        unsafe {
            let handle = oliv_tokenizer_open(filename.as_ptr());
            assert!(!handle.is_null());
            for _ in 0..3 {
                for case in cases.as_array().unwrap() {
                    let text = case["text"].as_str().unwrap();
                    let expected: Vec<u32> = case["tokens"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|v| v.as_u64().unwrap() as u32)
                        .collect();
                    let mut count = 0;
                    let tokens =
                        oliv_tokenizer_encode(handle, text.as_ptr(), text.len(), false, &mut count);
                    assert!(!tokens.is_null());
                    assert_eq!(std::slice::from_raw_parts(tokens, count), expected);
                    let mut length = 0;
                    let bytes = oliv_tokenizer_decode(handle, tokens, count, false, &mut length);
                    assert!(!bytes.is_null());
                    assert_eq!(std::slice::from_raw_parts(bytes, length), text.as_bytes());
                    oliv_tokenizer_free_tokens(tokens, count);
                    oliv_tokenizer_free_bytes(bytes, length);
                }
            }
            let mut count = 99;
            let invalid = [0xff];
            assert!(
                oliv_tokenizer_encode(handle, invalid.as_ptr(), invalid.len(), false, &mut count)
                    .is_null()
            );
            assert_eq!(count, 0);
            oliv_tokenizer_close(handle);
        }
    }
}
