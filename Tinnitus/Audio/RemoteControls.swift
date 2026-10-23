import MediaPlayer

/// Lock screen and headphone buttons. Whichever player started most recently owns them.
enum RemoteControls {
    static func claim(
        play: @escaping () -> Void,
        pause: @escaping () -> Void,
        toggle: @escaping () -> Void,
        next: (() -> Void)? = nil,
        previous: (() -> Void)? = nil,
        seek: ((TimeInterval) -> Void)? = nil
    ) {
        let commands = MPRemoteCommandCenter.shared()
        set(commands.playCommand, play)
        set(commands.pauseCommand, pause)
        set(commands.togglePlayPauseCommand, toggle)
        set(commands.nextTrackCommand, next)
        set(commands.previousTrackCommand, previous)

        let position = commands.changePlaybackPositionCommand
        position.removeTarget(nil)
        position.isEnabled = seek != nil
        if let seek {
            position.addTarget { event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                seek(event.positionTime)
                return .success
            }
        }
    }

    private static func set(_ command: MPRemoteCommand, _ action: (() -> Void)?) {
        command.removeTarget(nil)
        command.isEnabled = action != nil
        if let action {
            command.addTarget { _ in
                action()
                return .success
            }
        }
    }
}
