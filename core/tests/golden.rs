//! Сверка с эталоном, выгруженным из Swift-реализации (core/golden, см. golden/README.md).
use evenly_dsp::{Mode, Normalizer};
use serde::Deserialize;

#[derive(Deserialize)]
struct Segment { seconds: usize, kind: String, period: Option<usize>, amp: Option<f32> }
#[derive(Deserialize)]
struct Toggle { from_seconds: usize, to_seconds: usize }
#[derive(Deserialize)]
struct Scenario {
    name: String, mode: String, sample_rate: usize, channels: usize,
    blocks: Vec<usize>, segments: Vec<Segment>, toggle_off: Option<Toggle>,
}
#[derive(Deserialize)]
struct Spec { decimate: usize, scenarios: Vec<Scenario> }

fn make_input(sc: &Scenario) -> Vec<f32> {
    let mut out = Vec::new();
    for seg in &sc.segments {
        let n = seg.seconds * sc.sample_rate * sc.channels;
        match seg.kind.as_str() {
            "silence" => out.extend(std::iter::repeat(0.0f32).take(n)),
            "tri" => {
                let period = seg.period.unwrap();
                let amp = seg.amp.unwrap();
                for i in 0..n {
                    let p = (i % period) as i64;
                    let v = 1.0f32 - 2.0f32 * ((2 * p - period as i64).abs() as f32) / period as f32;
                    out.push(v * amp);
                }
            }
            "noise" => {
                let amp = seg.amp.unwrap();
                let mut s: u32 = 12345;
                for _ in 0..n {
                    s = s.wrapping_mul(1664525).wrapping_add(1013904223);
                    let v = (s >> 8) as f32 / 8388608.0 - 1.0;
                    out.push(v * amp);
                }
            }
            k => panic!("kind {k}"),
        }
    }
    out
}

fn mode(name: &str) -> Mode {
    match name {
        "universal" => Mode::UNIVERSAL,
        "radio" => Mode::RADIO,
        "music" => Mode::MUSIC,
        m => panic!("mode {m}"),
    }
}

#[test]
fn matches_swift_golden_vectors() {
    let dir = std::env::var("EVENLY_GOLDEN_DIR").unwrap_or_else(|_| concat!(env!("CARGO_MANIFEST_DIR"), "/golden").to_string());
    let spec: Spec = serde_json::from_slice(&std::fs::read(format!("{dir}/scenarios.json")).unwrap()).unwrap();
    for sc in &spec.scenarios {
        let input = make_input(sc);
        let mut buf = input.clone();
        let mut norm = Normalizer::new(sc.channels, sc.sample_rate as f64);
        norm.mode = mode(&sc.mode);
        let (mut pos, mut bi) = (0usize, 0usize);
        while pos < buf.len() {
            let n = sc.blocks[bi % sc.blocks.len()].min(buf.len() - pos);
            bi += 1;
            let frame = pos / sc.channels;
            if let Some(t) = &sc.toggle_off {
                norm.enabled = !(frame >= t.from_seconds * sc.sample_rate && frame < t.to_seconds * sc.sample_rate);
            }
            norm.process_interleaved(&mut buf[pos..pos + n]);
            pos += n;
        }
        let gold = std::fs::read(format!("{dir}/{}.f32", sc.name)).unwrap();
        let gold: Vec<f32> = gold.chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect();
        let mine: Vec<f32> = buf.iter().step_by(spec.decimate).copied().collect();
        assert_eq!(mine.len(), gold.len(), "{}: длина", sc.name);
        let (mut max_diff, mut at) = (0.0f32, 0usize);
        for (i, (a, b)) in mine.iter().zip(gold.iter()).enumerate() {
            let d = (a - b).abs();
            if d > max_diff { max_diff = d; at = i; }
        }
        println!("{}: max diff {:e} at {}", sc.name, max_diff, at * spec.decimate);
        assert!(max_diff <= 1e-5, "{}: расхождение {:e} на сэмпле {}", sc.name, max_diff, at * spec.decimate);
    }
}
