import AVFoundation
import MediaPlayer
import Observation

/// Where imported songs and their notched copies live.
enum MusicFiles {
    static let folder = URL.documentsDirectory.appending(path: "Music", directoryHint: .isDirectory)
    static let indexURL = folder.appending(path: "library.json")
}

/// A song copied into the app, so it can be decoded and filtered.
struct Track: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var artist: String?
    let fileName: String
    var duration: TimeInterval

    var url: URL { MusicFiles.folder.appending(path: fileName) }
}

/// The user's imported, DRM-free songs. Apple Music downloads are copy protected and cannot be imported.
@MainActor
@Observable
final class MusicLibrary {
    private(set) var tracks: [Track] = []
    private(set) var isImporting = false

    init() {
        try? FileManager.default.createDirectory(at: MusicFiles.folder, withIntermediateDirectories: true)
        load()
    }

    /// Copies audio files picked in the Files app, off the main thread so large files don't freeze the
    /// screen. Returns a message about anything that was skipped.
    func importFiles(_ urls: [URL]) async -> String? {
        isImporting = true
        defer { isImporting = false }
        var failed: [String] = []
        for url in urls {
            let id = UUID()
            let fileName = "\(id.uuidString).\(url.pathExtension.isEmpty ? "audio" : url.pathExtension.lowercased())"
            let copied = await Task.detached(priority: .userInitiated) { () -> TimeInterval? in
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let destination = MusicFiles.folder.appending(path: fileName)
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    return try Self.playableDuration(of: destination)
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    return nil
                }
            }.value
            if let duration = copied {
                tracks.append(Track(id: id, title: url.deletingPathExtension().lastPathComponent, artist: nil, fileName: fileName, duration: duration))
                save()
            } else {
                failed.append(url.lastPathComponent)
            }
        }
        guard !failed.isEmpty else { return nil }
        return "Couldn't import \(failed.joined(separator: ", ")). The file may be copy protected or in a format iPhone can't decode."
    }

    /// Exports songs picked from the Music app's library. Protected and cloud-only songs are skipped.
    func importMediaItems(_ items: [MPMediaItem]) async -> String? {
        isImporting = true
        defer { isImporting = false }
        var skipped: [String] = []
        for item in items {
            let title = item.title ?? "Untitled"
            guard let assetURL = item.assetURL, !item.hasProtectedAsset else {
                skipped.append(title)
                continue
            }
            let id = UUID()
            let fileName = "\(id.uuidString).m4a"
            let destination = MusicFiles.folder.appending(path: fileName)
            // Copy the song as it is when possible, which keeps its quality. Re-encode only if needed.
            var duration: TimeInterval?
            for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] where duration == nil {
                try? FileManager.default.removeItem(at: destination)
                guard let export = AVAssetExportSession(asset: AVURLAsset(url: assetURL), presetName: preset) else { continue }
                export.outputURL = destination
                export.outputFileType = .m4a
                await export.export()
                if export.status == .completed {
                    duration = await Task.detached { try? Self.playableDuration(of: destination) }.value
                }
            }
            guard let duration else {
                try? FileManager.default.removeItem(at: destination)
                skipped.append(title)
                continue
            }
            tracks.append(Track(id: id, title: title, artist: item.artist, fileName: fileName, duration: duration))
            save()
        }
        guard !skipped.isEmpty else { return nil }
        return "Skipped \(skipped.joined(separator: ", ")). Apple Music songs are copy protected, and songs must be downloaded to this iPhone."
    }

    func delete(_ track: Track) {
        try? FileManager.default.removeItem(at: track.url)
        tracks.removeAll { $0.id == track.id }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        tracks.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Opening the file with AVAudioFile proves we can decode it, which also rules out DRM.
    private nonisolated static func playableDuration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard file.length > 0, rate > 0 else { throw CocoaError(.fileReadCorruptFile) }
        return Double(file.length) / rate
    }

    private func load() {
        guard let data = try? Data(contentsOf: MusicFiles.indexURL),
              let saved = try? JSONDecoder().decode([Track].self, from: data) else { return }
        tracks = saved.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: MusicFiles.indexURL, options: .atomic)
    }
}
