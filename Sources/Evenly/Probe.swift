import Foundation
import CoreAudio
import AudioToolbox

/// Режим измерения: `Evenly --probe out.wav секунды`. Пишет в WAV (float32, стерео),
/// что реально уходит на устройство вывода (tap устройства, без глушения). Движок не запускается.
final class Probe {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var samples: [Float] = []
    private var channels = 2
    private var rate = 44100.0

    static var requested: (path: String, seconds: Double)? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--probe"), a.count > i + 2, let s = Double(a[i + 2]) else { return nil }
        return (a[i + 1], s)
    }

    func run(path: String, seconds: Double) {
        do {
            let outID = try AudioEngine.defaultOutputDevice()
            let uid = try AudioEngine.stringProperty(outID, kAudioDevicePropertyDeviceUID)
            let desc = CATapDescription(excludingProcesses: [], deviceUID: uid, stream: 0)
            desc.name = "EvenlyProbe"
            desc.isPrivate = true
            desc.muteBehavior = .unmuted
            var tap = AudioObjectID(kAudioObjectUnknown)
            guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { fail("tap") }
            tapID = tap
            let dict: [String: Any] = [
                kAudioAggregateDeviceNameKey: "EvenlyProbe",
                kAudioAggregateDeviceUIDKey: "app.evenly.probe.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: uid,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                                   kAudioSubTapUIDKey: desc.uuid.uuidString]],
            ]
            var agg = AudioObjectID(kAudioObjectUnknown)
            guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg) == noErr else { fail("aggregate") }
            aggregateID = agg
            let fmt = try AudioEngine.tapFormat(tap)
            channels = max(Int(fmt.mChannelsPerFrame), 1)
            rate = fmt.mSampleRate
            samples.reserveCapacity(Int(rate * seconds) * channels + 1_000_000)
            var proc: AudioDeviceIOProcID?
            let st = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { [weak self] _, inData, _, outData, _ in
                let out = UnsafeMutableAudioBufferListPointer(outData)
                for b in out { if let m = b.mData { memset(m, 0, Int(b.mDataByteSize)) } }
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
                guard let b = list.first, let p = b.mData?.assumingMemoryBound(to: Float.self) else { return }
                self?.samples.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(b.mDataByteSize) / 4))
            }
            guard st == noErr else { fail("ioproc") }
            procID = proc
            guard AudioDeviceStart(agg, proc) == noErr else { fail("start") }
        } catch { fail("\(error)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID!)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            writeWAV(path)
            exit(0)
        }
    }

    private func fail(_ what: String) -> Never {
        FileHandle.standardError.write(Data("probe failed: \(what)\n".utf8))
        exit(2)
    }

    private func writeWAV(_ path: String) {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(samples.count * 4)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(3); u16(UInt16(channels)); u32(UInt32(rate)); u32(UInt32(rate) * UInt32(channels) * 4)
        u16(UInt16(channels * 4)); u16(32); d.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBufferPointer { d.append(UnsafeBufferPointer(start: $0.baseAddress, count: samples.count)) }
        try? d.write(to: URL(fileURLWithPath: path))
    }
}
