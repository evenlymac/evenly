#![allow(clippy::chunks_exact_to_as_chunks)]
//! evenly-pcm: читает interleaved f32 little-endian из stdin, выравнивает громкость ядром evenly-dsp,
//! пишет в stdout. Параметры: --rate N (по умолчанию 48000), --channels N (2), --off (без обработки, только задержка).

use evenly_dsp::Normalizer;
use std::io::{self, Read, Write};

struct Opts {
    rate: f64,
    channels: usize,
    off: bool,
    off_file: Option<std::path::PathBuf>,
}

fn parse(args: &[String]) -> Result<Opts, String> {
    let mut o = Opts { rate: 48000.0, channels: 2, off: false, off_file: None };
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--rate" => {
                i += 1;
                o.rate = args.get(i).and_then(|v| v.parse().ok()).filter(|v: &f64| *v >= 8000.0 && *v <= 384000.0).ok_or("--rate: 8000..384000")?;
            }
            "--channels" => {
                i += 1;
                o.channels = args.get(i).and_then(|v| v.parse().ok()).filter(|v: &usize| (1..=8).contains(v)).ok_or("--channels: 1..8")?;
            }
            "--off" => o.off = true,
            "--off-file" => {
                i += 1;
                o.off_file = Some(args.get(i).ok_or("--off-file: нужен путь")?.into());
            }
            other => return Err(format!("неизвестный параметр {other}")),
        }
        i += 1;
    }
    Ok(o)
}

/// Обрабатывает поток целыми кадрами; хвост, не кратный кадру, переносится в следующее чтение.
pub fn run<R: Read, W: Write>(input: R, output: W, rate: f64, channels: usize, off: bool) -> io::Result<()> {
    run_with(input, output, rate, channels, off, None)
}

/// Как `run`, плюс выключатель на лету: пока существует `off_file`, обработка отключена (звук идёт без остановки потока).
pub fn run_with<R: Read, W: Write>(
    mut input: R,
    mut output: W,
    rate: f64,
    channels: usize,
    off: bool,
    off_file: Option<&std::path::Path>,
) -> io::Result<()> {
    let mut n = Normalizer::new(channels, rate);
    n.enabled = !off;
    let frame_bytes = 4 * channels;
    let mut raw = vec![0u8; frame_bytes * 1024];
    let mut have = 0usize;
    let mut samples: Vec<f32> = Vec::new();
    loop {
        let got = match input.read(&mut raw[have..]) {
            Ok(0) => break,
            Ok(g) => g,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        have += got;
        let whole = have / frame_bytes * frame_bytes;
        if whole == 0 {
            continue;
        }
        if let Some(f) = off_file {
            n.enabled = !(off || f.exists());
        }
        samples.clear();
        samples.extend(raw[..whole].chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])));
        n.process_interleaved(&mut samples);
        evenly_dsp::clip_output(&mut samples);
        let mut out = Vec::with_capacity(whole);
        for s in &samples {
            out.extend_from_slice(&s.to_le_bytes());
        }
        output.write_all(&out)?;
        output.flush()?;
        raw.copy_within(whole..have, 0);
        have -= whole;
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let o = match parse(&args) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("evenly-pcm: {e}");
            std::process::exit(2);
        }
    };
    let stdout = io::stdout();
    match run_with(io::stdin().lock(), stdout.lock(), o.rate, o.channels, o.off, o.off_file.as_deref()) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::BrokenPipe => {}
        Err(e) => {
            eprintln!("evenly-pcm: {e}");
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(amp: f32, frames: usize, ch: usize) -> Vec<u8> {
        let mut v = Vec::new();
        for i in 0..frames {
            let s = amp * (2.0 * std::f32::consts::PI * 440.0 * i as f32 / 48000.0).sin();
            for _ in 0..ch {
                v.extend_from_slice(&s.to_le_bytes());
            }
        }
        v
    }

    fn peak_tail(b: &[u8], n: usize) -> f32 {
        b[b.len() - n * 4..].chunks_exact(4).fold(0.0, |m, c| m.max(f32::from_le_bytes([c[0], c[1], c[2], c[3]]).abs()))
    }

    #[test]
    fn quiet_is_boosted_and_length_kept() {
        let x = tone(0.01, 48000 * 20, 2);
        let mut y = Vec::new();
        run(&x[..], &mut y, 48000.0, 2, false).unwrap();
        assert_eq!(x.len(), y.len());
        assert!(peak_tail(&y, 9600) > 0.03);
    }

    #[test]
    fn loud_is_limited() {
        let x = tone(1.0, 48000 * 2, 2);
        let mut y = Vec::new();
        run(&x[..], &mut y, 48000.0, 2, false).unwrap();
        assert!(peak_tail(&y, 9600) <= 1.0);
    }

    #[test]
    fn off_keeps_level() {
        let x = tone(0.01, 48000 * 5, 2);
        let mut y = Vec::new();
        run(&x[..], &mut y, 48000.0, 2, true).unwrap();
        assert!(peak_tail(&y, 9600) < 0.011);
    }

    /// Читатель отдаёт по 7 байт: кадры не кратны чтению, результат должен совпасть с чтением целиком.
    struct Slow<'a>(&'a [u8]);
    impl Read for Slow<'_> {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            let n = 7.min(self.0.len()).min(buf.len());
            buf[..n].copy_from_slice(&self.0[..n]);
            self.0 = &self.0[n..];
            Ok(n)
        }
    }

    #[test]
    fn partial_reads_keep_all_frames() {
        let x = tone(0.2, 5000, 2);
        let mut y = Vec::new();
        run(Slow(&x), &mut y, 48000.0, 2, false).unwrap();
        assert_eq!(x.len(), y.len());
    }

    #[test]
    fn bad_args_rejected() {
        assert!(parse(&["--rate".into(), "5".into()]).is_err());
        assert!(parse(&["--channels".into(), "0".into()]).is_err());
        assert!(parse(&["--x".into()]).is_err());
    }

    #[test]
    fn off_file_switches_processing_live() {
        let path = std::env::temp_dir().join(format!("evenly-off-test-{}", std::process::id()));
        std::fs::write(&path, b"").unwrap();
        let input = tone(0.01, 48000, 2);
        let mut out = Vec::new();
        run_with(&input[..], &mut out, 48000.0, 2, false, Some(&path)).unwrap();
        let _ = std::fs::remove_file(&path);
        assert_eq!(out.len(), input.len());
        assert!(peak_tail(&out, 4800) < 0.02, "с файлом-выключателем звук не усиливается");
        let mut out2 = Vec::new();
        run_with(&input[..], &mut out2, 48000.0, 2, false, Some(&path)).unwrap();
        assert!(peak_tail(&out2, 4800) > 0.02, "без файла тихий сигнал поднимается");
    }
}
