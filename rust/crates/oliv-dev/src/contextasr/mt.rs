//! CPython's `random.Random(seed)` (MT19937, `init_by_array`) and `randrange(n)`,
//! so bootstrap confidence intervals reproduce the upstream scorer's draws.
const N: usize = 624;
const M: usize = 397;

pub struct PyRandom {
    mt: [u32; N],
    index: usize,
}
impl PyRandom {
    /// `random.Random(seed)` for a non-negative seed below 2^32.
    pub fn new(seed: u32) -> Self {
        let mut mt = [0u32; N];
        mt[0] = 19_650_218;
        for i in 1..N {
            mt[i] = 1_812_433_253u32
                .wrapping_mul(mt[i - 1] ^ (mt[i - 1] >> 30))
                .wrapping_add(i as u32);
        }
        let key = [seed];
        let (mut i, mut j) = (1usize, 0usize);
        for _ in 0..N.max(key.len()) {
            mt[i] = (mt[i] ^ (mt[i - 1] ^ (mt[i - 1] >> 30)).wrapping_mul(1_664_525))
                .wrapping_add(key[j])
                .wrapping_add(j as u32);
            i += 1;
            j += 1;
            if i >= N {
                mt[0] = mt[N - 1];
                i = 1;
            }
            if j >= key.len() {
                j = 0;
            }
        }
        for _ in 0..N - 1 {
            mt[i] = (mt[i] ^ (mt[i - 1] ^ (mt[i - 1] >> 30)).wrapping_mul(1_566_083_941))
                .wrapping_sub(i as u32);
            i += 1;
            if i >= N {
                mt[0] = mt[N - 1];
                i = 1;
            }
        }
        mt[0] = 0x8000_0000;
        Self { mt, index: N }
    }

    fn next_u32(&mut self) -> u32 {
        if self.index >= N {
            for k in 0..N {
                let y = (self.mt[k] & 0x8000_0000) | (self.mt[(k + 1) % N] & 0x7fff_ffff);
                let mag = if y & 1 == 1 { 0x9908_b0df } else { 0 };
                self.mt[k] = self.mt[(k + M) % N] ^ (y >> 1) ^ mag;
            }
            self.index = 0;
        }
        let mut y = self.mt[self.index];
        self.index += 1;
        y ^= y >> 11;
        y ^= (y << 7) & 0x9d2c_5680;
        y ^= (y << 15) & 0xefc6_0000;
        y ^ (y >> 18)
    }

    /// `randrange(n)` via `_randbelow_with_getrandbits` for 0 < n < 2^32.
    pub fn randrange(&mut self, n: usize) -> usize {
        assert!(n > 0 && n <= u32::MAX as usize);
        let k = usize::BITS - n.leading_zeros();
        loop {
            let r = (self.next_u32() >> (32 - k)) as usize;
            if r < n {
                return r;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::PyRandom;
    #[test]
    fn matches_cpython_random_2026() {
        // python3 -c "import random; r=random.Random(2026); print([r.randrange(n) for n in (10,2062,1678,1,7,1000,3)])"
        let mut r = PyRandom::new(2026);
        let got: Vec<usize> = [10, 2062, 1678, 1, 7, 1000, 3]
            .iter()
            .map(|n| r.randrange(*n))
            .collect();
        assert_eq!(got, EXPECTED);
    }
    const EXPECTED: [usize; 7] = [1, 1308, 1029, 0, 1, 916, 2];
}
