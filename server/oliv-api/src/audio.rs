//! Public contract: RIFF/WAVE PCM signed 16-bit, mono, 16 kHz, <= 120 seconds.
//! Validate the entire container before forwarding it to the model decoder.
pub const MAX_SECONDS: usize = 120;
const MAX_DATA: usize = 16000 * 2 * MAX_SECONDS;

pub fn validate(wav: &[u8]) -> Result<(), &'static str> {
    let bad = "wav_b64 must contain PCM16 mono 16000 Hz WAV, 0 < duration <= 120 seconds";
    if wav.len() < 44 || &wav[..4] != b"RIFF" || &wav[8..12] != b"WAVE" {
        return Err(bad);
    }
    let u32le = |p: &[u8]| u32::from_le_bytes(p.try_into().unwrap()) as usize;
    if u32le(&wav[4..8]).checked_add(8) != Some(wav.len()) {
        return Err(bad);
    }
    let (mut pos, mut fmt, mut data) = (12usize, false, false);
    while pos < wav.len() {
        if wav.len() - pos < 8 {
            return Err(bad);
        }
        let tag = &wav[pos..pos + 4];
        let len = u32le(&wav[pos + 4..pos + 8]);
        let start = pos + 8;
        let end = start
            .checked_add(len)
            .filter(|n| *n <= wav.len())
            .ok_or(bad)?;
        match tag {
            b"fmt " => {
                if fmt || !(len == 16 || len == 18) {
                    return Err(bad);
                }
                let f = &wav[start..end];
                if f[..4] != [1, 0, 1, 0]
                    || u32le(&f[4..8]) != 16000
                    || u32le(&f[8..12]) != 32000
                    || f[12..16] != [2, 0, 16, 0]
                    || (len == 18 && f[16..18] != [0, 0])
                {
                    return Err(bad);
                }
                fmt = true;
            }
            b"data" => {
                if !fmt || data || len == 0 || len > MAX_DATA || len % 2 != 0 {
                    return Err(bad);
                }
                data = true;
            }
            // Keep iOS metadata compatible, but bound metadata and reject nested
            // format-changing containers such as LIST/wavl and concatenated RIFF.
            b"JUNK" | b"PAD " | b"LIST" | b"bext" => {
                if len > 65536 || (tag == b"LIST" && (len < 4 || &wav[start..start + 4] != b"INFO"))
                {
                    return Err(bad);
                }
            }
            _ => return Err(bad),
        }
        pos = end
            .checked_add(len % 2)
            .filter(|n| *n <= wav.len())
            .ok_or(bad)?;
    }
    if !fmt || !data {
        return Err(bad);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn wav(samples: usize) -> Vec<u8> {
        let mut w = b"RIFF".to_vec();
        w.extend_from_slice(&((36 + samples * 2) as u32).to_le_bytes());
        w.extend_from_slice(
            b"WAVEfmt \x10\0\0\0\x01\0\x01\0\x80\x3e\0\0\0\x7d\0\0\x02\0\x10\0data",
        );
        w.extend_from_slice(&((samples * 2) as u32).to_le_bytes());
        w.resize(44 + samples * 2, 0);
        w
    }
    #[test]
    fn accepts_pcm_and_duration_boundary() {
        assert!(validate(&wav(1)).is_ok());
        assert!(validate(&wav(16000 * 120)).is_ok());
        assert!(validate(&wav(16000 * 120 + 1)).is_err());
        assert!(validate(&wav(0)).is_err());
    }
    #[test]
    fn refuses_bad_headers_truncation_and_hidden_trailing_payload() {
        let valid = wav(16);
        for n in 0..valid.len() {
            assert!(validate(&valid[..n]).is_err());
        }
        for offset in [0, 4, 8, 12, 16, 20, 22, 24, 28, 32, 34, 36, 40] {
            let mut bad = valid.clone();
            bad[offset] ^= 0xff;
            assert!(validate(&bad).is_err(), "offset {offset}");
        }
        let mut bad = valid;
        bad.extend_from_slice(b"unparsed");
        assert!(validate(&bad).is_err());
    }
}
