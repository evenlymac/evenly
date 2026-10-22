import Foundation
import CoreAudio
import AudioToolbox
import EvenlyDSP

/// Захват всего системного звука через Core Audio tap (оригинал глушится),
/// обработка нормализатором и вывод на текущее устройство по умолчанию.
final class AudioEngine {
    enum EngineError: Error { case os(String, OSStatus), noDevice }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var normalizer: Normalizer?
    private var scratchIn: [[Float]] = []
    private var scratchOut: [[Float]] = []

    var isRunning: Bool { procID != nil }

    func start() throws {
        guard !isRunning else { return }
        let outputID = try Self.defaultOutputDevice()
        let outputUID = try Self.stringProperty(outputID, kAudioDevicePropertyDeviceUID)

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "Evenly"
        desc.isPrivate = true
        desc.muteBehavior = .muted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tap), "CreateProcessTap")
        tapID = tap

        let tapUID = desc.uuid.uuidString
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Evenly",
            kAudioAggregateDeviceUIDKey: "app.evenly.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        do {
            try check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg), "CreateAggregateDevice")
        } catch { stop(); throw error }
        aggregateID = agg

        let fmt = try Self.tapFormat(tap)
        let channels = max(Int(fmt.mChannelsPerFrame), 1)
        let norm = Normalizer(channelCount: channels, sampleRate: fmt.mSampleRate)
        normalizer = norm

        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { [weak self] _, inData, _, outData, _ in
            self?.render(inData, outData)
        }
        if status != noErr { stop(); throw EngineError.os("CreateIOProc", status) }
        procID = proc
        let startStatus = AudioDeviceStart(agg, proc)
        if startStatus != noErr { stop(); throw EngineError.os("DeviceStart", startStatus) }
    }

    func stop() {
        if let p = procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, p)
            AudioDeviceDestroyIOProcID(aggregateID, p)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        normalizer = nil
    }

    // MARK: - Реальное время

    private func render(_ inData: UnsafePointer<AudioBufferList>, _ outData: UnsafeMutablePointer<AudioBufferList>) {
        guard let norm = normalizer else { return }
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        let outList = UnsafeMutableAudioBufferListPointer(outData)
        guard let inBuf = inList.first, let outBuf = outList.first,
              let ip = inBuf.mData?.assumingMemoryBound(to: Float.self),
              let op = outBuf.mData?.assumingMemoryBound(to: Float.self) else { return }

        let inCh = Int(inBuf.mNumberChannels)
        let outCh = Int(outBuf.mNumberChannels)
        let frames = Int(inBuf.mDataByteSize) / (MemoryLayout<Float>.size * max(inCh, 1))
        let outFrames = Int(outBuf.mDataByteSize) / (MemoryLayout<Float>.size * max(outCh, 1))
        let n = min(frames, outFrames)
        if scratchIn.count != norm.channelCount || (scratchIn.first?.count ?? 0) < n {
            scratchIn = [[Float]](repeating: [Float](repeating: 0, count: max(n, 4096)), count: norm.channelCount)
            scratchOut = scratchIn
        }
        for c in 0..<norm.channelCount {
            let src = min(c, inCh - 1)
            scratchIn[c].withUnsafeMutableBufferPointer { b in
                for i in 0..<n { b[i] = ip[i * inCh + src] }
            }
            scratchIn[c].withUnsafeBufferPointer { ib in
                scratchOut[c].withUnsafeMutableBufferPointer { ob in
                    norm.process(channel: c, input: ib.baseAddress!, output: ob.baseAddress!, count: n)
                }
            }
        }
        for i in 0..<n {
            for c in 0..<outCh { op[i * outCh + c] = scratchOut[min(c, norm.channelCount - 1)][i] }
        }
    }

    // MARK: - Помощники

    private func check(_ s: OSStatus, _ what: String) throws {
        if s != noErr { throw EngineError.os(what, s) }
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let s = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        if s != noErr || id == kAudioObjectUnknown { throw EngineError.noDevice }
        return id
    }

    static func stringProperty(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let s = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
        if s != noErr || value == nil { throw EngineError.os("GetProperty", s) }
        return value!.takeRetainedValue() as String
    }

    static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let s = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &fmt)
        if s != noErr { throw EngineError.os("TapFormat", s) }
        return fmt
    }
}
