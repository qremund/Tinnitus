import Foundation
import Observation
import SwiftUI
import TinnitusCore

/// Saved matching sessions, newest first, stored as JSON in Application Support.
@Observable
final class ProfileStore {
    private(set) var profiles: [TinnitusProfile] = []
    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = URL.applicationSupportDirectory.appending(path: "profiles.json")) {
        self.fileURL = fileURL
        load()
    }

    /// Median of the last three sessions, which is steadier than any single match.
    var current: TinnitusProfile? {
        TinnitusProfile.consensus(of: Array(profiles.prefix(3)))
    }

    func add(_ profile: TinnitusProfile) {
        profiles.insert(profile, at: 0)
        save()
    }

    func delete(at offsets: IndexSet) {
        profiles.remove(atOffsets: offsets)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        profiles = (try? decoder.decode([TinnitusProfile].self, from: data)) ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profiles).write(to: fileURL, options: .atomic)
        } catch {
            print("Saving profiles failed: \(error)")
        }
    }
}
