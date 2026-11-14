import AVFoundation
import Observation
import os
import TinnitusCore

/// Plays test tones and narrowband noise through AVAudioEngine for the matching screens.
/// The engine runs only while a sound plays, and shuts down shortly after it stops.
@MainActor
@Observable
final class TestToneEngine {
    private(set) var headphonesConnected = false
    private(set) var errorMessage: String?
    /// The phone's volume, 0 to 1. Test sound levels are relative to it.
    private(set) var outputVolume = Double(AVAudioSession.sharedInstance().outputVolume)

    /// Above this phone volume, test sounds near the loudness cap can get uncomfortably loud.
    static let comfortableVolume = 0.75
    /// How long after a stop the engine shuts down: long enough for the 20 ms fade.
    static let shutdownDelay: TimeInterval = 0.3

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var sourceNode: AVAudioSourceNode?
    @ObservationIgnored private var renderState: RenderState?
    @ObservationIgnored private var parameters = TestSoundParameters()
    /// Other sounds played quietly alongside the main one, such as a profile's other matches.
    @ObservationIgnored private var companions: [TestSoundParameters] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var volumeObservation: NSKeyValueObservation?
    @ObservationIgnored private var shutdown: DispatchWorkItem?

    init() {
        refreshRoute()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                self?.handleRouteChange(reason: reason)
            }
        })
        // The engine stops itself when the output device changes, for example when earbuds connect.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuild()
            }
        })
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            let volume = Double(session.outputVolume)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.outputVolume = volume
                }
            }
        }
    }

    /// Reads the phone's volume again. iOS reports changes only while the audio session is active.
    func refreshVolume() {
        outputVolume = Double(AVAudioSession.sharedInstance().outputVolume)
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
        shutdown?.cancel()
        shutdown = nil
        submit(p)
        prepare()
    }

    func stop() {
        var p = parameters
        p.isPlaying = false
        companions = []
        submit(p)
        guard renderState != nil else { return }
        shutdown?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.parameters.isPlaying else { return }
                self.tearDown()
            }
        }
        shutdown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shutdownDelay, execute: work)
    }

    private func prepare() {
        guard renderState == nil else { return }
        do {
            try AudioSessionCoordinator.activate(.tones)
            refreshVolume()

            let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate > 0
                ? engine.outputNode.outputFormat(forBus: 0).sampleRate
                : 48_000
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
            let state = RenderState(sampleRate: sampleRate, configurations: configurations(sampleRate: sampleRate))
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
        refreshRoute()
    }

    /// Built outside the main actor, so the render block carries no main-actor isolation onto the audio thread.
    private nonisolated static func makeSourceNode(format: AVAudioFormat, state: RenderState) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            state.render(left: left, right: right, frameCount: Int(frameCount))
            return noErr
        }
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
        AudioSessionCoordinator.deactivate(.tones)
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
        let wasPlaying = parameters.isPlaying
        tearDown()
        if wasPlaying { prepare() }
    }

    private func refreshRoute() {
        let headphonePorts: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .usbAudio]
        headphonesConnected = AVAudioSession.sharedInstance().currentRoute.outputs.contains { headphonePorts.contains($0.portType) }
    }

    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason?) {
        refreshRoute()
        if reason == .oldDeviceUnavailable {
            // Headphones were unplugged: never let a test sound move to the speaker.
            stop()
        }
    }
}

/// Owns the synths on the audio thread: the main test sound and a few companions mixed in with it.
/// New settings arrive through a mailbox the audio thread never waits on, and old settings are
/// released back on the main thread.
private final class RenderState: @unchecked Sendable {
    static let maxCompanions = 4
    /// Companions render into these, then get added to the output.
    private static let scratchFrames = 4096

    let sampleRate: Double
    private let synths: [ToneSynth]
    private let mailbox = RealtimeMailbox<[ToneSynth.Configuration]>()
    /// Audio thread only: the settings being swapped in or out.
    private var incoming: [ToneSynth.Configuration]
    private let scratchLeft = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames)
    private let scratchRight = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames)

    init(sampleRate: Double, configurations: [ToneSynth.Configuration]) {
        self.sampleRate = sampleRate
        synths = configurations.prefix(1 + Self.maxCompanions).map { ToneSynth(sampleRate: sampleRate, configuration: $0) }
        incoming = Array(configurations.prefix(1 + Self.maxCompanions))
    }

    deinit {
        scratchLeft.deallocate()
        scratchRight.deallocate()
    }

    func submit(_ configurations: [ToneSynth.Configuration]) {
        mailbox.post(configurations)
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frameCount: Int) {
        if mailbox.exchange(&incoming) {
            // Each synth swaps its old settings into `incoming`, which goes back to the main thread
            // at the next exchange. The array is uniquely held here, so this never copies.
            for index in 0..<min(synths.count, incoming.count) {
                synths[index].apply(&incoming[index])
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
