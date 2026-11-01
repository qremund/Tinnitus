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

    /// Use one notch for both ears, from the newest matches of any ear.
    var sameForBothEars = UserDefaults.standard.bool(forKey: "sameNotchBothEars") {
        didSet { UserDefaults.standard.set(sameForBothEars, forKey: "sameNotchBothEars") }
    }

    /// A saved match picked for each ear in Play or Music. Nil means automatic: the recent median.
    var leftChoice = UserDefaults.standard.string(forKey: "leftMatchChoice").flatMap(UUID.init(uuidString:)) {
        didSet { UserDefaults.standard.set(leftChoice?.uuidString, forKey: "leftMatchChoice") }
    }
    var rightChoice = UserDefaults.standard.string(forKey: "rightMatchChoice").flatMap(UUID.init(uuidString:)) {
        didSet { UserDefaults.standard.set(rightChoice?.uuidString, forKey: "rightMatchChoice") }
    }

    /// Each ear's profile: the chosen match, or else the median of its last three applicable sessions,
    /// which is steadier than any single match.
    var ears: EarProfiles {
        EarProfiles.resolve(profiles, sameForBothEars: sameForBothEars, leftChoice: leftChoice, rightChoice: rightChoice)
    }

    /// The recent medians, ignoring any chosen match.
    var automaticEars: EarProfiles {
        EarProfiles.from(profiles, sameForBothEars: sameForBothEars)
    }

    /// Uses a saved match for an ear, or both ears. Pass nil to go back to automatic.
    func choose(_ id: UUID?, for ear: Ear) {
        switch ear {
        case .left: leftChoice = id
        case .right: rightChoice = id
        case .both:
            leftChoice = id
            rightChoice = id
        }
    }

    func add(_ profile: TinnitusProfile) {
        profiles.insert(profile, at: 0)
        save()
    }

    func delete(at offsets: IndexSet) {
        let removed = Set(offsets.map { profiles[$0].id })
        profiles.remove(atOffsets: offsets)
        if let id = leftChoice, removed.contains(id) { leftChoice = nil }
        if let id = rightChoice, removed.contains(id) { rightChoice = nil }
        save()
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[index].name = trimmed.isEmpty ? nil : trimmed
        save()
    }

    /// A default name for the next saved match.
    var nextMatchName: String { "Match \(profiles.count + 1)" }

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
