import AVFoundation
import MediaPlayer
import Observation
import os
import TinnitusCore

/// Plays the procedural sleep sounds through the tinnitus notch, in the background and on the lock screen.
/// When playback stops, the audio engine shuts down and the audio session is released, so the app
/// doesn't keep running in the background after the sleep timer ends.
@MainActor
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
    @ObservationIgnored private var shutdown: DispatchWorkItem?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// How long after a pause the engine shuts down: long enough for the volume to glide to silence.
    static let shutdownDelay: TimeInterval = 0.6

    init() {
        let defaults = UserDefaults.standard
        sound = defaults.string(forKey: "sleepSound").flatMap(SleepSound.init(rawValue:)) ?? .pink
        if defaults.object(forKey: "sleepLevelDBFS") != nil {
            levelDBFS = min(defaults.double(forKey: "sleepLevelDBFS"), SafetyLimits.maxSleepLevelDBFS)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                // Headphones unplugged: pause instead of switching to the speaker.
                if reason == .oldDeviceUnavailable { self?.pause() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            MainActor.assumeIsolated {
                self?.handleInterruption(type: type, options: options)
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuild()
            }
        })
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
        shutdown?.cancel()
        shutdown = nil
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
        scheduleShutdown()
    }

    /// Stops the engine and releases the audio session once the volume has faded out.
    private func scheduleShutdown() {
        shutdown?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isPlaying else { return }
                self.tearDown()
            }
        }
        shutdown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shutdownDelay, execute: work)
    }

    private func tearDown() {
        shutdown?.cancel()
        shutdown = nil
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
        }
        sourceNode = nil
        renderState = nil
        AudioSessionCoordinator.deactivate(.sleep)
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
            MainActor.assumeIsolated {
                self?.tickTimer()
            }
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
            try AudioSessionCoordinator.activate(.sleep)

            let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            let sampleRate = outputRate > 0 ? outputRate : 48_000
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
            let state = MixerRenderState(mixer: SleepMixer(sampleRate: sampleRate, configuration: configuration(sampleRate: sampleRate)))
            let node = Self.makeSourceNode(format: format, state: state)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            sourceNode = node
            engine.prepare()
            try engine.start()
            renderState = state
            errorMessage = nil
        } catch {
            errorMessage = "Audio could not start: \(error.localizedDescription)"
            tearDown()
        }
    }

    /// Built outside the main actor, so the render block carries no main-actor isolation onto the audio thread.
    private nonisolated static func makeSourceNode(format: AVAudioFormat, state: MixerRenderState) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            state.render(left: left, right: right, frameCount: Int(frameCount))
            return noErr
        }
    }

    private func rebuild() {
        let wasPlaying = isPlaying
        tearDown()
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

    /// True while a phone call or similar has paused playback that should resume afterward.
    @ObservationIgnored private var interruptedWhilePlaying = false

    private func handleInterruption(type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            interruptedWhilePlaying = isPlaying
            guard isPlaying else { return }
            isPlaying = false
            updateNowPlaying()
            // The system has already stopped the sound, so shut down now; play() rebuilds.
            tearDown()
        case .ended:
            if interruptedWhilePlaying && options.contains(.shouldResume) {
                play()
            }
            interruptedWhilePlaying = false
        default:
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

/// Owns the mixer on the audio thread. New settings arrive through a mailbox the audio thread never
/// waits on, and old settings are released back on the main thread.
private final class MixerRenderState: @unchecked Sendable {
    let mixer: SleepMixer
    private let mailbox = RealtimeMailbox<SleepMixer.Configuration>()
    /// Audio thread only: the settings being swapped in or out.
    private var scratch: SleepMixer.Configuration

    init(mixer: SleepMixer) {
        self.mixer = mixer
        scratch = mixer.configuration
    }

    func submit(_ configuration: SleepMixer.Configuration) {
        mailbox.post(configuration)
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frameCount: Int) {
        if mailbox.exchange(&scratch) {
            // `scratch` now holds the new settings; apply swaps the mixer's old ones back into it,
            // and the next exchange hands those to the main thread to release.
            mixer.apply(&scratch)
        }
        mixer.render(left: left, right: right, frameCount: frameCount)
    }
}
