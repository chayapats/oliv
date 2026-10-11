//! Pure microphone gates; no device or inference dependencies.
pub const RATE: usize = 16_000;
pub const MAX_SAMPLES: usize = RATE * 600;

pub fn is_silent(samples: &[f32]) -> bool {
    if samples.len() < 2400 {
        return true;
    }
    let speech_frames = samples
        .as_chunks::<480>()
        .0
        .iter()
        .filter(|frame| {
            // Python squares in float32, then accumulates in float64.
            let square: f64 = frame.iter().map(|x| f64::from(x * x)).sum();
            (square / 480.0).sqrt() >= 0.005
        })
        .count();
    speech_frames as f64 * 0.03 < 0.15
}

pub fn implausible_length(text: &str, duration: Option<f64>) -> bool {
    let Some(duration) = duration.filter(|d| d.is_finite() && *d > 0.0) else {
        return false;
    };
    text.chars().filter(|c| !crate::pyu::is_space(*c)).count()
        > 48usize.max((duration * 28.0) as usize + 16)
}
