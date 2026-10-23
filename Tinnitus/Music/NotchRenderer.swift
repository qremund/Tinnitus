import AVFoundation
import os
import TinnitusCore

/// Renders songs through the notch ahead of playback and keeps the results in Caches.
/// Rendering a few minutes of audio takes seconds, and playing the copy needs no work on the audio thread.
final class NotchRenderer {
    /// Lets the player abandon a render it no longer needs.
    final class Job {
        private let cancelled = OSAllocatedUnfairLock(initialState: false)
        var isCancelled: Bool { cancelled.withLock { $0 } }
        func cancel() { cancelled.withLock { $0 = true } }
    }

    /// Filtered copies kept on disk. Older ones are deleted.
    static let maxCachedFiles = 10
    private static let chunkFrames: AVAudioFrameCount = 32_768

    private let queue = DispatchQueue(label: "NotchRenderer", qos: .userInitiated)

    init() {
        try? FileManager.default.createDirectory(at: MusicFiles.cacheFolder, withIntermediateDirectories: true)
    }

    func cachedURL(for track: Track, centerHz: Double, widthOctaves: Double) -> URL {
        let name = "\(track.id.uuidString)-\(Int(centerHz.rounded()))-\(Int((widthOctaves * 100).rounded())).caf"
        return MusicFiles.cacheFolder.appending(path: name)
    }

    /// Produces the notched copy of `track`, or reuses it. Progress and completion arrive on the main queue.
    @discardableResult
    func render(
        _ track: Track,
        centerHz: Double,
        widthOctaves: Double,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) -> Job {
        let job = Job()
        let source = track.url
        let destination = cachedURL(for: track, centerHz: centerHz, widthOctaves: widthOctaves)
        queue.async {
            let result = Result {
                if FileManager.default.fileExists(atPath: destination.path) {
                    // Mark as recently used so pruning keeps it.
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
                } else {
                    try Self.renderFile(source: source, destination: destination, centerHz: centerHz, widthOctaves: widthOctaves, job: job, progress: progress)
                    Self.prune()
                }
                return destination
            }
            DispatchQueue.main.async { completion(result) }
        }
        return job
    }

    /// Deletes every filtered copy of a song, for when it is removed from the library.
    func removeCache(for track: Track) {
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: MusicFiles.cacheFolder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix(track.id.uuidString) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func renderFile(
        source: URL,
        destination: URL,
        centerHz: Double,
        widthOctaves: Double,
        job: Job,
        progress: ((Double) -> Void)?
    ) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let channelCount = Int(format.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw CocoaError(.fileReadUnknown)
        }

        // Apple Lossless at 16 bits keeps the copy about half the size of the PCM, with no added artifacts.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitDepthHintKey: 16,
        ]
        let partial = destination.deletingPathExtension().appendingPathExtension("partial.caf")
        try? FileManager.default.removeItem(at: partial)

        var processor = NotchProcessor.forTinnitus(
            centerHz: centerHz,
            widthOctaves: widthOctaves,
            sampleRate: format.sampleRate,
            channelCount: channelCount
        )
        let total = Double(max(input.length, 1))
        var lastReported = 0.0

        do {
            // Scoped so the output file is closed before it is moved into place.
            let output = try AVAudioFile(forWriting: partial, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            while input.framePosition < input.length {
                if job.isCancelled { throw CancellationError() }
                try input.read(into: buffer, frameCount: chunkFrames)
                let frames = Int(buffer.frameLength)
                guard frames > 0, let channels = buffer.floatChannelData else { break }
                for channel in 0..<channelCount {
                    processor.process(channels[channel], frameCount: frames, channel: channel)
                }
                try output.write(from: buffer)

                let fraction = Double(input.framePosition) / total
                if let progress, fraction - lastReported >= 0.02 {
                    lastReported = fraction
                    DispatchQueue.main.async { progress(fraction) }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    private static func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: MusicFiles.cacheFolder, includingPropertiesForKeys: keys)) ?? []
        let dated = files
            .filter { $0.pathExtension == "caf" && !$0.lastPathComponent.contains(".partial") }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        for (file, _) in dated.dropFirst(maxCachedFiles) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
