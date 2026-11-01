import AVFoundation
import Observation
import os
import TinnitusCore

/// Plays test tones and narrowband noise through AVAudioEngine for the matching screens.
@Observable
final class TestToneEngine {
    private(set) var headphonesConnected = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var sourceNode: AVAudioSourceNode?
    @ObservationIgnored private var renderState: RenderState?
    @ObservationIgnored private var parameters = TestSoundParameters()
    /// Other sounds played quietly alongside the main one, such as a profile's other matches.
    @ObservationIgnored private var companions: [TestSoundParameters] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        refreshRoute()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleRouteChange(note)
        })
        // The engine stops itself when the output device changes, for example when earbuds connect.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.rebuild()
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Plays the test sound, plus up to `RenderState.maxCompanions` other sounds mixed in with it.
    func play(_ newParameters: TestSoundParameters, companions newCompanions: [TestSoundParameters] = []) {
        var p = newParameters
        p.isPlaying = true
        companions = Array(newCompanions.prefix(RenderState.maxCompanions)).map {
            var c = $0
            c.isPlaying = true
            return c
        }
        submit(p)
        prepare()
    }

    func stop() {
        var p = parameters
        p.isPlaying = false
        companions = []
        submit(p)
    }

    func prepare() {
        guard renderState == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate > 0
                ? engine.outputNode.outputFormat(forBus: 0).sampleRate
                : 48_000
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
            let state = RenderState(sampleRate: sampleRate, configurations: configurations(sampleRate: sampleRate))
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
        refreshRoute()
    }

    private func submit(_ p: TestSoundParameters) {
        parameters = p
        guard let state = renderState else { return }
        state.submit(configurations(sampleRate: state.sampleRate))
    }

    /// The main sound first, then one per companion slot. Unused slots are stopped so they fade out.
    private func configurations(sampleRate: Double) -> [ToneSynth.Configuration] {
        var all = [ToneSynth.configuration(for: parameters, sampleRate: sampleRate)]
        for index in 0..<RenderState.maxCompanions {
            var c = index < companions.count ? companions[index] : TestSoundParameters()
            if !parameters.isPlaying { c.isPlaying = false }
            all.append(ToneSynth.configuration(for: c, sampleRate: sampleRate))
        }
        return all
    }

    private func rebuild() {
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
        }
        sourceNode = nil
        renderState = nil
        prepare()
    }

    private func refreshRoute() {
        let headphonePorts: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .usbAudio]
        headphonesConnected = AVAudioSession.sharedInstance().currentRoute.outputs.contains { headphonePorts.contains($0.portType) }
    }

    private func handleRouteChange(_ note: Notification) {
        refreshRoute()
        if let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
           AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable {
            // Headphones were unplugged: never let a test sound move to the speaker.
            stop()
        }
    }
}

/// Owns the synths on the audio thread: the main test sound and a few companions mixed in with it.
/// New settings arrive through a lock the audio thread never waits on.
private final class RenderState {
    static let maxCompanions = 4
    /// Companions render into these, then get added to the output.
    private static let scratchFrames = 4096

    let sampleRate: Double
    private let synths: [ToneSynth]
    private let pending = OSAllocatedUnfairLock<[ToneSynth.Configuration]?>(initialState: nil)
    private let scratchLeft = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames)
    private let scratchRight = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames)

    init(sampleRate: Double, configurations: [ToneSynth.Configuration]) {
        self.sampleRate = sampleRate
        synths = configurations.prefix(1 + Self.maxCompanions).map { ToneSynth(sampleRate: sampleRate, configuration: $0) }
    }

    deinit {
        scratchLeft.deallocate()
        scratchRight.deallocate()
    }

    func submit(_ configurations: [ToneSynth.Configuration]) {
        pending.withLock { $0 = configurations }
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frameCount: Int) {
        let next = pending.withLockIfAvailable { state -> [ToneSynth.Configuration]? in
            defer { state = nil }
            return state
        }
        if let next, let configurations = next {
            for (synth, configuration) in zip(synths, configurations) {
                synth.apply(configuration)
            }
        }
        guard let main = synths.first else { return }
        main.render(left: left, right: right, frameCount: frameCount)
        for synth in synths.dropFirst() where !synth.isSilent {
            var offset = 0
            while offset < frameCount {
                let count = min(frameCount - offset, Self.scratchFrames)
                synth.render(left: scratchLeft, right: scratchRight, frameCount: count)
                for i in 0..<count {
                    left[offset + i] = min(max(left[offset + i] + scratchLeft[i], -1), 1)
                    if let right {
                        right[offset + i] = min(max(right[offset + i] + scratchRight[i], -1), 1)
                    }
                }
                offset += count
            }
        }
    }
}
