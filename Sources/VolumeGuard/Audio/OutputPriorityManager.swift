import Foundation
import CoreAudio
import AppKit
import Combine

struct PreferredDeviceRecord: Codable, Equatable, Identifiable {
    var id: String { uid }
    let uid: String
    var name: String
    var transportRaw: String
}

/// Coordinates device discovery, automatic HDMI/external output priority, wake/reconnect recovery,
/// per-device volume persistence, and the virtual audio passthrough engine.
final class OutputPriorityManager: ObservableObject {
    static let shared = OutputPriorityManager()

    @Published private(set) var outputDevices: [CoreAudioDevice] = []
    @Published private(set) var activeDevice: CoreAudioDevice?
    @Published private(set) var isVirtualDriverAvailable: Bool = false
    @Published private(set) var needsDriverUpdate: Bool = false
    @Published private(set) var isPassthroughActive: Bool = false
    @Published private(set) var isInstallingDriver: Bool = false
    @Published var statusMessage: String?

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.isEnabled)
            if isEnabled {
                userForcedBuiltInSpeakerSession = false
                evaluatePriorityAndRoute(reason: "app-enabled")
            } else {
                deactivatePassthroughAndRestoreNativeOutput()
            }
            onStateChanged?()
        }
    }

    @Published var volume: Float = 0.75
    @Published var isMuted: Bool = false
    @Published var autoSwitchEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoSwitchEnabled, forKey: Keys.autoSwitchEnabled)
            if autoSwitchEnabled && isEnabled {
                userForcedBuiltInSpeakerSession = false
                evaluatePriorityAndRoute(reason: "toggle-auto-switch")
            }
        }
    }
    @Published var boostEnabled: Bool {
        didSet {
            UserDefaults.standard.set(boostEnabled, forKey: Keys.boostEnabled)
            if !boostEnabled && volume > 1.0 {
                setVolume(1.0, syncToDriver: true)
            }
        }
    }
    @Published private(set) var preferredDevices: [PreferredDeviceRecord] = []

    private let engine = AudioPassthroughEngine()
    private var watchdogTimer: Timer?
    private var reevaluationWaveWorkItems: [DispatchWorkItem] = []
    private var listenerQueue = DispatchQueue(label: "dev.volumeguard.coreaudio-listener", qos: .userInteractive)
    private var registeredVirtualDeviceID: AudioObjectID?
    private var internalRoutingSuppressUntil: Date = .distantPast
    private var isUpdatingDriverVolume = false
    private var userForcedBuiltInSpeakerSession = false
    private var isSystemOrDisplaySleeping = false
    private var lastTopologyOrWakeEventTime: Date = .distantPast

    private var isInternalRoutingChange: Bool {
        Date() < internalRoutingSuppressUntil
    }

    private func beginInternalRoutingSuppression(duration: TimeInterval = 0.65) {
        let target = Date().addingTimeInterval(duration)
        if target > internalRoutingSuppressUntil {
            internalRoutingSuppressUntil = target
        }
    }

    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var virtualVolumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var virtualMuteListenerBlock: AudioObjectPropertyListenerBlock?

    var onStateChanged: (() -> Void)?

    private enum Keys {
        static let isEnabled = "vg.isEnabled"
        static let autoSwitchEnabled = "vg.autoSwitchEnabled"
        static let boostEnabled = "vg.boostEnabled"
        static let preferredDevices = "vg.preferredDevices"
        static let perDeviceVolume = "vg.perDeviceVolume"
        static let perDeviceMute = "vg.perDeviceMute"
    }

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.isEnabled) == nil {
            defaults.set(true, forKey: Keys.isEnabled)
        }
        if defaults.object(forKey: Keys.autoSwitchEnabled) == nil {
            defaults.set(true, forKey: Keys.autoSwitchEnabled)
        }
        self.isEnabled = defaults.bool(forKey: Keys.isEnabled)
        self.autoSwitchEnabled = defaults.bool(forKey: Keys.autoSwitchEnabled)
        self.boostEnabled = defaults.bool(forKey: Keys.boostEnabled)
        self.preferredDevices = Self.loadPreferredDevices()
    }

    func start() {
        refreshDeviceList()
        setupSystemListeners()
        setupWorkspaceWakeObservers()
        setupMediaKeyCallbacks()

        if isEnabled {
            evaluatePriorityAndRoute(reason: "initial-start")
        } else {
            deactivatePassthroughAndRestoreNativeOutput()
        }

        // Periodic 2.0s watchdog to catch slow HDMI EDID/HDCP wake handshakes
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
    }

    func stopAndRestoreSystemOutput() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        deactivatePassthroughAndRestoreNativeOutput()
    }

    private func deactivatePassthroughAndRestoreNativeOutput() {
        cancelReevaluationWave()
        beginInternalRoutingSuppression(duration: 0.5)

        removeVirtualDeviceListeners()
        engine.stop()
        isPassthroughActive = false

        refreshDeviceList()
        if let target = activeDevice, target.isAlive {
            CoreAudioDevice.currentDefaultOutputDevice = target
        } else if let fallback = outputDevices.first(where: { !$0.isBuiltInSpeaker && $0.isReadyForPlayback }) ?? outputDevices.first {
            CoreAudioDevice.currentDefaultOutputDevice = fallback
            activeDevice = fallback
        }
        statusMessage = nil
    }

    // MARK: - Device Discovery & Priority Logic

    func refreshDeviceList() {
        let all = CoreAudioDevice.allDevices()
        let physicalOutputs = all.filter { dev in
            guard dev.isOutputDevice, dev.isAlive else { return false }
            if let uid = dev.uid, VirtualDriverBridge.excludedVirtualUIDs.contains(uid) {
                return false
            }
            if dev.name.hasPrefix("VolumeGuard") {
                return false
            }
            return true
        }

        outputDevices = physicalOutputs
        isVirtualDriverAvailable = VirtualDriverBridge.shared.isAvailable
        needsDriverUpdate = VirtualDriverBridge.shared.needsDriverUpdate

        // Automatically register any connected HDMI or DisplayPort monitor as preferred
        // so the user's monitor is prioritized out-of-the-box.
        for dev in physicalOutputs where dev.transportType.isExternalDisplay {
            registerPreferredDevice(dev, moveToFront: false)
        }
    }

    /// Evaluates available devices and ensures that if an external HDMI/DisplayPort or preferred
    /// device is ready, we never stay stuck on MacBook Speakers.
    func evaluatePriorityAndRoute(reason: String) {
        refreshDeviceList()

        guard isEnabled else { return }

        let currentDefault = CoreAudioDevice.currentDefaultOutputDevice
        let virtualDev = VirtualDriverBridge.shared.device

        // Determine the best target physical output device
        var target: CoreAudioDevice?

        if autoSwitchEnabled && !userForcedBuiltInSpeakerSession {
            // 1. Check preferred external devices in priority order
            for pref in preferredDevices {
                if let match = outputDevices.first(where: { $0.uid == pref.uid && $0.isReadyForPlayback && !$0.isBuiltInSpeaker }) {
                    target = match
                    break
                }
            }
            // 2. Next, any ready HDMI / DisplayPort display audio
            if target == nil {
                target = outputDevices.first(where: { $0.transportType.isExternalDisplay && $0.isReadyForPlayback })
            }
            // 3. Next, any other external auto-selectable device (USB / Bluetooth / Thunderbolt)
            if target == nil {
                target = outputDevices.first(where: { $0.transportType.isExternalAutoSelectable && $0.isReadyForPlayback && !$0.isBuiltInSpeaker })
            }
        }

        // 4. If user manually selected a device and it's still alive, keep it
        if target == nil, let currentActive = activeDevice,
           let stillThere = outputDevices.first(where: { $0.id == currentActive.id && $0.isReadyForPlayback }) {
            target = stillThere
        }

        // 5. Otherwise inspect macOS current default output (if not virtual)
        if target == nil, let cur = currentDefault, cur.id != virtualDev?.id,
           let match = outputDevices.first(where: { $0.id == cur.id }) {
            target = match
        }

        // 6. Final fallback: first available physical output (e.g., Built-in Speakers when unplugged)
        if target == nil {
            target = outputDevices.first
        }

        guard let chosen = target else { return }

        let targetChanged = (activeDevice?.id != chosen.id) || (activeDevice?.uid != chosen.uid)
        let driverReady = (virtualDev != nil) && !needsDriverUpdate
        let needsPassthroughRestart = driverReady && (
            !engine.isHealthyAndRendering ||
            engine.currentOutputDeviceID != chosen.id ||
            currentDefault?.id != virtualDev?.id
        )

        if targetChanged || needsPassthroughRestart || (!driverReady && currentDefault?.id == virtualDev?.id) {
            routeToPhysicalDevice(chosen, userInitiated: false)
        }
    }

    func selectDeviceFromUI(_ device: CoreAudioDevice) {
        if !isEnabled {
            isEnabled = true
        }
        if device.isBuiltInSpeaker {
            // Allow manual selection of MacBook Speakers until next screen wake or plug event
            userForcedBuiltInSpeakerSession = true
        } else {
            userForcedBuiltInSpeakerSession = false
            registerPreferredDevice(device, moveToFront: true)
        }
        routeToPhysicalDevice(device, userInitiated: true)
    }

    private func handleExternalDefaultOutputChange() {
        guard isEnabled, !isInternalRoutingChange else { return }
        refreshDeviceList()

        let virtualDev = VirtualDriverBridge.shared.device
        guard let newDefault = CoreAudioDevice.currentDefaultOutputDevice else { return }

        // If default is already our virtual device, nothing to do
        if newDefault.id == virtualDev?.id {
            return
        }

        // Ignore automatic macOS fallback to Built-In Speakers during display/system sleep-wake
        // or within 8 seconds of a hardware topology / HDMI hotplug change.
        let inSleepOrWakeTransition = isSystemOrDisplaySleeping || (Date().timeIntervalSince(lastTopologyOrWakeEventTime) < 8.0)

        let previousWasAlive = activeDevice.map { prev in
            outputDevices.contains(where: { $0.id == prev.id && $0.isReadyForPlayback })
        } ?? false

        if previousWasAlive,
           !inSleepOrWakeTransition,
           let manualMatch = outputDevices.first(where: { $0.id == newDefault.id }) {
            if manualMatch.isBuiltInSpeaker {
                userForcedBuiltInSpeakerSession = true
            } else {
                userForcedBuiltInSpeakerSession = false
                registerPreferredDevice(manualMatch, moveToFront: true)
            }
            routeToPhysicalDevice(manualMatch, userInitiated: true)
            return
        }

        // Otherwise, the previous device disconnected / powered off or is waking -> run priority evaluation
        evaluatePriorityAndRoute(reason: "system-default-changed")
    }

    private func routeToPhysicalDevice(_ device: CoreAudioDevice, userInitiated: Bool) {
        beginInternalRoutingSuppression(duration: 0.65)

        activeDevice = device

        // Restore saved volume & mute for this device
        let savedVol = savedVolume(for: device)
        let savedMuted = savedMute(for: device)
        volume = savedVol
        isMuted = savedMuted

        guard isEnabled else {
            CoreAudioDevice.currentDefaultOutputDevice = device
            onStateChanged?()
            return
        }

        if let virtualDev = VirtualDriverBridge.shared.device, !VirtualDriverBridge.shared.needsDriverUpdate {
            isVirtualDriverAvailable = true
            needsDriverUpdate = false
            let hudLabel = "VolumeGuard (\(device.name))"
            VirtualDriverBridge.shared.setName(hudLabel)
            VirtualDriverBridge.shared.setShown(true)
            VirtualDriverBridge.shared.syncSampleRate(to: device)

            // Sync virtual driver's hardware volume scalar (0.0...1.0) so macOS OSD HUD matches
            isUpdatingDriverVolume = true
            virtualDev.setVirtualMasterVolume(min(savedVol, 1.0))
            virtualDev.setMuted(savedMuted)
            isUpdatingDriverVolume = false

            attachVirtualDeviceListeners(virtualDev)

            engine.gain = savedVol
            engine.isMuted = savedMuted

            // If physical device also has its own hardware volume control, set it to 100% (unity)
            // so VolumeGuard's digital curve controls the full dynamic range cleanly
            if device.supportsHardwareOutputVolume {
                device.setVirtualMasterVolume(1.0)
                device.setMuted(false)
            }

            let started = engine.start(virtualDevice: virtualDev, outputDevice: device)
            isPassthroughActive = started

            if started {
                // Briefly switch default output if needed so macOS Control Center & Volume HUD
                // immediately refresh the "VolumeGuard (<Device>)" label.
                if CoreAudioDevice.currentDefaultOutputDevice?.id == virtualDev.id {
                    CoreAudioDevice.currentDefaultOutputDevice = device
                }
                CoreAudioDevice.currentDefaultOutputDevice = virtualDev
                statusMessage = nil
            } else {
                CoreAudioDevice.currentDefaultOutputDevice = device
                statusMessage = LocalizationManager.shared.waitingForDeviceStatus
            }
        } else {
            // Virtual driver not installed yet or needs update: switch macOS default output directly to the physical device
            isVirtualDriverAvailable = VirtualDriverBridge.shared.isAvailable
            needsDriverUpdate = VirtualDriverBridge.shared.needsDriverUpdate
            isPassthroughActive = false
            engine.stop()

            if CoreAudioDevice.currentDefaultOutputDevice?.id != device.id {
                CoreAudioDevice.currentDefaultOutputDevice = device
            }
            if device.supportsHardwareOutputVolume {
                device.setVirtualMasterVolume(min(savedVol, 1.0))
                device.setMuted(savedMuted)
            }
        }

        onStateChanged?()
    }

    // MARK: - Volume & Mute Control

    func setVolume(_ newVolume: Float, syncToDriver: Bool = true) {
        let maxAllowed: Float = boostEnabled ? 2.0 : 1.0
        let clamped = min(max(newVolume, 0.0), maxAllowed)
        volume = clamped
        if clamped > 0.001 && isMuted {
            isMuted = false
        }

        engine.gain = clamped
        engine.isMuted = isMuted

        if let active = activeDevice {
            saveVolume(clamped, for: active)
            saveMute(isMuted, for: active)
        }

        if syncToDriver {
            if isEnabled, let virtualDev = VirtualDriverBridge.shared.device {
                isUpdatingDriverVolume = true
                virtualDev.setVirtualMasterVolume(min(clamped, 1.0))
                virtualDev.setMuted(isMuted)
                isUpdatingDriverVolume = false
            } else if let active = activeDevice, active.supportsHardwareOutputVolume {
                active.setVirtualMasterVolume(min(clamped, 1.0))
                active.setMuted(isMuted)
            }
        }

        onStateChanged?()
    }

    func toggleMute() {
        setMuted(!isMuted, syncToDriver: true)
    }

    func setMuted(_ muted: Bool, syncToDriver: Bool = true) {
        isMuted = muted
        engine.isMuted = muted

        if let active = activeDevice {
            saveMute(muted, for: active)
        }

        if syncToDriver {
            if isEnabled, let virtualDev = VirtualDriverBridge.shared.device {
                isUpdatingDriverVolume = true
                virtualDev.setMuted(muted)
                isUpdatingDriverVolume = false
            } else if let active = activeDevice {
                active.setMuted(muted)
            }
        }

        onStateChanged?()
    }

    func stepVolume(delta: Float) {
        if isMuted && delta > 0 {
            setMuted(false, syncToDriver: true)
        }
        setVolume(volume + delta, syncToDriver: true)
    }

    // MARK: - Driver Installation

    func installVirtualDriver() {
        guard !isInstallingDriver else { return }
        isInstallingDriver = true
        statusMessage = LocalizationManager.shared.installingDriverStatus

        VirtualDriverBridge.shared.installDriverWithAdminPrompt { [weak self] success, errorMsg in
            guard let self = self else { return }
            self.isInstallingDriver = false
            self.refreshDeviceList()
            if success {
                let successText = LocalizationManager.shared.driverInstalledSuccessStatus
                self.statusMessage = successText
                self.scheduleReevaluationWave(reason: "driver-installed")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if self.statusMessage == successText {
                        self.statusMessage = nil
                    }
                }
            } else if let errorMsg = errorMsg {
                self.statusMessage = LocalizationManager.shared.errorStatus(errorMsg)
            }
        }
    }

    // MARK: - Preferred Devices Persistence

    func isPreferred(_ device: CoreAudioDevice) -> Bool {
        guard let uid = device.uid else { return false }
        return preferredDevices.contains(where: { $0.uid == uid })
    }

    func togglePreferred(_ device: CoreAudioDevice) {
        guard !device.isBuiltInSpeaker, let uid = device.uid else { return }
        if let idx = preferredDevices.firstIndex(where: { $0.uid == uid }) {
            preferredDevices.remove(at: idx)
            Self.savePreferredDevices(preferredDevices)
        } else {
            registerPreferredDevice(device, moveToFront: true)
            if autoSwitchEnabled && isEnabled {
                userForcedBuiltInSpeakerSession = false
                evaluatePriorityAndRoute(reason: "preferred-toggled")
            }
        }
    }

    private func registerPreferredDevice(_ device: CoreAudioDevice, moveToFront: Bool) {
        guard !device.isBuiltInSpeaker, let uid = device.uid else { return }
        let record = PreferredDeviceRecord(
            uid: uid,
            name: device.name,
            transportRaw: device.transportType.rawValue
        )
        if let existingIdx = preferredDevices.firstIndex(where: { $0.uid == uid }) {
            preferredDevices[existingIdx] = record
            if moveToFront && existingIdx != 0 {
                let item = preferredDevices.remove(at: existingIdx)
                preferredDevices.insert(item, at: 0)
            }
        } else {
            if moveToFront {
                preferredDevices.insert(record, at: 0)
            } else {
                preferredDevices.append(record)
            }
        }
        Self.savePreferredDevices(preferredDevices)
    }

    private static func loadPreferredDevices() -> [PreferredDeviceRecord] {
        guard let data = UserDefaults.standard.data(forKey: Keys.preferredDevices),
              let decoded = try? JSONDecoder().decode([PreferredDeviceRecord].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func savePreferredDevices(_ list: [PreferredDeviceRecord]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Keys.preferredDevices)
        }
    }

    private func savedVolume(for device: CoreAudioDevice) -> Float {
        guard let uid = device.uid else { return 0.75 }
        let dict = UserDefaults.standard.dictionary(forKey: Keys.perDeviceVolume) as? [String: Float] ?? [:]
        return dict[uid] ?? 0.75
    }

    private func saveVolume(_ vol: Float, for device: CoreAudioDevice) {
        guard let uid = device.uid else { return }
        var dict = UserDefaults.standard.dictionary(forKey: Keys.perDeviceVolume) as? [String: Float] ?? [:]
        dict[uid] = vol
        UserDefaults.standard.set(dict, forKey: Keys.perDeviceVolume)
    }

    private func savedMute(for device: CoreAudioDevice) -> Bool {
        guard let uid = device.uid else { return false }
        let dict = UserDefaults.standard.dictionary(forKey: Keys.perDeviceMute) as? [String: Bool] ?? [:]
        return dict[uid] ?? false
    }

    private func saveMute(_ muted: Bool, for device: CoreAudioDevice) {
        guard let uid = device.uid else { return }
        var dict = UserDefaults.standard.dictionary(forKey: Keys.perDeviceMute) as? [String: Bool] ?? [:]
        dict[uid] = muted
        UserDefaults.standard.set(dict, forKey: Keys.perDeviceMute)
    }

    // MARK: - CoreAudio & System Wake Observers

    private func setupSystemListeners() {
        var devListAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lastTopologyOrWakeEventTime = Date()
                self.userForcedBuiltInSpeakerSession = false
                self.scheduleReevaluationWave(reason: "devices-changed")
            }
        }
        deviceListListenerBlock = devBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devListAddr,
            listenerQueue,
            devBlock
        )

        var defaultOutAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self = self, !self.isInternalRoutingChange else { return }
                self.handleExternalDefaultOutputChange()
            }
        }
        defaultOutputListenerBlock = defBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutAddr,
            listenerQueue,
            defBlock
        )
    }

    private func attachVirtualDeviceListeners(_ virtualDev: CoreAudioDevice) {
        if registeredVirtualDeviceID == virtualDev.id { return }
        removeVirtualDeviceListeners()
        registeredVirtualDeviceID = virtualDev.id

        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let volBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self = self, self.isEnabled, !self.isUpdatingDriverVolume else { return }
                guard let vDev = VirtualDriverBridge.shared.device,
                      let driverVol = vDev.virtualMasterVolume else { return }
                if self.volume > 1.0 && driverVol < 1.0 {
                    return
                }
                self.setVolume(driverVol, syncToDriver: false)
            }
        }
        virtualVolumeListenerBlock = volBlock
        AudioObjectAddPropertyListenerBlock(virtualDev.id, &volAddr, listenerQueue, volBlock)

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let muteBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self = self, self.isEnabled, !self.isUpdatingDriverVolume else { return }
                guard let vDev = VirtualDriverBridge.shared.device else { return }
                self.setMuted(vDev.isMuted, syncToDriver: false)
            }
        }
        virtualMuteListenerBlock = muteBlock
        AudioObjectAddPropertyListenerBlock(virtualDev.id, &muteAddr, listenerQueue, muteBlock)
    }

    private func removeVirtualDeviceListeners() {
        guard let oldID = registeredVirtualDeviceID else { return }
        if let volBlock = virtualVolumeListenerBlock {
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(oldID, &volAddr, listenerQueue, volBlock)
        }
        if let muteBlock = virtualMuteListenerBlock {
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(oldID, &muteAddr, listenerQueue, muteBlock)
        }
        registeredVirtualDeviceID = nil
        virtualVolumeListenerBlock = nil
        virtualMuteListenerBlock = nil
    }

    private func setupWorkspaceWakeObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.isSystemOrDisplaySleeping = true
            self.lastTopologyOrWakeEventTime = Date()
            self.userForcedBuiltInSpeakerSession = false
        }
        wsCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.isSystemOrDisplaySleeping = true
            self.lastTopologyOrWakeEventTime = Date()
            self.userForcedBuiltInSpeakerSession = false
        }
        wsCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.isSystemOrDisplaySleeping = false
            self.lastTopologyOrWakeEventTime = Date()
            self.userForcedBuiltInSpeakerSession = false
            // Force a clean AudioUnit rebuild on screen wake in case HDMI kept the same AudioObjectID
            self.engine.stop()
            self.scheduleReevaluationWave(reason: "screens-did-wake")
        }
        wsCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.isSystemOrDisplaySleeping = false
            self.lastTopologyOrWakeEventTime = Date()
            self.userForcedBuiltInSpeakerSession = false
            self.engine.stop()
            self.scheduleReevaluationWave(reason: "system-did-wake")
        }
    }

    private func cancelReevaluationWave() {
        for item in reevaluationWaveWorkItems {
            item.cancel()
        }
        reevaluationWaveWorkItems.removeAll()
    }

    private func scheduleReevaluationWave(reason: String) {
        guard isEnabled else { return }
        cancelReevaluationWave()
        evaluatePriorityAndRoute(reason: reason)
        for delay in [0.4, 1.2, 2.5, 4.5, 7.5] {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.isEnabled else { return }
                self.evaluatePriorityAndRoute(reason: "\(reason)-retry-\(delay)s")
            }
            reevaluationWaveWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func watchdogTick() {
        guard isEnabled else { return }
        refreshDeviceList()

        if autoSwitchEnabled && !userForcedBuiltInSpeakerSession {
            let externalReady = outputDevices.contains { dev in
                !dev.isBuiltInSpeaker && dev.isReadyForPlayback && (dev.transportType.isExternalDisplay || isPreferred(dev))
            }
            if externalReady && (activeDevice == nil || activeDevice?.isBuiltInSpeaker == true) {
                evaluatePriorityAndRoute(reason: "watchdog-external-ready")
                return
            }
        }

        if let virtualDev = VirtualDriverBridge.shared.device,
           !needsDriverUpdate,
           let active = activeDevice,
           active.isReadyForPlayback {
            if !engine.isHealthyAndRendering ||
               engine.currentOutputDeviceID != active.id ||
               CoreAudioDevice.currentDefaultOutputDevice?.id != virtualDev.id {
                evaluatePriorityAndRoute(reason: "watchdog-passthrough-heal")
            }
        }
    }

    private func setupMediaKeyCallbacks() {
        let interceptor = MediaKeyInterceptor.shared
        interceptor.shouldInterceptEvent = { [weak self] in
            guard let self = self, self.isEnabled else { return false }
            if !self.isVirtualDriverAvailable {
                return true
            }
            if self.boostEnabled && self.volume >= 0.95 {
                return true
            }
            return false
        }
        interceptor.onVolumeUp = { [weak self] in
            self?.stepVolume(delta: 0.0625)
        }
        interceptor.onVolumeDown = { [weak self] in
            self?.stepVolume(delta: -0.0625)
        }
        interceptor.onMuteToggle = { [weak self] in
            self?.toggleMute()
        }
    }
}
