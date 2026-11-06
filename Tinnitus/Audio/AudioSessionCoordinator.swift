import AVFoundation

/// The one audio session is shared by the sleep player, the music player, and the test tones. Each
/// says when it starts and stops making sound; the session is released only when none are, so other
/// apps can resume and iOS can suspend this app in the background.
@MainActor
enum AudioSessionCoordinator {
    enum User: Hashable {
        case sleep, music, tones
    }

    private static var active: Set<User> = []

    static func activate(_ user: User) throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback || session.mode != .default {
            try session.setCategory(.playback, mode: .default)
        }
        // Also reactivates after an interruption such as a phone call.
        try session.setActive(true)
        active.insert(user)
    }

    static func deactivate(_ user: User) {
        guard active.remove(user) != nil, active.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
