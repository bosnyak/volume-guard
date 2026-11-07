import AppKit

/// Intercepts macOS media volume keys (F10 Mute, F11 Volume Down, F12 Volume Up)
/// when Volume Boost (>100%) is active or when the active device lacks native volume control.
final class MediaKeyInterceptor {
    static let shared = MediaKeyInterceptor()

    private let NX_KEYTYPE_SOUND_UP: Int = 0
    private let NX_KEYTYPE_SOUND_DOWN: Int = 1
    private let NX_KEYTYPE_MUTE: Int = 7

    var onVolumeUp: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    var onMuteToggle: (() -> Void)?

    /// Return true to intercept the media key event in app (e.g., when volume > 100% boost
    /// or when virtual driver is not installed yet).
    var shouldInterceptEvent: (() -> Bool)?

    func handleSystemDefinedEvent(_ event: NSEvent) -> Bool {
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else {
            return false
        }

        let data1 = event.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let keyPressed = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let keyRepeat = (keyFlags & 0x1) == 0x1

        guard keyCode == NX_KEYTYPE_SOUND_UP || keyCode == NX_KEYTYPE_SOUND_DOWN || keyCode == NX_KEYTYPE_MUTE else {
            return false
        }

        guard shouldInterceptEvent?() == true else {
            return false
        }

        if keyPressed || keyRepeat {
            switch keyCode {
            case NX_KEYTYPE_SOUND_UP:
                onVolumeUp?()
            case NX_KEYTYPE_SOUND_DOWN:
                onVolumeDown?()
            case NX_KEYTYPE_MUTE:
                if !keyRepeat {
                    onMuteToggle?()
                }
            default:
                break
            }
        }
        return true
    }
}
