import Foundation
import CoreAudio
import AppKit
import Darwin

@_silgen_name("shm_open")
private func c_shm_open(_ name: UnsafePointer<CChar>, _ oflag: Int32) -> Int32

/// Manages the Virtual HAL Loopback Driver used to expose native macOS volume/mute controls
/// and capture system audio for passthrough to HDMI, DisplayPort, USB, and Bluetooth outputs.
final class VirtualDriverBridge {
    static let shared = VirtualDriverBridge()

    static let deviceUID = "VolumeGuard_VirtualDevice"
    static let nameSelector = CoreAudioDevice.fourCC("vgnm")
    static let shownSelector = CoreAudioDevice.fourCC("vgsh")
    static let latencySelector = CoreAudioDevice.fourCC("vglt")

    static let excludedVirtualUIDs: Set<String> = [
        "VolumeGuard_VirtualDevice"
    ]

    static let supportedSampleRates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000
    ]

    var device: CoreAudioDevice? {
        CoreAudioDevice.lookupByUID(Self.deviceUID)
    }

    var isAvailable: Bool {
        device != nil
    }

    var isSharedMemoryAvailable: Bool {
        let fd = "/vg_audio_shm_v1".withCString { namePtr in
            c_shm_open(namePtr, O_RDONLY)
        }
        if fd >= 0 {
            close(fd)
            return true
        }
        return false
    }

    var needsDriverUpdate: Bool {
        guard let dev = device else { return false }
        let version = CoreAudioDevice.readCFString(objectID: dev.id, selector: CoreAudioDevice.fourCC("vgvr"))
        if version != "1.2.0" {
            return true
        }
        return !isSharedMemoryAvailable
    }

    func setShown(_ shown: Bool) {
        guard let dev = device else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: Self.shownSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(dev.id, &addr) else { return }
        var val: CFBoolean = shown ? kCFBooleanTrue : kCFBooleanFalse
        let size = UInt32(MemoryLayout<CFBoolean>.size)
        withUnsafeMutablePointer(to: &val) { ptr in
            _ = AudioObjectSetPropertyData(dev.id, &addr, 0, nil, size, ptr)
        }
    }

    func setName(_ newName: String) {
        guard let dev = device else { return }
        var cfStr: CFString = newName as CFString
        let size = UInt32(MemoryLayout<CFString>.size)

        var customAddr = AudioObjectPropertyAddress(
            mSelector: Self.nameSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(dev.id, &customAddr) {
            withUnsafeMutablePointer(to: &cfStr) { ptr in
                _ = AudioObjectSetPropertyData(dev.id, &customAddr, 0, nil, size, ptr)
            }
        }

        var stdAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(dev.id, &stdAddr),
           AudioObjectIsPropertySettable(dev.id, &stdAddr, &settable) == noErr,
           settable.boolValue {
            withUnsafeMutablePointer(to: &cfStr) { ptr in
                _ = AudioObjectSetPropertyData(dev.id, &stdAddr, 0, nil, size, ptr)
            }
        }
    }

    func setLatency(_ latency: UInt32) {
        guard let dev = device else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: Self.latencySelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(dev.id, &addr) else { return }
        var numValue = Int32(latency)
        guard let cfNum = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &numValue) else { return }
        var ref: CFNumber = cfNum
        let size = UInt32(MemoryLayout<CFNumber>.size)
        withUnsafeMutablePointer(to: &ref) { ptr in
            _ = AudioObjectSetPropertyData(dev.id, &addr, 0, nil, size, ptr)
        }
    }

    func syncSampleRate(to targetDevice: CoreAudioDevice) {
        guard let dev = device else { return }
        let targetRate = targetDevice.nominalSampleRate ?? 48_000
        let closest = Self.supportedSampleRates.min(by: { abs($0 - targetRate) < abs($1 - targetRate) }) ?? 48_000
        if dev.nominalSampleRate != closest {
            dev.setNominalSampleRate(closest)
        }
    }

    /// Installs VolumeGuard.driver into /Library/Audio/Plug-Ins/HAL and restarts coreaudiod
    /// using native macOS administrator authorization via osascript.
    func installDriverWithAdminPrompt(completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let bundleDriverPath = Bundle.main.resourceURL?.appendingPathComponent("VolumeGuard.driver").path
            let cwdDriverPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/VolumeGuard.driver").path
            let sourcePath: String
            if let bp = bundleDriverPath, FileManager.default.fileExists(atPath: bp) {
                sourcePath = bp
            } else if FileManager.default.fileExists(atPath: cwdDriverPath) {
                sourcePath = cwdDriverPath
            } else {
                DispatchQueue.main.async {
                    completion(false, "VolumeGuard.driver bundle not found.")
                }
                return
            }

            let scriptPath = "/tmp/vg_install_driver.sh"
            let scriptContent = """
            #!/bin/sh
            mkdir -p /Library/Audio/Plug-Ins/HAL
            rm -rf /Library/Audio/Plug-Ins/HAL/VolumeGuard.driver
            cp -R "\(sourcePath)" /Library/Audio/Plug-Ins/HAL/VolumeGuard.driver
            chown -R root:wheel /Library/Audio/Plug-Ins/HAL/VolumeGuard.driver
            chmod -R 755 /Library/Audio/Plug-Ins/HAL/VolumeGuard.driver
            killall -9 "Core Audio Driver" 2>/dev/null || true
            killall -9 coreaudiod 2>/dev/null || launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || true
            sleep 0.5
            killall ControlCenter 2>/dev/null || true
            exit 0
            """

            do {
                try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            } catch {
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
                return
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = [
                "-e",
                "do shell script \"/bin/sh \(scriptPath)\" with administrator privileges"
            ]
            let errPipe = Pipe()
            proc.standardError = errPipe

            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
                return
            }

            if proc.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Authorization cancelled"
                DispatchQueue.main.async {
                    completion(false, msg)
                }
                return
            }

            // Wait up to 4 seconds for coreaudiod to respawn and register VolumeGuard_VirtualDevice with shared memory
            for _ in 0..<8 {
                Thread.sleep(forTimeInterval: 0.5)
                if self.isAvailable && self.isSharedMemoryAvailable {
                    break
                }
            }
            DispatchQueue.main.async {
                completion(self.isAvailable && self.isSharedMemoryAvailable, nil)
            }
        }
    }
}
