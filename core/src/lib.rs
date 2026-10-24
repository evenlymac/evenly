//! Evenly: ядро нормализации громкости. Порт `Sources/EvenlyDSP/Compressor.swift`:
//! порядок операций с f32 сохранён как в Swift, чтобы выход совпадал с macOS-версией
//! (проверка по «золотым» векторам, см. `golden/README.md`).

/// Режим: makeup / push / speed.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Mode {
    pub makeup: f32,
    pub push: f32,
    pub speed: f32,
}

impl Mode {
    pub const OFF: Mode = Mode { makeup: 1.0, push: 0.0, speed: 0.0 };
    pub const MUSIC: Mode = Mode { makeup: 1.0, push: 1.0, speed: 0.0 };
    pub const MOVIE: Mode = Mode { makeup: 1.0, push: 0.7, speed: 0.3 };
    pub const VOICE: Mode = Mode { makeup: 1.0, push: 0.8, speed: 0.3 };
    /// Единый режим продукта (как `CompressorMode.universal` в Swift).
    pub const UNIVERSAL: Mode = Mode { makeup: 1.0, push: 1.0, speed: 0.15 };
    pub const RADIO: Mode = Mode { makeup: 0.88, push: 0.9, speed: 1.0 };
}

const ATTACK_RATE: f32 = 0.015;
const RELEASE_RATE: f32 = 5e-7;
const RELEASE_CALIBRATION: f32 = 1.3;
const MAXIMUM_GAIN: f32 = 100.0;
const KNEE_MAX: f32 = 200.0;

/// Нормализатор одного потока сэмплов: опережение 512 кадров, подъём тихого, ограничение громкого у порога 0.9.
pub struct ChannelCompressor {
    delay: Vec<f32>,
    write_index: usize,
    gain: f32,
    release_knee: f32,
    push: f32,
    scale: f32,
}

impl ChannelCompressor {
    pub const LOOKAHEAD: usize = 512;

    pub fn new(sample_rate: f64) -> Self {
        ChannelCompressor {
            delay: vec![0.0; Self::LOOKAHEAD],
            write_index: 0,
            gain: 1.0,
            release_knee: 1.0,
            push: 0.0,
            scale: (44100.0 / sample_rate) as f32,
        }
    }

    pub fn current_gain(&self) -> f32 {
        self.gain
    }

    /// Блок на месте. Как в Swift, усиление «k» (есть ли сигнал) считается по всему блоку,
    /// поэтому границы блоков влияют на результат одинаково на обеих платформах.
    pub fn process_in_place(&mut self, buf: &mut [f32], mode: Mode, target_push: f32) {
        let k = Self::block_k(buf);
        let p = self.params(mode, target_push);
        for v in buf.iter_mut() {
            *v = self.step(*v, k, &p);
        }
    }

    /// Блок из `input` в `output` (длины должны совпадать).
    pub fn process(&mut self, input: &[f32], output: &mut [f32], mode: Mode, target_push: f32) {
        assert_eq!(input.len(), output.len());
        let k = Self::block_k(input);
        let p = self.params(mode, target_push);
        for (o, &a) in output.iter_mut().zip(input.iter()) {
            *o = self.step(a, k, &p);
        }
    }

    fn block_k(block: &[f32]) -> f32 {
        let mut energy: f32 = 0.0;
        for &x in block {
            energy += x.abs();
        }
        if energy > 0.0 { 1.0 } else { 0.01 }
    }

    fn params(&self, mode: Mode, target_push: f32) -> Params {
        let one_minus = 1.0 - target_push;
        let threshold = if 0.9 > one_minus { 0.9 } else { one_minus };
        let speed_factor = (1.0 - mode.speed).max(0.005).min(1.0);
        Params { threshold, speed_factor, makeup: mode.makeup, target_push }
    }

    #[inline]
    fn step(&mut self, a: f32, k: f32, p: &Params) -> f32 {
        let s = self.scale;
        let d = self.delay[self.write_index];
        self.delay[self.write_index] = a;
        self.write_index += 1;
        if self.write_index == Self::LOOKAHEAD {
            self.write_index = 0;
        }

        if self.push < p.target_push {
            self.push = (self.push + s * 0.01).min(p.target_push);
        } else if self.push > p.target_push {
            self.push = (self.push - s * 0.01).max(p.target_push);
        }

        let g_prev = self.gain;
        if (a * self.gain).abs() > p.threshold {
            let m = if self.gain > 1.0 { self.gain } else { 1.0 };
            self.gain -= m * s * ATTACK_RATE;
            if self.gain < 0.0 {
                self.gain = 0.0;
            }
            if self.release_knee > 1.0 {
                self.release_knee -= 5.0;
            }
            if self.release_knee < 1.0 {
                self.release_knee = 1.0;
            }
        } else {
            self.gain += k * s * RELEASE_RATE * RELEASE_CALIBRATION * self.release_knee / p.speed_factor;
            if self.gain > MAXIMUM_GAIN {
                self.gain = MAXIMUM_GAIN;
            }
            if self.release_knee < KNEE_MAX {
                self.release_knee += 0.1;
            }
        }

        let processed = d * ((g_prev - 0.15) + 1.0) / 2.0 * p.makeup;
        let mix = self.push.max(0.0).min(1.0);
        d * (1.0 - mix) + processed * mix
    }
}

struct Params {
    threshold: f32,
    speed_factor: f32,
    makeup: f32,
    target_push: f32,
}

/// Обёртка как `Normalizer` в Swift: ОДНО состояние на все каналы, блок обрабатывается как поток
/// interleaved-сэмплов (поэтому скорости растут пропорционально числу каналов; поведение macOS-версии).
pub struct Normalizer {
    pub mode: Mode,
    pub enabled: bool,
    channel_count: usize,
    comp: ChannelCompressor,
}

impl Normalizer {
    pub fn new(channel_count: usize, sample_rate: f64) -> Self {
        Normalizer {
            mode: Mode::UNIVERSAL,
            enabled: true,
            channel_count,
            comp: ChannelCompressor::new(sample_rate),
        }
    }

    pub fn channel_count(&self) -> usize {
        self.channel_count
    }

    pub fn gain(&self) -> f32 {
        self.comp.current_gain()
    }

    /// Блок interleaved-сэмплов (кадры * каналы) на месте.
    pub fn process_interleaved(&mut self, buf: &mut [f32]) {
        let target = if self.enabled { self.mode.push } else { 0.0 };
        self.comp.process_in_place(buf, self.mode, target);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SR: f64 = 44100.0;

    fn sine(amp: f32, frames: usize) -> Vec<f32> {
        (0..frames).map(|i| amp * (2.0 * std::f32::consts::PI * 440.0 * i as f32 / SR as f32).sin()).collect()
    }

    fn run(c: &mut ChannelCompressor, x: &[f32], push: f32) -> Vec<f32> {
        let mut out = vec![0.0; x.len()];
        let mut i = 0;
        while i < x.len() {
            let n = 512.min(x.len() - i);
            c.process(&x[i..i + n], &mut out[i..i + n], Mode::MUSIC, push);
            i += n;
        }
        out
    }

    fn peak(x: &[f32]) -> f32 {
        x.iter().fold(0.0, |m, v| m.max(v.abs()))
    }

    #[test]
    fn quiet_signal_is_boosted() {
        let mut c = ChannelCompressor::new(SR);
        let y = run(&mut c, &sine(0.01, 44100 * 20), 1.0);
        assert!(peak(&y[y.len() - 4410..]) > 0.03, "тихий сигнал должен подниматься");
        assert!(peak(&y) <= 1.0);
    }

    #[test]
    fn loud_signal_limited_near_threshold() {
        let mut c = ChannelCompressor::new(SR);
        let y = run(&mut c, &sine(1.0, 44100 * 2), 1.0);
        assert!(peak(&y[y.len() - 8820..]) <= 1.0);
        assert!(c.current_gain() < 1.0, "громкий сигнал опускает gain");
    }

    #[test]
    fn step_down_is_released_slowly() {
        let mut c = ChannelCompressor::new(SR);
        let mut x = sine(1.0, 44100);
        x.extend(sine(0.05, 44100 * 3));
        let y = run(&mut c, &x, 1.0);
        let right = peak(&y[44100 + 4410..44100 + 8820]);
        let later = peak(&y[y.len() - 4410..]);
        assert!(right < later, "gain растёт постепенно после громкого");
    }

    #[test]
    fn push_zero_is_dry_delayed() {
        let mut c = ChannelCompressor::new(SR);
        let x = sine(0.3, 4096);
        let y = run(&mut c, &x, 0.0);
        for i in 600..4096 {
            assert!((y[i] - x[i - ChannelCompressor::LOOKAHEAD]).abs() < 1e-5);
        }
    }

    #[test]
    fn silence_stays_silent() {
        let mut c = ChannelCompressor::new(SR);
        let y = run(&mut c, &vec![0.0; 44100], 1.0);
        assert_eq!(peak(&y), 0.0);
    }

    #[test]
    fn sample_rate_scales_rates() {
        let mut c44 = ChannelCompressor::new(44100.0);
        let mut c48 = ChannelCompressor::new(48000.0);
        run(&mut c44, &sine(0.01, 44100 * 5), 1.0);
        let x48: Vec<f32> = (0..48000 * 5).map(|i| 0.01 * (2.0 * std::f32::consts::PI * 440.0 * i as f32 / 48000.0).sin()).collect();
        let mut out = vec![0.0; x48.len()];
        c48.process(&x48, &mut out, Mode::MUSIC, 1.0);
        let g = c44.current_gain();
        assert!((c48.current_gain() - g).abs() < g * 0.1);
    }

    #[test]
    fn universal_is_between_music_and_movie_speed() {
        assert!(Mode::UNIVERSAL.speed > Mode::MUSIC.speed);
        assert!(Mode::UNIVERSAL.speed < Mode::MOVIE.speed);
        assert_eq!(Mode::UNIVERSAL.push, 1.0);
        assert_eq!(Normalizer::new(2, 44100.0).mode, Mode::UNIVERSAL);
    }
}
