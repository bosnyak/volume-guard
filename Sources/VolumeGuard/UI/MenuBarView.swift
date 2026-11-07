import SwiftUI

struct MenuBarView: View {
    @ObservedObject var manager: OutputPriorityManager
    @ObservedObject var l10n = LocalizationManager.shared
    @ObservedObject var launchAtLogin = LaunchAtLoginManager.shared

    private var maxVolume: Double {
        manager.boostEnabled ? 2.0 : 1.0
    }

    private var volumePercentage: Int {
        manager.isMuted ? 0 : Int(round(manager.volume * 100))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerSection

            Divider()

            if !manager.isEnabled {
                disabledBanner
            } else {
                volumeSection

                if !manager.isVirtualDriverAvailable {
                    driverWarningBanner
                } else if manager.needsDriverUpdate {
                    driverUpdateBanner
                }
            }

            Divider()

            devicesSection

            Divider()

            footerSection
        }
        .padding(14)
        .frame(width: 330)
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(manager.isEnabled ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(nsImage: MenuBarIconRenderer.makeIcon(
                    volume: manager.volume,
                    isMuted: manager.isMuted,
                    isEnabled: manager.isEnabled
                ))
                .foregroundColor(manager.isEnabled ? .accentColor : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("VolumeGuard")
                        .font(.system(size: 13, weight: .bold))
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 7, height: 7)
                        .help(statusDotTooltip)
                }

                if !manager.isEnabled {
                    Text(l10n.statusDisabled)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                } else if let active = manager.activeDevice {
                    Text("\(active.name) • \(l10n.transportLabel(active.transportType))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text(l10n.noOutputDetected)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if manager.isEnabled {
                Text("\(volumePercentage)%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(manager.volume > 1.0 && !manager.isMuted ? .orange : .primary)
            }

            Button(action: {
                manager.isEnabled.toggle()
            }) {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(manager.isEnabled ? .green : .secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .tint(manager.isEnabled ? .green : .secondary)
            .help(l10n.enableAppTooltip)
        }
    }

    private var disabledBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.disabledBannerTitle)
                        .font(.system(size: 11, weight: .semibold))
                    Text(l10n.disabledBannerSubtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Button(action: { manager.isEnabled = true }) {
                Text(l10n.enableButtonTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.1))
        )
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(action: { manager.toggleMute() }) {
                    Image(systemName: manager.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(manager.isMuted ? .red : .primary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.bordered)
                .help(manager.isMuted ? l10n.unmuteTooltip : l10n.muteTooltip)

                Slider(
                    value: Binding(
                        get: { Double(manager.isMuted ? 0 : manager.volume) },
                        set: { newVal in
                            manager.setVolume(Float(newVal), syncToDriver: true)
                        }
                    ),
                    in: 0.0...maxVolume
                )

                Button(action: { manager.boostEnabled.toggle() }) {
                    Text("200%")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(manager.boostEnabled ? .orange : .secondary)
                .help(l10n.boostTooltip)
            }

            HStack(spacing: 6) {
                ForEach([0.25, 0.50, 0.75, 1.0], id: \.self) { preset in
                    Button(action: {
                        manager.setVolume(Float(preset), syncToDriver: true)
                    }) {
                        Text("\(Int(preset * 100))%")
                            .font(.system(size: 10, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var driverWarningBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(l10n.driverNeededTitle)
                    .font(.system(size: 11, weight: .semibold))
            }
            Button(action: { manager.installVirtualDriver() }) {
                HStack {
                    if manager.isInstallingDriver {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(manager.isInstallingDriver ? l10n.installingDriverButton : l10n.installDriverButton)
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(manager.isInstallingDriver)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private var driverUpdateBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundColor(.accentColor)
                Text(l10n.updateDriverForLabelText)
                    .font(.system(size: 11, weight: .medium))
            }
            Button(action: { manager.installVirtualDriver() }) {
                HStack {
                    if manager.isInstallingDriver {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(manager.isInstallingDriver ? l10n.installingDriverButton : l10n.updateDriverButton)
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(manager.isInstallingDriver)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
        )
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(l10n.outputDevicesHeader)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { manager.evaluatePriorityAndRoute(reason: "manual-refresh") }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(l10n.refreshDevicesTooltip)
            }

            VStack(spacing: 4) {
                ForEach(manager.outputDevices) { dev in
                    deviceRow(for: dev)
                }
            }
        }
    }

    private func deviceRow(for dev: CoreAudioDevice) -> some View {
        let isSelected = (manager.activeDevice?.id == dev.id)
        let isPref = manager.isPreferred(dev)

        return HStack(spacing: 8) {
            Button(action: {
                manager.selectDeviceFromUI(dev)
            }) {
                HStack(spacing: 8) {
                    Image(systemName: dev.transportType.sfSymbolName)
                        .font(.system(size: 13))
                        .foregroundColor(isSelected && manager.isEnabled ? .accentColor : .secondary)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(dev.name)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(l10n.transportLabel(dev.transportType))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(manager.isEnabled ? .accentColor : .secondary)
                            .font(.system(size: 13))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !dev.isBuiltInSpeaker {
                Button(action: {
                    manager.togglePreferred(dev)
                }) {
                    Image(systemName: isPref ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundColor(isPref ? .yellow : .secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help(isPref ? l10n.preferredActiveTooltip : l10n.preferredInactiveTooltip)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $manager.autoSwitchEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(l10n.autoSwitchTitle)
                        .font(.system(size: 11, weight: .medium))
                    Text(l10n.autoSwitchSubtitle)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!manager.isEnabled)

            Toggle(isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { newValue in launchAtLogin.setEnabled(newValue) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(l10n.launchAtLoginTitle)
                        .font(.system(size: 11, weight: .medium))
                    Text(l10n.launchAtLoginSubtitle)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if let msg = manager.statusMessage {
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Text("v1.0.0")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Picker("", selection: $l10n.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 72)

                Spacer()

                Button(l10n.quitButton) {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.red.opacity(0.85))
            }
            .padding(.top, 2)
        }
    }

    private var statusDotColor: Color {
        if !manager.isEnabled {
            return .gray
        }
        return manager.isPassthroughActive ? .green : .orange
    }

    private var statusDotTooltip: String {
        if !manager.isEnabled {
            return l10n.statusDisabled
        }
        return manager.isPassthroughActive ? l10n.passthroughActiveTooltip : l10n.directModeTooltip
    }

    private var speakerSymbolName: String {
        if !manager.isEnabled {
            return "speaker.fill"
        }
        if manager.isMuted || manager.volume <= 0.001 {
            return "speaker.slash.fill"
        } else if manager.volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if manager.volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}
