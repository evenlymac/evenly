// Выгрузка золотых векторов из Swift-реализации (Sources/EvenlyDSP/Compressor.swift).
// Запуск: gen.sh. Описание сигналов: ../README.md.
import Foundation

struct Segment: Decodable { let seconds: Int; let kind: String; let period: Int?; let amp: Float? }
struct Toggle: Decodable { let from_seconds: Int; let to_seconds: Int }
struct Scenario: Decodable {
    let name: String; let mode: String; let sample_rate: Int; let channels: Int
    let blocks: [Int]; let segments: [Segment]; let toggle_off: Toggle?
}
struct Spec: Decodable { let decimate: Int; let scenarios: [Scenario] }

func makeInput(_ sc: Scenario) -> [Float] {
    var out = [Float]()
    for seg in sc.segments {
        let n = seg.seconds * sc.sample_rate * sc.channels
        switch seg.kind {
        case "silence":
            out += [Float](repeating: 0, count: n)
        case "tri":
            let period = seg.period!, amp = seg.amp!
            for i in 0..<n {
                let p = i % period
                let v = 1 - 2 * Float(abs(2 * p - period)) / Float(period)
                out.append(v * amp)
            }
        case "noise":
            let amp = seg.amp!
            var s: UInt32 = 12345
            for _ in 0..<n {
                s = s &* 1664525 &+ 1013904223
                let v = Float(s >> 8) / 8388608 - 1
                out.append(v * amp)
            }
        default: fatalError("kind \(seg.kind)")
        }
    }
    return out
}

func mode(_ name: String) -> CompressorMode {
    switch name {
    case "universal": return .universal
    case "radio": return .radio
    case "music": return .music
    default: fatalError("mode \(name)")
    }
}

let args = CommandLine.arguments
let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let outDir = args[2]
for sc in spec.scenarios {
    let input = makeInput(sc)
    var output = [Float](repeating: 0, count: input.count)
    let norm = Normalizer(channelCount: sc.channels, sampleRate: Double(sc.sample_rate))
    norm.mode = mode(sc.mode)
    var pos = 0, bi = 0
    while pos < input.count {
        let n = min(sc.blocks[bi % sc.blocks.count], input.count - pos)
        bi += 1
        let frame = pos / sc.channels
        if let t = sc.toggle_off {
            norm.enabled = !(frame >= t.from_seconds * sc.sample_rate && frame < t.to_seconds * sc.sample_rate)
        }
        input.withUnsafeBufferPointer { ip in
            output.withUnsafeMutableBufferPointer { op in
                norm.process(channel: 0, input: ip.baseAddress! + pos, output: op.baseAddress! + pos, count: n)
            }
        }
        pos += n
    }
    var data = Data()
    for i in stride(from: 0, to: output.count, by: spec.decimate) {
        var bits = output[i].bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    try data.write(to: URL(fileURLWithPath: "\(outDir)/\(sc.name).f32"))
    print("\(sc.name): \(input.count) samples, \(data.count / 4) golden")
}
