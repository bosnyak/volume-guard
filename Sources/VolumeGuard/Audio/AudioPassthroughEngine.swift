import Foundation
import CoreAudio
import AudioToolbox
import Darwin

@_silgen_name("shm_open")
private func c_shm_open(_ name: UnsafePointer<CChar>, _ oflag: Int32) -> Int32

/// Low-latency CoreAudio HAL passthrough engine that reads system audio from the virtual driver's
/// lock-free POSIX shared memory ring buffer (`/vg_audio_shm_v1`) and renders it to the active
/// physical output device (HDMI, DisplayPort, USB, Bluetooth, etc.) while applying digital volume
/// & mute control in real time — without opening any CoreAudio Input unit (zero Microphone indicator).
final class AudioPassthroughEngine {
    private static let shmName = "/vg_audio_shm_v1"
    private static let shmMagic: UInt32 = 0x56475348
    private static let shmRingFrames: UInt64 = 65536
    private static let shmRingMask: UInt64 = 65535
    private static let shmChannels: Int = 2
    private static let shmHeaderBytes: Int = 32
    private static let shmTotalBytes: Int = 32 + (65536 * 2 * MemoryLayout<Float32>.size)

    private static let hostTicksPerNanosecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.numer > 0 else { return 1.0 }
        return Double(info.denom) / Double(info.numer)
    }()

    private static let staleWriterThresholdTicks: UInt64 = UInt64(120_000_000.0 * hostTicksPerNanosecond) // 120 ms
    private static let renderWatchdogThresholdTicks: UInt64 = UInt64(1_500_000_000.0 * hostTicksPerNanosecond) // 1.5 s

    private var outputUnit: AudioUnit?
    private var maxFramesPerSlice: UInt32 = 4096

    private var shmRawPtr: UnsafeMutableRawPointer?
    private var shmReadFrameCounter: UInt64 = 0
    private var isBufferingForStart: Bool = true
    private var shmRetryCounter: UInt32 = 0
    private var lastRenderHostTime: UInt64 = 0
    private var startedAtHostTime: UInt64 = 0

    var gain: Float = 1.0
    var isMuted: Bool = false

    private(set) var isRunning: Bool = false
    private(set) var currentOutputDeviceID: AudioObjectID?

    /// Returns true only if the output AudioUnit is initialized, started, and actively invoking
    /// the real-time render callback (detects dead AudioUnits after macOS sleep/wake or HDMI reset).
    var isHealthyAndRendering: Bool {
        guard isRunning, let outUnit = outputUnit else { return false }
        var unitRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(
            outUnit,
            kAudioOutputUnitProperty_IsRunning,
            kAudioUnitScope_Global,
            0,
            &unitRunning,
            &size
        )
        if status == noErr && unitRunning == 0 {
            return false
        }
        let now = mach_absolute_time()
        let lastRender = lastRenderHostTime
        if lastRender == 0 {
            // Allow up to 1.5s grace period right after start()
            return (now >= startedAtHostTime) && ((now - startedAtHostTime) < Self.renderWatchdogThresholdTicks)
        }
        return (now >= lastRender) && ((now - lastRender) < Self.renderWatchdogThresholdTicks)
    }

    init() {}

    deinit {
        stop()
        unmapSharedMemory()
    }

    @discardableResult
    func start(virtualDevice: CoreAudioDevice, outputDevice: CoreAudioDevice) -> Bool {
        stop()

        // Match sample rates between virtual driver and physical device
        VirtualDriverBridge.shared.syncSampleRate(to: outputDevice)
        VirtualDriverBridge.shared.setLatency(outputDevice.outputLatency)

        _ = tryMapSharedMemory()
        resetReadState()

        let sampleRate = outputDevice.nominalSampleRate ?? virtualDevice.nominalSampleRate ?? 48_000

        guard setupOutputUnit(device: outputDevice, sampleRate: sampleRate),
              let outUnit = outputUnit else {
            stop()
            return false
        }

        let now = mach_absolute_time()
        startedAtHostTime = now
        lastRenderHostTime = now

        let outStatus = AudioOutputUnitStart(outUnit)
        if outStatus != noErr {
            stop()
            return false
        }

        currentOutputDeviceID = outputDevice.id
        isRunning = true
        return true
    }

    func stop() {
        if let outUnit = outputUnit {
            AudioOutputUnitStop(outUnit)
            AudioUnitUninitialize(outUnit)
            AudioComponentInstanceDispose(outUnit)
            outputUnit = nil
        }
        isRunning = false
        currentOutputDeviceID = nil
        lastRenderHostTime = 0
        startedAtHostTime = 0
        resetReadState()
    }

    // MARK: - POSIX Shared Memory Mapping

    @discardableResult
    private func tryMapSharedMemory() -> Bool {
        if let existing = shmRawPtr {
            let magic = existing.load(fromByteOffset: 0, as: UInt32.self)
            if magic == Self.shmMagic {
                return true
            }
            unmapSharedMemory()
        }

        let fd = Self.shmName.withCString { namePtr in
            c_shm_open(namePtr, O_RDONLY)
        }
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0, Int(st.st_size) >= Self.shmTotalBytes else {
            return false
        }

        guard let ptr = mmap(nil, Self.shmTotalBytes, PROT_READ, MAP_SHARED, fd, 0),
              ptr != MAP_FAILED else {
            return false
        }

        let magic = ptr.load(fromByteOffset: 0, as: UInt32.self)
        guard magic == Self.shmMagic else {
            munmap(ptr, Self.shmTotalBytes)
            return false
        }

        shmRawPtr = ptr
        let currentWrite = ptr.load(fromByteOffset: 16, as: UInt64.self)
        shmReadFrameCounter = currentWrite
        isBufferingForStart = true
        return true
    }

    private func unmapSharedMemory() {
        if let ptr = shmRawPtr {
            munmap(ptr, Self.shmTotalBytes)
            shmRawPtr = nil
        }
    }

    private func resetReadState() {
        if let ptr = shmRawPtr {
            shmReadFrameCounter = ptr.load(fromByteOffset: 16, as: UInt64.self)
        } else {
            shmReadFrameCounter = 0
        }
        isBufferingForStart = true
    }

    // MARK: - Output AudioUnit Setup

    private func setupOutputUnit(device: CoreAudioDevice, sampleRate: Double) -> Bool {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else { return false }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(comp, &unit) == noErr, let outUnit = unit else { return false }
        self.outputUnit = outUnit

        // Bind to physical output device (Output scope only — never Input)
        var devID = device.id
        guard AudioUnitSetProperty(
            outUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        ) == noErr else { return false }

        // Set non-interleaved float32 stereo stream format on Input scope of bus 0
        var streamFormat = Self.makeStereoFloatFormat(sampleRate: sampleRate)
        guard AudioUnitSetProperty(
            outUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ) == noErr else { return false }

        var maxFrames = maxFramesPerSlice
        AudioUnitSetProperty(
            outUnit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maxFrames,
            UInt32(MemoryLayout<UInt32>.size)
        )

        var callbackStruct = AURenderCallbackStruct(
            inputProc: outputRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        guard AudioUnitSetProperty(
            outUnit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ) == noErr else { return false }

        return AudioUnitInitialize(outUnit) == noErr
    }

    private static func makeStereoFloatFormat(sampleRate: Double) -> AudioStreamBasicDescription {
        let bytesPerSample = UInt32(MemoryLayout<Float32>.size)
        return AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: bytesPerSample,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerSample,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 8 * bytesPerSample,
            mReserved: 0
        )
    }

    // MARK: - Real-Time Render Callback

    fileprivate func handleOutputCallback(
        inNumberFrames: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        let now = mach_absolute_time()
        lastRenderHostTime = now

        guard let ioData = ioData else { return noErr }
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        let frames = Int(inNumberFrames)

        if shmRawPtr == nil {
            shmRetryCounter &+= 1
            if (shmRetryCounter & 63) == 1 {
                _ = tryMapSharedMemory()
            }
        }

        guard let rawPtr = shmRawPtr else {
            Self.fillSilence(abl: abl, frames: frames)
            return noErr
        }

        let driverRunning = rawPtr.load(fromByteOffset: 12, as: UInt32.self)
        let writePos = rawPtr.load(fromByteOffset: 16, as: UInt64.self)
        let lastWriteTime = rawPtr.load(fromByteOffset: 24, as: UInt64.self)

        let writerIsFresh = (lastWriteTime > 0) && (now >= lastWriteTime) && ((now - lastWriteTime) <= Self.staleWriterThresholdTicks)

        // If driver IO is idle or writer stopped writing >120ms ago, reset read pointer and output silence
        if driverRunning == 0 || writePos == 0 || !writerIsFresh {
            shmReadFrameCounter = writePos
            isBufferingForStart = true
            Self.fillSilence(abl: abl, frames: frames)
            return noErr
        }

        // If writer restarted or wrapped around behind our read pointer, resync
        if writePos < shmReadFrameCounter {
            shmReadFrameCounter = writePos
            isBufferingForStart = true
        }

        var available = writePos - shmReadFrameCounter
        let targetCushion = UInt64(max(inNumberFrames * 3, 1536))
        let minDriftThreshold = UInt64(max(inNumberFrames + 256, 768))
        let maxDriftThreshold = UInt64(max(inNumberFrames * 5, 2560))
        let maxLagFrames = UInt64(max(inNumberFrames * 10, 5120))

        // If we fell too far behind, snap read pointer to targetCushion behind writePos
        if available > maxLagFrames {
            shmReadFrameCounter = writePos - targetCushion
            available = targetCushion
            isBufferingForStart = false
        }

        // Wait for initial cushion before starting playback to prevent phase jitter clicks
        if isBufferingForStart {
            if available < targetCushion {
                Self.fillSilence(abl: abl, frames: frames)
                return noErr
            }
            shmReadFrameCounter = writePos - targetCushion
            available = targetCushion
            isBufferingForStart = false
        }

        // If an underrun occurred while writer is still active, re-buffer cleanly to targetCushion
        if available < UInt64(inNumberFrames) {
            isBufferingForStart = true
            Self.fillSilence(abl: abl, frames: frames)
            return noErr
        }

        // Gentle 1-frame adaptive drift compensation to keep virtual & HDMI clocks locked
        var framesToConsume = frames
        if frames > 64 {
            if available > maxDriftThreshold && available >= UInt64(frames + 1) {
                framesToConsume = frames + 1
            } else if available < minDriftThreshold {
                framesToConsume = frames - 1
            }
        }

        let rawGain = isMuted ? Float(0.0) : gain
        if rawGain <= 0.0001 {
            shmReadFrameCounter &+= UInt64(framesToConsume)
            Self.fillSilence(abl: abl, frames: frames)
            return noErr
        }

        // Perceptual volume curve (quadratic below 100%, linear boost above 100%)
        let effectiveGain: Float = rawGain <= 1.0 ? (rawGain * rawGain) : rawGain
        let samplesPtr = rawPtr.advanced(by: Self.shmHeaderBytes).assumingMemoryBound(to: Float32.self)
        let readBase = shmReadFrameCounter

        if framesToConsume == frames {
            // Fast path: 1:1 frame copy with volume gain & soft limiter
            if abl.count >= 2,
               let leftOut = abl[0].mData?.assumingMemoryBound(to: Float32.self),
               let rightOut = abl[1].mData?.assumingMemoryBound(to: Float32.self) {
                for f in 0..<frames {
                    let ringIdx = Int((readBase &+ UInt64(f)) & Self.shmRingMask) * 2
                    var l = samplesPtr[ringIdx] * effectiveGain
                    var r = samplesPtr[ringIdx + 1] * effectiveGain
                    if l > 1.0 { l = 1.0 } else if l < -1.0 { l = -1.0 }
                    if r > 1.0 { r = 1.0 } else if r < -1.0 { r = -1.0 }
                    leftOut[f] = l
                    rightOut[f] = r
                }
            } else if abl.count == 1,
                      let out = abl[0].mData?.assumingMemoryBound(to: Float32.self) {
                let chCount = Int(abl[0].mNumberChannels)
                for f in 0..<frames {
                    let ringIdx = Int((readBase &+ UInt64(f)) & Self.shmRingMask) * 2
                    var l = samplesPtr[ringIdx] * effectiveGain
                    var r = samplesPtr[ringIdx + 1] * effectiveGain
                    if l > 1.0 { l = 1.0 } else if l < -1.0 { l = -1.0 }
                    if r > 1.0 { r = 1.0 } else if r < -1.0 { r = -1.0 }
                    if chCount >= 2 {
                        out[f * chCount] = l
                        out[f * chCount + 1] = r
                    } else {
                        out[f] = 0.5 * (l + r)
                    }
                }
            }
        } else {
            // Drift-competing linear interpolation path (+/- 1 frame over slice)
            let scale = Float(framesToConsume - 1) / Float(max(frames - 1, 1))
            if abl.count >= 2,
               let leftOut = abl[0].mData?.assumingMemoryBound(to: Float32.self),
               let rightOut = abl[1].mData?.assumingMemoryBound(to: Float32.self) {
                for f in 0..<frames {
                    let srcPos = Float(f) * scale
                    let idx0 = UInt64(srcPos)
                    let frac = srcPos - Float(idx0)
                    let r0 = Int((readBase &+ idx0) & Self.shmRingMask) * 2
                    let r1 = Int((readBase &+ idx0 &+ 1) & Self.shmRingMask) * 2
                    var l = (samplesPtr[r0] + frac * (samplesPtr[r1] - samplesPtr[r0])) * effectiveGain
                    var r = (samplesPtr[r0 + 1] + frac * (samplesPtr[r1 + 1] - samplesPtr[r0 + 1])) * effectiveGain
                    if l > 1.0 { l = 1.0 } else if l < -1.0 { l = -1.0 }
                    if r > 1.0 { r = 1.0 } else if r < -1.0 { r = -1.0 }
                    leftOut[f] = l
                    rightOut[f] = r
                }
            } else if abl.count == 1,
                      let out = abl[0].mData?.assumingMemoryBound(to: Float32.self) {
                let chCount = Int(abl[0].mNumberChannels)
                for f in 0..<frames {
                    let srcPos = Float(f) * scale
                    let idx0 = UInt64(srcPos)
                    let frac = srcPos - Float(idx0)
                    let r0 = Int((readBase &+ idx0) & Self.shmRingMask) * 2
                    let r1 = Int((readBase &+ idx0 &+ 1) & Self.shmRingMask) * 2
                    var l = (samplesPtr[r0] + frac * (samplesPtr[r1] - samplesPtr[r0])) * effectiveGain
                    var r = (samplesPtr[r0 + 1] + frac * (samplesPtr[r1 + 1] - samplesPtr[r0 + 1])) * effectiveGain
                    if l > 1.0 { l = 1.0 } else if l < -1.0 { l = -1.0 }
                    if r > 1.0 { r = 1.0 } else if r < -1.0 { r = -1.0 }
                    if chCount >= 2 {
                        out[f * chCount] = l
                        out[f * chCount + 1] = r
                    } else {
                        out[f] = 0.5 * (l + r)
                    }
                }
            }
        }

        shmReadFrameCounter &+= UInt64(framesToConsume)
        return noErr
    }

    private static func fillSilence(abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let byteSize = frames * MemoryLayout<Float32>.size
        for i in 0..<abl.count {
            if let data = abl[i].mData {
                memset(data, 0, min(Int(abl[i].mDataByteSize), byteSize * Int(max(abl[i].mNumberChannels, 1))))
            }
        }
    }
}

private func outputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let engine = Unmanaged<AudioPassthroughEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    return engine.handleOutputCallback(inNumberFrames: inNumberFrames, ioData: ioData)
}
