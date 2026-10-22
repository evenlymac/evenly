import XCTest
@testable import EvenlyDSP

final class CompressorTests: XCTestCase {
    let sr = 44100.0

    func sine(amp: Float, frames: Int, freq: Float = 440) -> [Float] {
        (0..<frames).map { amp * sin(2 * .pi * freq * Float($0) / Float(sr)) }
    }

    func run(_ x: [Float], on c: inout ChannelCompressor, push: Float = 1) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        let step = 512
        var i = 0
        while i < x.count {
            let n = min(step, x.count - i)
            x.withUnsafeBufferPointer { ip in
                out.withUnsafeMutableBufferPointer { op in
                    c.process(input: ip.baseAddress! + i, output: op.baseAddress! + i, count: n,
                              mode: .music, targetPush: push)
                }
            }
            i += n
        }
        return out
    }

    func peak(_ x: ArraySlice<Float>) -> Float { x.map { abs($0) }.max() ?? 0 }

    func testQuietSignalIsBoosted() {
        var c = ChannelCompressor(sampleRate: sr)
        let x = sine(amp: 0.01, frames: 44100 * 20)
        let y = run(x, on: &c)
        let tail = y.suffix(4410)
        XCTAssertGreaterThan(peak(tail), 0.01 * 3, "тихий сигнал должен подниматься")
        XCTAssertLessThanOrEqual(peak(y[...]), 1.0)
    }

    func testLoudSignalLimitedNearThreshold() {
        var c = ChannelCompressor(sampleRate: sr)
        let x = sine(amp: 1.0, frames: 44100 * 2)
        let y = run(x, on: &c)
        XCTAssertLessThanOrEqual(peak(y.suffix(8820)), 1.0)
        XCTAssertLessThan(c.currentGain, 1.0, "громкий сигнал опускает gain")
    }

    func testStepDownIsReleasedSlowly() {
        var c = ChannelCompressor(sampleRate: sr)
        let loud = sine(amp: 1.0, frames: 44100)
        let quiet = sine(amp: 0.05, frames: 44100 * 3)
        let y = run(loud + quiet, on: &c)
        let right = y[(44100 + 4410)..<(44100 + 8820)]
        let later = y.suffix(4410)
        XCTAssertLessThan(peak(right), peak(later), "gain растёт постепенно после громкого")
    }

    func testPushZeroIsDryDelayed() {
        var c = ChannelCompressor(sampleRate: sr)
        let x = sine(amp: 0.3, frames: 4096)
        let y = run(x, on: &c, push: 0)
        for i in 600..<4096 {
            XCTAssertEqual(y[i], x[i - ChannelCompressor.lookahead], accuracy: 1e-5)
        }
    }

    func testSilenceStaysSilent() {
        var c = ChannelCompressor(sampleRate: sr)
        let y = run([Float](repeating: 0, count: 44100), on: &c)
        XCTAssertEqual(peak(y[...]), 0)
    }

    func testSampleRateScalesRates() {
        var c48 = ChannelCompressor(sampleRate: 48000)
        var c44 = ChannelCompressor(sampleRate: 44100)
        let x = sine(amp: 0.01, frames: 44100 * 5)
        _ = run(x, on: &c44)
        let x48 = (0..<(48000 * 5)).map { 0.01 * sin(2 * Float.pi * 440 * Float($0) / 48000) }
        var out = [Float](repeating: 0, count: x48.count)
        x48.withUnsafeBufferPointer { ip in out.withUnsafeMutableBufferPointer { op in
            c48.process(input: ip.baseAddress!, output: op.baseAddress!, count: x48.count, mode: .music, targetPush: 1)
        } }
        XCTAssertEqual(c48.currentGain, c44.currentGain, accuracy: c44.currentGain * 0.1)
    }
}

final class UniversalModeTests: XCTestCase {
    func testUniversalIsBetweenMusicAndMovieSpeed() {
        XCTAssertGreaterThan(CompressorMode.universal.speed, CompressorMode.music.speed)
        XCTAssertLessThan(CompressorMode.universal.speed, CompressorMode.movie.speed)
        XCTAssertEqual(CompressorMode.universal.push, 1)
        XCTAssertEqual(Normalizer(channelCount: 2, sampleRate: 44100).mode, .universal)
    }
}
