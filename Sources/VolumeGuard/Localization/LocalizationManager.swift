import Foundation
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case portuguese = "pt"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "EN"
        case .portuguese: return "PT"
        }
    }

    var fullName: String {
        switch self {
        case .english: return "English"
        case .portuguese: return "Português"
        }
    }
}

final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    private static let storageKey = "vg.language"

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
        }
    }

    private init() {
        if let saved = UserDefaults.standard.string(forKey: Self.storageKey),
           let lang = AppLanguage(rawValue: saved) {
            self.language = lang
        } else {
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            self.language = preferred.hasPrefix("pt") ? .portuguese : .english
        }
    }

    // MARK: - Localized Strings

    var statusActive: String {
        language == .portuguese ? "Ativo" : "Active"
    }

    var statusDisabled: String {
        language == .portuguese ? "Desativado" : "Disabled"
    }

    var enableAppTooltip: String {
        language == .portuguese
            ? "Ativar ou desativar o VolumeGuard (restaura o áudio nativo do Mac quando desativado)"
            : "Enable or disable VolumeGuard (restores native Mac audio when disabled)"
    }

    var disabledBannerTitle: String {
        language == .portuguese
            ? "VolumeGuard está desativado"
            : "VolumeGuard is disabled"
    }

    var disabledBannerSubtitle: String {
        language == .portuguese
            ? "O controle de áudio está direto pelo macOS."
            : "Audio routing is currently managed directly by macOS."
    }

    var enableButtonTitle: String {
        language == .portuguese ? "Ativar VolumeGuard" : "Enable VolumeGuard"
    }

    var passthroughActiveTooltip: String {
        language == .portuguese ? "Controle de volume digital ativo" : "Digital volume control active"
    }

    var directModeTooltip: String {
        language == .portuguese ? "Modo direto" : "Direct mode"
    }

    var noOutputDetected: String {
        language == .portuguese ? "Nenhuma saída detectada" : "No output device detected"
    }

    var unmuteTooltip: String {
        language == .portuguese ? "Ativar som" : "Unmute"
    }

    var muteTooltip: String {
        language == .portuguese ? "Silenciar (Mudo)" : "Mute"
    }

    var boostTooltip: String {
        language == .portuguese ? "Ativar Boost de Volume até 200%" : "Enable Volume Boost up to 200%"
    }

    var driverNeededTitle: String {
        language == .portuguese
            ? "Driver de Áudio Virtual necessário para controle HDMI"
            : "Virtual Audio Driver required for HDMI volume control"
    }

    var installingDriverButton: String {
        language == .portuguese ? "Instalando..." : "Installing..."
    }

    var installDriverButton: String {
        language == .portuguese ? "Instalar VolumeGuard Driver" : "Install VolumeGuard Driver"
    }

    var updateDriverForLabelText: String {
        language == .portuguese
            ? "Atualize o driver para remover o ícone de microfone"
            : "Update driver to remove the microphone indicator icon"
    }

    var updateDriverButton: String {
        language == .portuguese ? "Atualizar Driver" : "Update Driver"
    }

    var outputDevicesHeader: String {
        language == .portuguese ? "SAÍDAS DE ÁUDIO" : "AUDIO OUTPUTS"
    }

    var refreshDevicesTooltip: String {
        language == .portuguese ? "Atualizar dispositivos" : "Refresh devices"
    }

    var preferredActiveTooltip: String {
        language == .portuguese
            ? "Prioridade automática ativada (clique para remover)"
            : "Auto-priority enabled (click to remove)"
    }

    var preferredInactiveTooltip: String {
        language == .portuguese
            ? "Priorizar automaticamente ao ligar/conectar"
            : "Automatically prioritize when connected/powered on"
    }

    var autoSwitchTitle: String {
        language == .portuguese
            ? "Sempre priorizar HDMI / Externa"
            : "Always prioritize HDMI / External"
    }

    var autoSwitchSubtitle: String {
        language == .portuguese
            ? "Muda automaticamente quando o monitor liga"
            : "Automatically switches when monitor turns on"
    }

    var launchAtLoginTitle: String {
        language == .portuguese
            ? "Iniciar ao ligar o Mac"
            : "Launch at Login"
    }

    var launchAtLoginSubtitle: String {
        language == .portuguese
            ? "Abre o VolumeGuard automaticamente no login"
            : "Automatically starts VolumeGuard when you log in"
    }

    var quitButton: String {
        language == .portuguese ? "Sair do VolumeGuard" : "Quit VolumeGuard"
    }

    var waitingForDeviceStatus: String {
        language == .portuguese ? "Aguardando dispositivo..." : "Waiting for device..."
    }

    var installingDriverStatus: String {
        language == .portuguese ? "Instalando driver de áudio virtual..." : "Installing virtual audio driver..."
    }

    var driverInstalledSuccessStatus: String {
        language == .portuguese ? "Driver ativado com sucesso!" : "Driver enabled successfully!"
    }

    func errorStatus(_ msg: String) -> String {
        language == .portuguese ? "Erro: \(msg)" : "Error: \(msg)"
    }

    func transportLabel(_ transport: AudioTransportType) -> String {
        switch transport {
        case .builtIn:
            return language == .portuguese ? "Interno" : "Built-In"
        case .unknown:
            return language == .portuguese ? "Desconhecido" : "Unknown"
        default:
            return transport.rawValue
        }
    }
}
