//! live-tool <seconds> <out.f32>: тон 440 Гц, амплитуда 0.05 (чётные секунды) / 0.5 (нечётные),
//! вывод на устройство по умолчанию, loopback того же устройства пишется в файл, RMS по секундам в stdout.
use std::io::Write;
use windows::core::Result;
use windows::Win32::Media::Audio::*;
use windows::Win32::System::Com::*;

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let secs: usize = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(8);
    let out = args.get(2).cloned().unwrap_or("loop.f32".into());
    unsafe {
        CoInitializeEx(None, COINIT_MULTITHREADED).ok()?;
        let en: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
        let dev = en.GetDefaultAudioEndpoint(eRender, eConsole)?;
        let rc: IAudioClient = dev.Activate(CLSCTX_ALL, None)?;
        let fmt = rc.GetMixFormat()?;
        let (ch, rate, bits, tag) = ((*fmt).nChannels as usize, (*fmt).nSamplesPerSec as usize, (*fmt).wBitsPerSample, (*fmt).wFormatTag);
        println!("format: tag=0x{tag:x} channels={ch} rate={rate} bits={bits}");
        assert!(bits == 32, "expected float32 mix format");
        rc.Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 10_000_000, 0, fmt, None)?;
        let cc: IAudioClient = dev.Activate(CLSCTX_ALL, None)?;
        cc.Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 10_000_000, 0, fmt, None)?;
        let render: IAudioRenderClient = rc.GetService()?;
        let cap: IAudioCaptureClient = cc.GetService()?;
        let total = rc.GetBufferSize()?;
        cc.Start()?;
        rc.Start()?;
        let mut phase = 0usize; // rendered frames
        let mut captured: Vec<f32> = Vec::new();
        let end = secs * rate;
        let t0 = std::time::Instant::now();
        while t0.elapsed().as_secs_f32() < secs as f32 + 1.0 {
            if phase < end {
                let avail = total - rc.GetCurrentPadding()?;
                let n = (avail as usize).min(end - phase);
                if n > 0 {
                    let p = render.GetBuffer(n as u32)? as *mut f32;
                    for i in 0..n {
                        let t = (phase + i) as f32 / rate as f32;
                        let amp = if (t as usize) % 2 == 0 { 0.05 } else { 0.5 };
                        let v = amp * (2.0 * std::f32::consts::PI * 440.0 * t).sin();
                        for c in 0..ch { *p.add(i * ch + c) = v; }
                    }
                    render.ReleaseBuffer(n as u32, 0)?;
                    phase += n;
                }
            }
            while cap.GetNextPacketSize()? > 0 {
                let (mut data, mut frames, mut flags) = (std::ptr::null_mut(), 0u32, 0u32);
                cap.GetBuffer(&mut data, &mut frames, &mut flags, None, None)?;
                let n = frames as usize * ch;
                if flags & (AUDCLNT_BUFFERFLAGS_SILENT.0 as u32) != 0 { captured.extend(std::iter::repeat(0.0).take(n)); }
                else { captured.extend_from_slice(std::slice::from_raw_parts(data as *const f32, n)); }
                cap.ReleaseBuffer(frames)?;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        rc.Stop()?; cc.Stop()?;
        let mut f = std::fs::File::create(&out).unwrap();
        for s in &captured { f.write_all(&s.to_le_bytes()).unwrap(); }
        // начало захвата = первый ненулевой кадр; RMS по окнам в 1 с
        let first = captured.iter().position(|v| v.abs() > 1e-4).unwrap_or(0) / ch * ch;
        println!("captured_frames={} first_nonzero_frame={}", captured.len() / ch, first / ch);
        let win = rate * ch;
        let mut k = 0;
        while first + (k + 1) * win <= captured.len() {
            let w = &captured[first + k * win..first + (k + 1) * win];
            let rms = (w.iter().map(|v| (*v as f64).powi(2)).sum::<f64>() / w.len() as f64).sqrt();
            println!("sec {k}: in_amp={} rms={rms:.5}", if k % 2 == 0 { 0.05 } else { 0.5 });
            k += 1;
        }
    }
    Ok(())
}
