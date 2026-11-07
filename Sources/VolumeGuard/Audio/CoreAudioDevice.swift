import Foundation
import CoreAudio
import AudioToolbox

enum AudioTransportType: String, Codable {
    case hdmi = "HDMI"
    case displayPort = "DisplayPort"
    case usb = "USB"
    case bluetooth = "Bluetooth"
    case bluetoothLE = "Bluetooth LE"
    case thunderbolt = "Thunderbolt"
    case airPlay = "AirPlay"
    case builtIn = "Built-In"
    case virtual = "Virtual"
    case aggregate = "Aggregate"
    case pci = "PCI"
    case fireWire = "FireWire"
    case unknown = "Unknown"

    init(rawCoreAudioType: UInt32) {
        switch rawCoreAudioType {
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAutoAggregate, kAudioDeviceTransportTypeAggregate: self = .aggregate
        case kAudioDeviceTransportTypePCI: self = .pci
        case kAudioDeviceTransportTypeFireWire: self = .fireWire
        default: self = .unknown
        }
    }

    var isExternalDisplay: Bool {
        self == .hdmi || self == .displayPort
    }

    var isExternalAutoSelectable: Bool {
        switch self {
        case .hdmi, .displayPort, .bluetooth, .bluetoothLE, .usb, .thunderbolt:
            return true
        default:
            return false
        }
    }

    var sfSymbolName: String {
        switch self {
        case .hdmi, .displayPort, .thunderbolt:
            return "display"
        case .bluetooth, .bluetoothLE:
            return "headphones"
        case .usb:
            return "cable.connector"
        case .airPlay:
            return "airplayaudio"
        case .builtIn:
            return "laptopcomputer"
        default:
            return "hifispeaker"
        }
    }
}

struct CoreAudioDevice: Identifiable, Equatable, Hashable {
    let id: AudioObjectID

    var name: String {
        Self.readCFString(objectID: id, selector: kAudioObjectPropertyName) ?? "Unknown Audio Device"
    }

    var uid: String? {
        Self.readCFString(objectID: id, selector: kAudioDevicePropertyDeviceUID)
    }

    var transportType: AudioTransportType {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var raw: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &raw)
        guard status == noErr else { return .unknown }
        return AudioTransportType(rawCoreAudioType: raw)
    }

    var outputChannelCount: Int {
        channelCount(scope: kAudioObjectPropertyScopeOutput)
    }

    var inputChannelCount: Int {
        channelCount(scope: kAudioObjectPropertyScopeInput)
    }

    var isOutputDevice: Bool {
        outputChannelCount > 0
    }

    var isInputDevice: Bool {
        inputChannelCount > 0
    }

    var isAlive: Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var val: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &val) == noErr else { return false }
        return val != 0
    }

    var nominalSampleRate: Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    func setNominalSampleRate(_ rate: Double) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var val = Float64(rate)
        let size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectSetPropertyData(id, &addr, 0, nil, size, &val)
    }

    var outputLatency: UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyLatency,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var lat: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &lat) == noErr else { return 0 }
        return lat
    }

    var isJackConnected: Bool? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyJackIsConnected,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var val: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &val) == noErr else { return nil }
        return val != 0
    }

    /// True when this device is the internal MacBook speaker (not wired headphones plugged into the 3.5mm jack).
    var isBuiltInSpeaker: Bool {
        guard transportType == .builtIn else { return false }
        if let jack = isJackConnected, jack {
            return false
        }
        let lower = name.lowercased()
        if lower.contains("headphone") || lower.contains("fone") {
            return false
        }
        return true
    }

    var isReadyForPlayback: Bool {
        isAlive && isOutputDevice && (nominalSampleRate ?? 0) > 0
    }

    // MARK: - Hardware Volume & Mute Controls

    var supportsHardwareOutputVolume: Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    var virtualMasterVolume: Float? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(id, &addr) {
            var vol: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &vol) == noErr {
                return vol
            }
        }
        // Fallback to master scalar volume control (element 0)
        var scalarAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(id, &scalarAddr) {
            var vol: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &scalarAddr, 0, nil, &size, &vol) == noErr {
                return vol
            }
        }
        return nil
    }

    func setVirtualMasterVolume(_ volume: Float) {
        var clamped = min(max(volume, 0.0), 1.0)
        let size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(id, &addr) {
            AudioObjectSetPropertyData(id, &addr, 0, nil, size, &clamped)
        }
        var scalarAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(id, &scalarAddr) {
            AudioObjectSetPropertyData(id, &scalarAddr, 0, nil, size, &clamped)
        }
    }

    var isMuted: Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var val: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(id, &addr),
              AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &val) == noErr else {
            return false
        }
        return val != 0
    }

    func setMuted(_ muted: Bool) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &addr) else { return }
        var val: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectSetPropertyData(id, &addr, 0, nil, size, &val)
    }

    // MARK: - Static Discovery & System Defaults

    static func allDevices() -> [CoreAudioDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.map { CoreAudioDevice(id: $0) }
    }

    static func lookupByUID(_ uid: String) -> CoreAudioDevice? {
        if let found = allDevices().first(where: { $0.uid == uid }) {
            return found
        }
        var cfUID: CFString = uid as CFString
        var devID: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                UInt32(MemoryLayout<CFString>.size),
                uidPtr,
                &size,
                &devID
            )
        }
        if status == noErr, devID != kAudioObjectUnknown {
            let dev = CoreAudioDevice(id: devID)
            if dev.isAlive {
                return dev
            }
        }
        return nil
    }

    static var currentDefaultOutputDevice: CoreAudioDevice? {
        get {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var devID: AudioObjectID = kAudioObjectUnknown
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr,
                  devID != kAudioObjectUnknown else { return nil }
            return CoreAudioDevice(id: devID)
        }
        set {
            guard let dev = newValue else { return }
            var devID = dev.id
            let size = UInt32(MemoryLayout<AudioObjectID>.size)
            var outAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outAddr, 0, nil, size, &devID)

            var sysAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &sysAddr, 0, nil, size, &devID)
        }
    }

    // MARK: - Internal Helpers

    private func channelCount(scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let rawPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPtr.deallocate() }
        let ablPtr = rawPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ablPtr) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func readCFString(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanagedStr) { ptr in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfStr = unmanagedStr?.takeUnretainedValue() else { return nil }
        return cfStr as String
    }

    static func fourCC(_ chars: String) -> UInt32 {
        let bytes = Array(chars.utf8)
        guard bytes.count == 4 else { return 0 }
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }
}
