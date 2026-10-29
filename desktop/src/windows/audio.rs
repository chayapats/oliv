//! Bounded, streaming conversion from device audio to the existing WAV format.
//! Kept independent of WASAPI so the conversion is testable on any host.

pub const RATE: u32 = 16_000;
pub const MAX_SAMPLES: usize = RATE as usize * 120;
const LEVEL_WINDOW: usize = RATE as usize / 24;

pub struct Buf {
    pub samples: Vec<i16>,
    cap: usize,
    sum_sq: f64,
    n: usize,
    pub level: f32,
}

impl Buf {
    pub fn new(cap: usize) -> Self {
        Self {
            // Allocate once, before starting the audio callback.
            samples: Vec::with_capacity(cap),
            cap,
            sum_sq: 0.0,
            n: 0,
            level: 0.0,
        }
    }

    pub fn full(&self) -> bool {
        self.samples.len() >= self.cap
    }

    /// Append what fits; report only the transition to full.
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

const BASE_TAPS: usize = 64;
const PHASES: usize = 256;
const MAX_INPUT_RATE: u32 = 384_000;

/// A windowed-sinc low-pass resampler. Coefficients and output storage are
/// allocated before capture; per-callback work requires no allocations.
///
/// Integer phase accumulation prevents drift at rates such as 44.1 kHz. The
/// causal filter has less than 4 ms delay at supported audio rates (8–384 kHz).
/// The tap count scales with input rate so high-rate devices retain the same
/// suppression of frequencies above the output Nyquist limit. Even at 384 kHz,
/// filter storage is bounded to approximately 512 KiB, allocated before capture.
pub(super) struct Converter {
    pub output: Buf,
    channels: usize,
    channel_sum: f64,
    channel_count: usize,
    input_rate: u32,
    input_frames: u64,
    next_output: u64,
    ring: Vec<f32>,
    write: usize,
    kernels: Vec<Vec<f32>>,
}

impl Converter {
    pub fn new(input_rate: u32, channels: usize, cap: usize) -> Result<Self, String> {
        if input_rate == 0 || channels == 0 {
            return Err("microphone returned a zero sample rate or channel count".into());
        }
        if input_rate > MAX_INPUT_RATE {
            return Err(format!(
                "microphone sample rate {input_rate} Hz exceeds the supported 384000 Hz maximum"
            ));
        }
        let taps = BASE_TAPS * (input_rate as usize).div_ceil(48_000);
        let kernels = if input_rate == RATE {
            Vec::new()
        } else {
            let cutoff = (f64::from(RATE) / f64::from(input_rate)).min(1.0) * 0.45;
            (0..PHASES)
                .map(|phase| {
                    let mut kernel = vec![0.0; taps];
                    let center = (taps / 2 - 1) as f64 + phase as f64 / PHASES as f64;
                    let mut sum = 0.0;
                    for (i, tap) in kernel.iter_mut().enumerate() {
                        let x = i as f64 - center;
                        let sinc = if x.abs() < 1e-12 {
                            2.0 * cutoff
                        } else {
                            (2.0 * std::f64::consts::PI * cutoff * x).sin()
                                / (std::f64::consts::PI * x)
                        };
                        let angle = 2.0 * std::f64::consts::PI * i as f64 / (taps - 1) as f64;
                        let window = 0.42 - 0.5 * angle.cos() + 0.08 * (2.0 * angle).cos();
                        *tap = (sinc * window) as f32;
                        sum += *tap;
                    }
                    for tap in &mut kernel {
                        *tap /= sum;
                    }
                    kernel
                })
                .collect()
        };
        Ok(Self {
            output: Buf::new(cap),
            channels,
            channel_sum: 0.0,
            channel_count: 0,
            input_rate,
            input_frames: 0,
            next_output: 0,
            ring: vec![0.0; taps],
            write: 0,
            kernels,
        })
    }

    /// Interleaved normalized device samples, including incomplete frames.
    /// Returns true exactly once when the output reaches its cap.
    pub fn push(&mut self, samples: impl IntoIterator<Item = f32>) -> bool {
        if self.output.full() {
            return false;
        }
        for sample in samples {
            let sample = if sample.is_finite() { sample } else { 0.0 };
            self.channel_sum += f64::from(sample.clamp(-1.0, 1.0));
            self.channel_count += 1;
            if self.channel_count != self.channels {
                continue;
            }
            let mono = (self.channel_sum / self.channels as f64) as f32;
            self.channel_sum = 0.0;
            self.channel_count = 0;
            if self.push_frame(mono) {
                return true;
            }
        }
        false
    }

    fn push_frame(&mut self, mono: f32) -> bool {
        if self.input_rate == RATE {
            return self.output.push(&[pcm(mono)]);
        }
        self.ring[self.write] = mono;
        let taps = self.ring.len();
        self.write = (self.write + 1) % taps;
        let now = self.input_frames * u64::from(RATE);
        self.input_frames += 1;
        while self.next_output <= now {
            let phase = ((now - self.next_output) * PHASES as u64 / u64::from(RATE)) as usize;
            let mut sample = 0.0;
            for (i, coefficient) in self.kernels[phase].iter().enumerate() {
                sample += self.ring[(self.write + taps - 1 - i) % taps] * coefficient;
            }
            self.next_output += u64::from(self.input_rate);
            if self.output.push(&[pcm(sample)]) {
                return true;
            }
        }
        false
    }
}

fn pcm(sample: f32) -> i16 {
    (sample.clamp(-1.0, 1.0) * 32768.0).round() as i16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn common_rates_preserve_duration_and_chunk_boundaries() {
        for rate in [8_000, 16_000, 44_100, 48_000, 96_000, 192_000] {
            let input: Vec<f32> = (0..rate * 2)
                .map(|i| (i as f32 * 0.1).sin() * 0.3)
                .collect();
            let mut whole = Converter::new(rate, 2, MAX_SAMPLES).unwrap();
            whole.push(input.iter().copied());
            let mut split = Converter::new(rate, 2, MAX_SAMPLES).unwrap();
            // Odd chunks deliberately split stereo frames.
            for chunk in input.chunks(127) {
                split.push(chunk.iter().copied());
            }
            // A causal resampler can be one sample short at the very end when
            // upsampling; it must never drift beyond one output sample.
            assert!((whole.output.samples.len() as i64 - RATE as i64).abs() <= 1);
            assert_eq!(whole.output.samples, split.output.samples, "{rate} Hz");
        }
    }

    #[test]
    fn stereo_downmix_and_pcm_levels() {
        let mut converter = Converter::new(RATE, 2, 10).unwrap();
        converter.push([0.75, -0.25, 1.0, -1.0, -1.0, -1.0, 1.0, 1.0]);
        assert_eq!(converter.output.samples, [8192, 0, i16::MIN, i16::MAX]);
    }

    #[test]
    fn suppresses_aliasing_while_preserving_speech_band() {
        fn tone_rms(frequency: f32, rate: u32) -> f32 {
            let mut c = Converter::new(rate, 1, MAX_SAMPLES).unwrap();
            c.push((0..rate).map(|i| {
                (2.0 * std::f64::consts::PI * f64::from(frequency) * f64::from(i) / f64::from(rate))
                    .sin() as f32
            }));
            let samples = &c.output.samples[100..];
            (samples
                .iter()
                .map(|s| (f32::from(*s) / 32768.0).powi(2))
                .sum::<f32>()
                / samples.len() as f32)
                .sqrt()
        }
        for rate in [44_100, 48_000, 96_000, 192_000, 384_000] {
            assert!(
                (tone_rms(1_000.0, rate) - std::f32::consts::FRAC_1_SQRT_2).abs() < 0.01,
                "{rate} Hz passband"
            );
            let aliased = tone_rms(12_000.0, rate);
            assert!(aliased < 0.005, "{rate} Hz has aliased RMS {aliased}");
        }
    }

    #[test]
    fn cap_is_bounded_and_signaled_once() {
        let mut c = Converter::new(48_000, 2, 100).unwrap();
        let capacity = c.output.samples.capacity();
        assert!(c.push(std::iter::repeat_n(0.25, 48_000)));
        assert_eq!(c.output.samples.len(), 100);
        assert!(!c.push(std::iter::repeat_n(0.25, 48_000)));
        assert_eq!(c.output.samples.len(), 100);
        assert_eq!(c.output.samples.capacity(), capacity);
        assert_eq!(MAX_SAMPLES, 1_920_000);
    }

    #[test]
    fn rms_updates_only_after_a_full_window() {
        let mut b = Buf::new(MAX_SAMPLES);
        assert!(!b.push(&vec![16384; LEVEL_WINDOW - 1]));
        assert_eq!(b.level, 0.0);
        b.push(&[16384]);
        assert!((b.level - 0.5).abs() < 1e-6);
        b.push(&vec![i16::MIN; LEVEL_WINDOW]);
        assert!((b.level - 1.0).abs() < 1e-6);
    }

    #[test]
    fn invalid_device_samples_and_config_are_safe() {
        assert!(Converter::new(0, 1, 10).is_err());
        assert!(Converter::new(u32::MAX, 1, 10).is_err());
        assert!(Converter::new(MAX_INPUT_RATE + 1, 1, 10).is_err());
        assert!(Converter::new(RATE, 0, 10).is_err());
        let mut c = Converter::new(RATE, 1, 10).unwrap();
        c.push([f32::NAN, f32::INFINITY, f32::NEG_INFINITY, 2.0, -2.0]);
        assert_eq!(c.output.samples, [0, 0, 0, i16::MAX, i16::MIN]);
    }

    #[test]
    fn sixteen_bit_pcm_round_trips_without_changing_samples() {
        let input: Vec<i16> = (i16::MIN..=i16::MAX).collect();
        let mut c = Converter::new(RATE, 1, input.len()).unwrap();
        assert!(c.push(input.iter().map(|s| f32::from(*s) / 32768.0)));
        assert_eq!(c.output.samples, input);
    }

    #[test]
    fn arbitrary_callback_boundaries_and_surround_channels_are_equivalent() {
        for rate in [
            1, 7_999, 8_000, 11_025, 16_001, 22_050, 32_000, 44_099, 384_000,
        ] {
            for channels in [1, 2, 6, 8] {
                let samples: Vec<_> = (0..1_027 * channels)
                    .map(|n| ((n * 379 % 65_536) as f32 - 32_768.0) / 32_768.0)
                    .collect();
                let mut whole = Converter::new(rate, channels, 5_000).unwrap();
                whole.push(samples.iter().copied());
                let mut split = Converter::new(rate, channels, 5_000).unwrap();
                let mut at = 0;
                while at < samples.len() {
                    let end = (at + (at * 73 % 97) + 1).min(samples.len());
                    assert!(!split.push([]), "empty callbacks must not signal a cap");
                    split.push(samples[at..end].iter().copied());
                    at = end;
                }
                assert_eq!(
                    whole.output.samples, split.output.samples,
                    "{rate} Hz, {channels} channels"
                );
                assert_eq!(whole.output.level, split.output.level);
            }
        }
    }

    #[test]
    fn full_two_minutes_at_cd_rate_have_no_drift_or_allocation_growth() {
        let mut c = Converter::new(44_100, 1, MAX_SAMPLES).unwrap();
        let output_address = c.output.samples.as_ptr();
        let capacity = c.output.samples.capacity();
        let mut full_signals = 0;
        // Synthetic silence, streamed without a large source allocation.
        for _ in 0..120 {
            full_signals += usize::from(c.push(std::iter::repeat_n(0.0, 44_100)));
        }
        assert_eq!(full_signals, 1);
        assert_eq!(c.output.samples.len(), MAX_SAMPLES);
        assert_eq!(c.output.samples.as_ptr(), output_address);
        assert_eq!(c.output.samples.capacity(), capacity);
        assert!(c.output.samples.iter().all(|s| *s == 0));
        assert_eq!(c.output.level, 0.0);
        // A completed recording must not even consume further device input.
        assert!(!c.push(std::iter::from_fn(|| panic!("read after full"))));
    }

    #[test]
    fn all_rates_keep_dc_level_after_startup_and_sanitize_bad_samples() {
        for rate in [
            8_000, 11_025, 22_050, 44_100, 48_000, 96_000, 192_000, 384_000,
        ] {
            let mut c = Converter::new(rate, 2, 2_000).unwrap();
            c.push([f32::NAN, f32::INFINITY, f32::NEG_INFINITY, 0.0]);
            c.push(std::iter::repeat_n(0.25, rate as usize / 5));
            assert!(c.output.samples.len() > 200);
            assert!(
                c.output.samples[200..]
                    .iter()
                    .all(|s| (*s - 8192).abs() <= 1),
                "{rate} Hz"
            );
            assert!(c.output.level.is_finite());
            assert!((c.output.level - 0.25).abs() < 0.01, "{rate} Hz");
        }
    }

    #[test]
    fn zero_cap_and_incomplete_frames_never_emit_spurious_audio() {
        let mut empty = Converter::new(48_000, 2, 0).unwrap();
        assert!(!empty.push(std::iter::from_fn(|| panic!("read with zero cap"))));
        assert!(empty.output.samples.is_empty());
        let mut c = Converter::new(RATE, 6, 10).unwrap();
        c.push([1.0; 5]);
        assert!(c.output.samples.is_empty());
        c.push([-1.0]);
        assert_eq!(c.output.samples, [21845]);
        c.push([0.5; 5]);
        assert_eq!(c.output.samples.len(), 1);
    }
}
