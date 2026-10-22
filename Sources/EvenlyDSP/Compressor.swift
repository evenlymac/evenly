import Foundation

/// Режимы Simple Compressor: makeup / push / speed (см. soundsource-ALGORITHM.md).
public struct CompressorMode: Equatable {
    public var makeup: Float
    public var push: Float
    public var speed: Float

    public init(makeup: Float, push: Float, speed: Float) {
        self.makeup = makeup
        self.push = push
        self.speed = speed
    }

    public static let off = CompressorMode(makeup: 1, push: 0, speed: 0)
    public static let music = CompressorMode(makeup: 1, push: 1, speed: 0)
    public static let movie = CompressorMode(makeup: 1, push: 0.7, speed: 0.3)
    public static let voice = CompressorMode(makeup: 1, push: 0.8, speed: 0.3)
    public static let radio = CompressorMode(makeup: 0.88, push: 0.9, speed: 1.0)
}

/// Нормализатор громкости для одного канала: опережение 512 кадров,
/// самонастраивающийся подъём тихого и ограничение громкого у порога 0.9.
public struct ChannelCompressor {
    public static let lookahead = 512
    static let attackRate: Float = 0.015
    static let releaseRate: Float = 5e-7
    static let maximumGain: Float = 100
    static let kneeMax: Float = 200

    private var delay: [Float]
    private var writeIndex = 0
    private(set) var gain: Float = 1
    private var releaseKnee: Float = 1
    private var push: Float = 0
    private let scale: Float

    public init(sampleRate: Double) {
        delay = [Float](repeating: 0, count: Self.lookahead)
        scale = Float(44100 / sampleRate)
    }

    public var currentGain: Float { gain }

    /// Обрабатывает блок на месте (in-place допустим: input и output могут совпадать).
    public mutating func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>,
                                 count: Int, mode: CompressorMode, targetPush: Float) {
        let s = scale
        let threshold = max(0.9, 1 - targetPush)
        let speedFactor = min(max(1 - mode.speed, 0.005), 1)

        var energy: Float = 0
        for i in 0..<count { energy += abs(input[i]) }
        let k: Float = energy > 0 ? 1 : 0.01

        for i in 0..<count {
            let a = input[i]
            let d = delay[writeIndex]
            delay[writeIndex] = a
            writeIndex += 1
            if writeIndex == Self.lookahead { writeIndex = 0 }

            if push < targetPush {
                push = min(push + s * 0.01, targetPush)
            } else if push > targetPush {
                push = max(push - s * 0.01, targetPush)
            }

            let gPrev = gain
            if abs(a * gain) > threshold {
                gain -= max(gain, 1) * s * Self.attackRate
                if gain < 0 { gain = 0 }
                if releaseKnee > 1 { releaseKnee -= 5 }
                if releaseKnee < 1 { releaseKnee = 1 }
            } else {
                gain += k * s * Self.releaseRate * releaseKnee / speedFactor
                if gain > Self.maximumGain { gain = Self.maximumGain }
                if releaseKnee < Self.kneeMax { releaseKnee += 0.1 }
            }

            let processed = d * ((gPrev - 0.15) + 1) / 2 * mode.makeup
            let mix = min(max(push, 0), 1)
            output[i] = d * (1 - mix) + processed * mix
        }
    }
}

/// Многоканальная обёртка: независимое состояние на каждый канал.
public final class Normalizer {
    public var mode: CompressorMode = .music
    public var enabled: Bool = true
    private var channels: [ChannelCompressor]

    public init(channelCount: Int, sampleRate: Double) {
        channels = (0..<channelCount).map { _ in ChannelCompressor(sampleRate: sampleRate) }
    }

    public var channelCount: Int { channels.count }
    public var gain: Float { channels.first?.currentGain ?? 1 }

    /// Один канал блоком (планарно).
    public func process(channel: Int, input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, count: Int) {
        channels[channel].process(input: input, output: output, count: count,
                                  mode: mode, targetPush: enabled ? mode.push : 0)
    }
}
