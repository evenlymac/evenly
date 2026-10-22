import Foundation
import CoreAudio
import AudioToolbox
import EvenlyDSP
import os

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

    // Диагностика: пики за период (пишутся из потока аудио, читаются таймером; гонка безвредна).
    private var peakIn: Float = 0
    private var peakOut: Float = 0
    private var diagTimer: DispatchSourceTimer?
    private let log = Logger(subsystem: "app.evenly", category: "levels")

    private func startDiagnostics() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let gain = self.normalizer?.gain ?? 0
            self.log.notice("in=\(self.peakIn, format: .fixed(precision: 4)) out=\(self.peakOut, format: .fixed(precision: 4)) gain=\(gain, format: .fixed(precision: 2))")
            self.peakIn = 0; self.peakOut = 0
        }
        t.resume()
        diagTimer = t
    }

    func start() throws {
        guard !isRunning else { return }
        let outputID = try Self.defaultOutputDevice()
        let outputUID = try Self.stringProperty(outputID, kAudioDevicePropertyDeviceUID)

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
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
        startDiagnostics()
        let startStatus = AudioDeviceStart(agg, proc)
        if startStatus != noErr { stop(); throw EngineError.os("DeviceStart", startStatus) }
    }

    func stop() {
        diagTimer?.cancel(); diagTimer = nil
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
        // Гипотеза эталона: одно состояние на все каналы, цикл по interleaved-сэмплам.
        if scratchIn.count != 1 || scratchIn[0].count < n * norm.channelCount {
            scratchIn = [[Float](repeating: 0, count: max(n * norm.channelCount, 8192))]
            scratchOut = scratchIn
        }
        let nc = norm.channelCount
        for i in 0..<n { for c in 0..<nc { scratchIn[0][i * nc + c] = ip[i * inCh + min(c, inCh - 1)] } }
        scratchIn[0].withUnsafeBufferPointer { ib in
            scratchOut[0].withUnsafeMutableBufferPointer { ob in
                norm.process(channel: 0, input: ib.baseAddress!, output: ob.baseAddress!, count: n * nc)
            }
        }
        var pi: Float = 0, po: Float = 0
        for i in 0..<n { pi = max(pi, abs(ip[i * inCh])) }
        for i in 0..<n { po = max(po, abs(scratchOut[0][i * nc])) }
        peakIn = max(peakIn, pi); peakOut = max(peakOut, po)
        for i in 0..<n {
            for c in 0..<outCh { op[i * outCh + c] = min(max(scratchOut[0][i * nc + min(c, nc - 1)], -1), 1) }
        }
    }

    // MARK: - Помощники

    private func check(_ s: OSStatus, _ what: String) throws {
        if s != noErr { throw EngineError.os(what, s) }
    }

    /// Свой процесс исключаем из захвата, иначе выход Evenly попадает обратно на вход (петля).
    static func ownProcessObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let s = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                           UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return s == noErr && obj != kAudioObjectUnknown ? [obj] : []
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
