pub const RATE: u32 = 16_000;
// 16-bit PCM WAV encoding for what `capture` records (16 kHz mono).

const HEADER: usize = 44;

/// Match the Mac capture's Float32 to PCM16 clamping and rounding.
pub fn encode_float(samples: &[f32]) -> Result<Vec<u8>, &'static str> {
    encode_float_limited(samples, 1_920_000)
}

pub fn encode_float_limited(samples: &[f32], limit: usize) -> Result<Vec<u8>, &'static str> {
    if samples.is_empty() {
        return Err("emptyAudio");
    }
    if samples.len() > limit {
        return Err("audioTooLong");
    }
    let pcm: Vec<i16> = samples
        .iter()
        .map(|sample| {
            let value = if sample.is_finite() {
                sample.clamp(-1.0, 1.0)
            } else {
                0.0
            };
            (value * 32768.0).round().clamp(-32768.0, 32767.0) as i16
        })
        .collect();
    Ok(encode(&pcm, RATE))
}

/// A canonical 44-byte-header WAV holding `samples` as mono 16-bit PCM.
pub fn encode(samples: &[i16], rate: u32) -> Vec<u8> {
    let data_len = (samples.len() * 2) as u32;
    let mut out = Vec::with_capacity(HEADER + data_len as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_len).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes()); // fmt chunk size
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&rate.to_le_bytes());
    out.extend_from_slice(&(rate * 2).to_le_bytes()); // byte rate
    out.extend_from_slice(&2u16.to_le_bytes()); // block align
    out.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    for s in samples {
        out.extend_from_slice(&s.to_le_bytes());
    }
    out
}

/// Seconds of audio in a WAV `encode` made at `RATE`.
pub fn seconds(wav: &[u8]) -> f64 {
    wav.len().saturating_sub(HEADER) as f64 / f64::from(RATE * 2)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u32_at(b: &[u8], i: usize) -> u32 {
        u32::from_le_bytes(b[i..i + 4].try_into().unwrap())
    }
    fn u16_at(b: &[u8], i: usize) -> u16 {
        u16::from_le_bytes(b[i..i + 2].try_into().unwrap())
    }

    #[test]
    fn header_and_samples() {
        let w = encode(&[0, 1, -1, i16::MAX, i16::MIN], 16_000);
        assert_eq!(w.len(), 44 + 10);
        assert_eq!(&w[0..4], b"RIFF");
        assert_eq!(u32_at(&w, 4), 36 + 10);
        assert_eq!(&w[8..16], b"WAVEfmt ");
        assert_eq!(u32_at(&w, 16), 16);
        assert_eq!(u16_at(&w, 20), 1);
        assert_eq!(u16_at(&w, 22), 1);
        assert_eq!(u32_at(&w, 24), 16_000);
        assert_eq!(u32_at(&w, 28), 32_000);
        assert_eq!(u16_at(&w, 32), 2);
        assert_eq!(u16_at(&w, 34), 16);
        assert_eq!(&w[36..40], b"data");
        assert_eq!(u32_at(&w, 40), 10);
        assert_eq!(&w[44..], &[0, 0, 1, 0, 0xff, 0xff, 0xff, 0x7f, 0x00, 0x80]);
    }

    #[test]
    fn seconds_of_audio() {
        assert_eq!(seconds(&encode(&[0; 16_000], 16_000)), 1.0);
        assert_eq!(seconds(&[]), 0.0);
    }

    #[test]
    fn empty() {
        let w = encode(&[], 16_000);
        assert_eq!(w.len(), 44);
        assert_eq!(u32_at(&w, 40), 0);
    }

    #[test]
    fn captured_float_clamps_sanitizes_and_obeys_provider_limits() {
        let w = encode_float(&[
            -2.0,
            2.0,
            f32::NAN,
            f32::INFINITY,
            0.5 / 32768.0,
            -0.5 / 32768.0,
        ])
        .unwrap();
        let pcm: Vec<i16> = w[44..]
            .as_chunks::<2>()
            .0
            .iter()
            .map(|b| i16::from_le_bytes([b[0], b[1]]))
            .collect();
        assert_eq!(pcm, [-32768, 32767, 0, 0, 1, -1]);
        assert_eq!(encode_float(&[]), Err("emptyAudio"));
        let samples = vec![0.0; 1_920_001];
        assert_eq!(encode_float(&samples), Err("audioTooLong"));
        assert!(encode_float_limited(&samples, 9_600_000).is_ok());
    }
}
