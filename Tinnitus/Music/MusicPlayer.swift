import AVFoundation
import MediaPlayer
import Observation
import TinnitusCore

/// Plays imported songs, with the notched copy running in sync so the filter can be toggled with a crossfade.
@Observable
final class MusicPlayer {
    private(set) var queue: [Track] = []
    private(set) var currentIndex: Int?
    private(set) var isPlaying = false
    /// True while the notched copy of the current song is being rendered.
    private(set) var isPreparing = false
    private(set) var prepareProgress = 0.0
    private(set) var errorMessage: String?
    private(set) var hasNotch = false

    var filterEnabled = true {
        didSet {
            crossfade()
            updateNowPlaying()
        }
    }

    /// Called before playback starts, so other players can stop.
    @ObservationIgnored var onWillPlay: (() -> Void)?

    static let crossfadeDuration: TimeInterval = 0.3

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let dryNode = AVAudioPlayerNode()
    @ObservationIgnored private let wetNode = AVAudioPlayerNode()
    @ObservationIgnored private let renderer = NotchRenderer()
    @ObservationIgnored private var dryFile: AVAudioFile?
    @ObservationIgnored private var wetFile: AVAudioFile?
    @ObservationIgnored private var renderJob: NotchRenderer.Job?
    @ObservationIgnored private var prefetchJob: NotchRenderer.Job?
    /// File frame where the currently scheduled segment starts.
    @ObservationIgnored private var segmentStart: AVAudioFramePosition = 0
    /// Position to resume from while paused.
    @ObservationIgnored private var pausedFrame: AVAudioFramePosition = 0
    /// Bumped whenever scheduled audio is thrown away, so stale completion callbacks are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var notchPitches = EarPitches.none
    @ObservationIgnored private var notchWidthOctaves = 1.0
    @ObservationIgnored private var wetMix: Float = 1
    @ObservationIgnored private var fadeTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        engine.attach(dryNode)
        engine.attach(wetNode)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            if let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable {
                self?.pause()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var currentTrack: Track? {
        currentIndex.flatMap { queue.indices.contains($0) ? queue[$0] : nil }
    }

    var duration: TimeInterval { currentTrack?.duration ?? 0 }

    /// Playback position in seconds. Not observed, so views poll it with a TimelineView.
    var currentTime: TimeInterval {
        guard let file = dryFile else { return 0 }
        return Double(currentFrame) / file.processingFormat.sampleRate
    }

    // MARK: Notch

    /// Sets each ear's notch from the saved profiles. An ear without a pitch plays unfiltered.
    func setNotch(pitches: EarPitches, widthOctaves: Double) {
        guard pitches != notchPitches || widthOctaves != notchWidthOctaves else { return }
        notchPitches = pitches
        notchWidthOctaves = widthOctaves
        hasNotch = !pitches.isEmpty
        // The rendered copy no longer matches, so reload the song where it is.
        if let index = currentIndex {
            load(index: index, from: currentFrame, autoplay: isPlaying)
        }
    }

    // MARK: Transport

    func play(_ tracks: [Track], startAt index: Int) {
        guard tracks.indices.contains(index) else { return }
        queue = tracks
        load(index: index, from: 0, autoplay: true)
    }

    func play() {
        guard let index = currentIndex else { return }
        // Reload if the filtered copy never finished, so the song doesn't start unfiltered.
        if dryFile == nil || isPreparing || (hasNotch && wetFile == nil) {
            load(index: index, from: pausedFrame, autoplay: true)
        } else {
            start(from: pausedFrame)
        }
    }

    func pause() {
        guard isPlaying || isPreparing else { return }
        pausedFrame = currentFrame
        generation += 1
        renderJob?.cancel()
        isPreparing = false
        dryNode.stop()
        wetNode.stop()
        isPlaying = false
        updateNowPlaying()
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func next() {
        guard let index = currentIndex else { return }
        if index + 1 < queue.count {
            load(index: index + 1, from: 0, autoplay: isPlaying || isPreparing)
        } else {
            stopAtEnd()
        }
    }

    func previous() {
        guard let index = currentIndex else { return }
        // Like the Music app: restart the song unless it has only just begun.
        if currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            load(index: index - 1, from: 0, autoplay: isPlaying || isPreparing)
        }
    }

    func seek(to seconds: TimeInterval) {
        guard let file = dryFile else { return }
        let frame = AVAudioFramePosition(max(0, seconds) * file.processingFormat.sampleRate)
        pausedFrame = min(frame, file.length)
        if isPlaying {
            start(from: pausedFrame)
        } else {
            updateNowPlaying()
        }
    }

    /// Drops a deleted song from the queue, stopping it if it is playing.
    func remove(_ track: Track) {
        renderer.removeCache(for: track)
        guard let removed = queue.firstIndex(where: { $0.id == track.id }) else { return }
        if removed == currentIndex {
            stop()
            queue.remove(at: removed)
            return
        }
        queue.remove(at: removed)
        if let index = currentIndex, removed < index {
            currentIndex = index - 1
        }
    }

    func stop() {
        pause()
        generation += 1
        renderJob?.cancel()
        dryFile = nil
        wetFile = nil
        currentIndex = nil
        pausedFrame = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Loading

    private func load(index: Int, from frame: AVAudioFramePosition, autoplay: Bool) {
        guard queue.indices.contains(index) else { return }
        if autoplay { onWillPlay?() }
        generation += 1
        renderJob?.cancel()
        dryNode.stop()
        wetNode.stop()
        isPlaying = false
        isPreparing = false
        errorMessage = nil
        currentIndex = index
        pausedFrame = frame
        wetFile = nil

        let track = queue[index]
        do {
            dryFile = try AVAudioFile(forReading: track.url)
        } catch {
            dryFile = nil
            errorMessage = "Couldn't open \(track.title)."
            return
        }

        guard hasNotch else {
            if autoplay { start(from: frame) } else { updateNowPlaying() }
            return
        }

        isPreparing = autoplay
        prepareProgress = 0
        let loadGeneration = generation
        renderJob = renderer.render(track, pitches: notchPitches, widthOctaves: notchWidthOctaves, progress: { [weak self] fraction in
            guard let self, self.generation == loadGeneration else { return }
            self.prepareProgress = fraction
        }, completion: { [weak self] result in
            guard let self, self.generation == loadGeneration else { return }
            self.isPreparing = false
            switch result {
            case .success(let url):
                self.wetFile = try? AVAudioFile(forReading: url)
                if self.wetFile == nil {
                    self.errorMessage = "The filtered copy couldn't be opened, so this song plays unfiltered."
                }
            case .failure:
                self.errorMessage = "Filtering failed, so this song plays unfiltered."
            }
            if autoplay { self.start(from: self.pausedFrame) } else { self.updateNowPlaying() }
            self.prefetchNext()
        })
    }

    /// Renders the next song in the background so it starts without a wait.
    private func prefetchNext() {
        guard let index = currentIndex, index + 1 < queue.count, hasNotch else { return }
        prefetchJob = renderer.render(queue[index + 1], pitches: notchPitches, widthOctaves: notchWidthOctaves) { _ in }
    }

    // MARK: Engine

    private func start(from frame: AVAudioFramePosition) {
        guard let dry = dryFile else { return }
        onWillPlay?()
        generation += 1
        let playGeneration = generation
        dryNode.stop()
        wetNode.stop()

        let remaining = dry.length - frame
        guard remaining > 0 else {
            trackDidFinish()
            return
        }
        do {
            try startEngine(format: dry.processingFormat, wetFormat: wetFile?.processingFormat ?? dry.processingFormat)
        } catch {
            errorMessage = "Audio could not start: \(error.localizedDescription)"
            return
        }

        segmentStart = frame
        dryNode.scheduleSegment(dry, startingFrame: frame, frameCount: AVAudioFrameCount(remaining), at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == playGeneration else { return }
                // A stopped engine also fires this callback. Only advance when the song really reached its end.
                let tolerance = AVAudioFramePosition(dry.processingFormat.sampleRate)
                guard self.currentFrame >= dry.length - tolerance else { return }
                self.trackDidFinish()
            }
        }
        if let wet = wetFile, wet.length > frame {
            wetNode.scheduleSegment(wet, startingFrame: frame, frameCount: AVAudioFrameCount(min(remaining, wet.length - frame)), at: nil)
        }

        wetMix = targetWetMix
        applyMix()
        // A shared start time keeps the dry and notched copies sample aligned.
        let startTime = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        dryNode.play(at: startTime)
        if wetFile != nil {
            wetNode.play(at: startTime)
        }
        isPlaying = true
        claimRemoteControls()
        updateNowPlaying()
    }

    private func startEngine(format: AVAudioFormat, wetFormat: AVAudioFormat) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        // Songs can differ in sample rate and channel count, so connect with each song's own format.
        // A mono song with a different notch in each ear has a stereo filtered copy.
        if dryNode.outputFormat(forBus: 0) != format || engine.outputConnectionPoints(for: dryNode, outputBus: 0).isEmpty {
            engine.connect(dryNode, to: engine.mainMixerNode, format: format)
        }
        if wetNode.outputFormat(forBus: 0) != wetFormat || engine.outputConnectionPoints(for: wetNode, outputBus: 0).isEmpty {
            engine.connect(wetNode, to: engine.mainMixerNode, format: wetFormat)
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private var currentFrame: AVAudioFramePosition {
        guard isPlaying,
              let nodeTime = dryNode.lastRenderTime,
              let playerTime = dryNode.playerTime(forNodeTime: nodeTime) else { return pausedFrame }
        let frame = segmentStart + max(playerTime.sampleTime, 0)
        return min(frame, dryFile?.length ?? frame)
    }

    private func trackDidFinish() {
        guard let index = currentIndex else { return }
        if index + 1 < queue.count {
            load(index: index + 1, from: 0, autoplay: true)
        } else {
            stopAtEnd()
        }
    }

    private func stopAtEnd() {
        pause()
        pausedFrame = 0
        updateNowPlaying()
    }

    private func handleConfigurationChange() {
        // The engine stops itself when the output changes. Pick up where we were.
        guard isPlaying else { return }
        let frame = currentFrame
        isPlaying = false
        pausedFrame = frame
        start(from: frame)
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if isPlaying {
                pausedFrame = currentFrame
                generation += 1
                isPlaying = false
                updateNowPlaying()
            }
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            if options.contains(.shouldResume), currentIndex != nil, dryFile != nil {
                start(from: pausedFrame)
            }
        @unknown default:
            break
        }
    }

    // MARK: Filter crossfade

    private var targetWetMix: Float {
        filterEnabled && wetFile != nil ? 1 : 0
    }

    private func applyMix() {
        // The two copies are nearly identical outside the notch, so a linear fade keeps the level steady.
        wetNode.volume = wetMix
        dryNode.volume = 1 - wetMix
    }

    private func crossfade() {
        fadeTimer?.invalidate()
        let target = targetWetMix
        guard isPlaying else {
            wetMix = target
            applyMix()
            return
        }
        let step = Float(1.0 / 60 / Self.crossfadeDuration)
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            if abs(self.wetMix - target) <= step {
                self.wetMix = target
                timer.invalidate()
            } else {
                self.wetMix += self.wetMix < target ? step : -step
            }
            self.applyMix()
        }
    }

    // MARK: Lock screen

    private func claimRemoteControls() {
        RemoteControls.claim(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlayback() },
            next: { [weak self] in self?.next() },
            previous: { [weak self] in self?.previous() },
            seek: { [weak self] in self?.seek(to: $0) }
        )
    }

    private func updateNowPlaying() {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        let notchNote = hasNotch && filterEnabled ? "Tinnitus notch on" : "Tinnitus notch off"
        info[MPMediaItemPropertyArtist] = [track.artist, notchNote].compactMap { $0 }.joined(separator: " · ")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
