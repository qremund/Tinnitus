import AVFoundation
import MediaPlayer
import Observation
import os
import TinnitusCore

/// Plays the procedural sleep sounds through the tinnitus notch, in the background and on the lock screen.
@Observable
final class SleepPlayer {
    private(set) var isPlaying = false
    private(set) var errorMessage: String?
    /// When the sleep timer will finish fading out, or nil if no timer is running.
    private(set) var timerEnd: Date?

    var sound: SleepSound = .pink {
        didSet {
            UserDefaults.standard.set(sound.rawValue, forKey: "sleepSound")
            submit()
            updateNowPlaying()
        }
    }
    var levelDBFS = -30.0 {
        didSet {
            UserDefaults.standard.set(levelDBFS, forKey: "sleepLevelDBFS")
            submit()
        }
    }
    var filterEnabled = true { didSet { submit(); updateNowPlaying() } }

    /// Called before playback starts, so other players can stop.
    @ObservationIgnored var onWillPlay: (() -> Void)?

    /// Fade length at the end of the sleep timer.
    static let fadeDuration: TimeInterval = 60

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var sourceNode: AVAudioSourceNode?
    @ObservationIgnored private var renderState: MixerRenderState?
    private var notchPitches = EarPitches.none
    @ObservationIgnored private var notchWidthOctaves = 1.0
    @ObservationIgnored private var fadeGain = 1.0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let defaults = UserDefaults.standard
        sound = defaults.string(forKey: "sleepSound").flatMap(SleepSound.init(rawValue:)) ?? .pink
        if defaults.object(forKey: "sleepLevelDBFS") != nil {
            levelDBFS = min(defaults.double(forKey: "sleepLevelDBFS"), SafetyLimits.maxSleepLevelDBFS)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            if let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable {
                // Headphones unplugged: pause instead of switching to the speaker.
                self?.pause()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.rebuild()
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var hasNotch: Bool { !notchPitches.isEmpty }

    /// Sets each ear's notch from the saved profiles. An ear without a pitch plays unfiltered.
    func setNotch(pitches: EarPitches, widthOctaves: Double) {
        guard pitches != notchPitches || widthOctaves != notchWidthOctaves else { return }
        notchPitches = pitches
        notchWidthOctaves = widthOctaves
        submit()
    }

    func play() {
        onWillPlay?()
        prepare()
        guard renderState != nil else { return }
        isPlaying = true
        submit()
        claimRemoteControls()
        updateNowPlaying()
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        cancelTimer()
        submit()
        updateNowPlaying()
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    // MARK: Sleep timer

    func startTimer(minutes: Int) {
        cancelTimer()
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        timerEnd = end
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tickTimer()
        }
    }

    func cancelTimer() {
        timer?.invalidate()
        timer = nil
        timerEnd = nil
        if fadeGain != 1 {
            fadeGain = 1
            submit()
        }
    }

    private func tickTimer() {
        guard let end = timerEnd else { return }
        let remaining = end.timeIntervalSinceNow
        if remaining <= 0 {
            pause()
            return
        }
        fadeGain = min(remaining / Self.fadeDuration, 1)
        submit()
    }

    // MARK: Engine

    private func prepare() {
        guard renderState == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            let sampleRate = outputRate > 0 ? outputRate : 48_000
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
            let state = MixerRenderState(mixer: SleepMixer(sampleRate: sampleRate, configuration: configuration(sampleRate: sampleRate)))
            let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
                state.render(left: left, right: right, frameCount: Int(frameCount))
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            sourceNode = node
            renderState = state
            errorMessage = nil
        } catch {
            errorMessage = "Audio could not start: \(error.localizedDescription)"
        }
    }

    private func rebuild() {
        let wasPlaying = isPlaying
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
        }
        sourceNode = nil
        renderState = nil
        if wasPlaying {
            play()
        }
    }

    private func configuration(sampleRate: Double) -> SleepMixer.Configuration {
        SleepMixer.Configuration(
            sound: sound,
            levelDBFS: levelDBFS,
            isPlaying: isPlaying,
            leftNotch: notchPitches.notch(for: .left, widthOctaves: notchWidthOctaves, sampleRate: sampleRate),
            rightNotch: notchPitches.notch(for: .right, widthOctaves: notchWidthOctaves, sampleRate: sampleRate),
            filterEnabled: filterEnabled,
            fadeGain: fadeGain
        )
    }

    private func submit() {
        guard let state = renderState else { return }
        state.submit(configuration(sampleRate: state.mixer.sampleRate))
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            isPlaying = false
            submit()
            updateNowPlaying()
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            if options.contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                try? engine.start()
                play()
            }
        @unknown default:
            break
        }
    }

    // MARK: Lock screen

    private func claimRemoteControls() {
        RemoteControls.claim(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlayback() }
        )
    }

    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: sound.title,
            MPMediaItemPropertyArtist: hasNotch && filterEnabled ? "Tinnitus notch on" : "Tinnitus",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }
}

/// Owns the mixer on the audio thread. New settings arrive through a lock the audio thread never waits on.
private final class MixerRenderState {
    let mixer: SleepMixer
    private let pending = OSAllocatedUnfairLock<SleepMixer.Configuration?>(initialState: nil)

    init(mixer: SleepMixer) {
        self.mixer = mixer
    }

    func submit(_ configuration: SleepMixer.Configuration) {
        pending.withLock { $0 = configuration }
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frameCount: Int) {
        let next = pending.withLockIfAvailable { state -> SleepMixer.Configuration? in
            defer { state = nil }
            return state
        }
        if let next, let configuration = next {
            mixer.apply(configuration)
        }
        mixer.render(left: left, right: right, frameCount: frameCount)
    }
}
