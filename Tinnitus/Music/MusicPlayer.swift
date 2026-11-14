import AVFoundation
import MediaPlayer
import MediaToolbox
import Observation
import TinnitusCore

/// Plays imported songs through the tinnitus notch, filtering live as they play.
///
/// Each song goes through an audio processing tap, which hands its audio to `LiveNotchProcessor` just
/// before it reaches the speakers. Songs start at once, profile changes and the notch toggle take
/// effect within a fraction of a second, and nothing is stored apart from the songs themselves.
@MainActor
@Observable
final class MusicPlayer {
    private(set) var queue: [Track] = []
    private(set) var currentIndex: Int?
    private(set) var isPlaying = false
    private(set) var errorMessage: String?
    private(set) var hasNotch = false

    var filterEnabled = true {
        didSet {
            pushSettings()
            updateNowPlaying()
        }
    }

    /// Called before playback starts, so other players can stop.
    @ObservationIgnored var onWillPlay: (() -> Void)?

    /// How long after a pause the audio session is released.
    static let releaseDelay: TimeInterval = 0.5

    @ObservationIgnored private let player = AVPlayer()
    /// The current song's notch. Each song gets its own, attached to its audio tap.
    @ObservationIgnored private var processor: LiveNotchProcessor?
    @ObservationIgnored private var settings = LiveNotchProcessor.Settings()
    /// Bumped whenever a new song loads, so a slow load that finishes late is ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var interruptedWhilePlaying = false
    @ObservationIgnored private var release: DispatchWorkItem?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
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
        // Earlier versions kept pre-filtered copies of songs here. They are no longer used.
        Task.detached(priority: .background) {
            try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: "Filtered", directoryHint: .isDirectory))
        }
    }

    var currentTrack: Track? {
        currentIndex.flatMap { queue.indices.contains($0) ? queue[$0] : nil }
    }

    var duration: TimeInterval { currentTrack?.duration ?? 0 }

    /// Playback position in seconds. Not observed, so views poll it with a TimelineView.
    var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(seconds, 0) : 0
    }

    // MARK: Notch

    /// Sets each ear's notches. An ear without a pitch plays unfiltered. Takes effect immediately.
    func setNotch(pitches: EarPitches, widthOctaves: Double) {
        settings.pitches = pitches
        settings.minimumWidthOctaves = widthOctaves
        hasNotch = !pitches.isEmpty
        pushSettings()
    }

    private func pushSettings() {
        settings.enabled = filterEnabled
        processor?.update(settings)
    }

    // MARK: Transport

    func play(_ tracks: [Track], startAt index: Int) {
        guard tracks.indices.contains(index) else { return }
        queue = tracks
        load(index: index, autoplay: true)
    }

    func play() {
        guard let index = currentIndex else { return }
        if player.currentItem == nil {
            load(index: index, autoplay: true)
        } else {
            start()
        }
    }

    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        updateNowPlaying()
        scheduleRelease()
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func next() {
        guard let index = currentIndex else { return }
        if index + 1 < queue.count {
            load(index: index + 1, autoplay: isPlaying)
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
            load(index: index - 1, autoplay: isPlaying)
        }
    }

    func seek(to seconds: TimeInterval) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.updateNowPlaying() }
            }
        }
    }

    /// Drops a deleted song from the queue, stopping it if it is playing.
    func remove(_ track: Track) {
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
        player.replaceCurrentItem(with: nil)
        processor = nil
        currentIndex = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        AudioSessionCoordinator.deactivate(.music)
    }

    // MARK: Loading

    private func load(index: Int, autoplay: Bool) {
        guard queue.indices.contains(index) else { return }
        if autoplay { onWillPlay?() }
        generation += 1
        let loadGeneration = generation
        player.pause()
        isPlaying = false
        errorMessage = nil
        currentIndex = index

        let track = queue[index]
        let asset = AVURLAsset(url: track.url)
        let item = AVPlayerItem(asset: asset)
        let processor = LiveNotchProcessor(settings: settings)
        self.processor = processor

        Task {
            let audioTrack: AVAssetTrack?
            do {
                audioTrack = try await asset.loadTracks(withMediaType: .audio).first
            } catch {
                guard self.generation == loadGeneration else { return }
                self.errorMessage = "Couldn't open \(track.title)."
                return
            }
            guard self.generation == loadGeneration else { return }
            if let audioTrack, let mix = Self.makeAudioMix(track: audioTrack, processor: processor) {
                item.audioMix = mix
            } else {
                self.errorMessage = "The notch couldn't be attached, so this song plays unfiltered."
            }
            self.player.replaceCurrentItem(with: item)
            self.observeEnd(of: item)
            if autoplay { self.start() } else { self.updateNowPlaying() }
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackDidFinish() }
        }
    }

    private func start() {
        guard player.currentItem != nil else { return }
        onWillPlay?()
        release?.cancel()
        release = nil
        do {
            try AudioSessionCoordinator.activate(.music)
        } catch {
            errorMessage = "Audio could not start: \(error.localizedDescription)"
            return
        }
        player.play()
        isPlaying = true
        claimRemoteControls()
        updateNowPlaying()
    }

    private func trackDidFinish() {
        guard let index = currentIndex else { return }
        if index + 1 < queue.count {
            load(index: index + 1, autoplay: true)
        } else {
            stopAtEnd()
        }
    }

    private func stopAtEnd() {
        pause()
        seek(to: 0)
    }

    /// Releases the audio session once playback has stayed paused, so other apps can resume.
    private func scheduleRelease() {
        release?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isPlaying else { return }
                AudioSessionCoordinator.deactivate(.music)
            }
        }
        release = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseDelay, execute: work)
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            interruptedWhilePlaying = isPlaying
            guard isPlaying else { return }
            // The system has already paused the player.
            isPlaying = false
            updateNowPlaying()
        case .ended:
            if interruptedWhilePlaying && options.contains(.shouldResume) {
                start()
            }
            interruptedWhilePlaying = false
        default:
            break
        }
    }

    // MARK: Audio tap

    /// An audio mix that sends the song through `processor`. Nil if the tap couldn't be made.
    private nonisolated static func makeAudioMix(track: AVAssetTrack, processor: LiveNotchProcessor) -> AVAudioMix? {
        let context = TapContext(processor: processor)
        let clientInfo = Unmanaged.passRetained(context).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: clientInfo,
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
            },
            unprepare: { tap in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().unprepare()
            },
            process: { tap, frameCount, _, bufferList, frameCountOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frameCount, bufferList, flagsOut, nil, frameCountOut) == noErr else { return }
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .process(bufferList, frameCount: Int(frameCountOut.pointee))
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged<TapContext>.fromOpaque(clientInfo).release()
            return nil
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
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

/// What the audio tap's callbacks need. They run on the player's own threads, never the main one.
private final class TapContext: @unchecked Sendable {
    let processor: LiveNotchProcessor
    private var isUsable = false
    private var isInterleaved = false
    private var channelCount = 0

    init(processor: LiveNotchProcessor) {
        self.processor = processor
    }

    func prepare(_ format: AudioStreamBasicDescription) {
        // The tap normally delivers 32-bit float. Anything else passes through unfiltered.
        isUsable = format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
            && format.mChannelsPerFrame > 0
        isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        channelCount = Int(format.mChannelsPerFrame)
        if isUsable {
            processor.prepare(sampleRate: format.mSampleRate, channelCount: channelCount)
        }
    }

    func unprepare() {
        isUsable = false
        processor.unprepare()
    }

    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard isUsable, frameCount > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        processor.beginBlock()
        if isInterleaved {
            if buffers.count > 0, let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                for channel in 0..<channelCount {
                    processor.process(data + channel, frameCount: frameCount, channel: channel, stride: channelCount)
                }
            }
        } else {
            for channel in 0..<min(buffers.count, channelCount) {
                if let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) {
                    processor.process(data, frameCount: frameCount, channel: channel)
                }
            }
        }
        processor.endBlock(frameCount: frameCount)
    }
}
