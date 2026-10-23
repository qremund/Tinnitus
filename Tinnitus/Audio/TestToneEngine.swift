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

    func play(_ newParameters: TestSoundParameters) {
        var p = newParameters
        p.isPlaying = true
        submit(p)
        prepare()
    }

    func stop() {
        var p = parameters
        p.isPlaying = false
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
            let state = RenderState(synth: ToneSynth(
                sampleRate: sampleRate,
                configuration: ToneSynth.configuration(for: parameters, sampleRate: sampleRate)
            ))
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
        state.submit(ToneSynth.configuration(for: p, sampleRate: state.synth.sampleRate))
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

/// Owns the synth on the audio thread. New settings arrive through a lock the audio thread never waits on.
private final class RenderState {
    let synth: ToneSynth
    private let pending = OSAllocatedUnfairLock<ToneSynth.Configuration?>(initialState: nil)

    init(synth: ToneSynth) {
        self.synth = synth
    }

    func submit(_ configuration: ToneSynth.Configuration) {
        pending.withLock { $0 = configuration }
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frameCount: Int) {
        let next = pending.withLockIfAvailable { state -> ToneSynth.Configuration? in
            defer { state = nil }
            return state
        }
        if let next, let configuration = next {
            synth.apply(configuration)
        }
        synth.render(left: left, right: right, frameCount: frameCount)
    }
}
