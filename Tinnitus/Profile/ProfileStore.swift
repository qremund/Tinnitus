import Foundation
import Observation
import SwiftUI
import TinnitusCore

/// Saved matching sessions, newest first, stored as JSON in Application Support.
@Observable
final class ProfileStore {
    private(set) var profiles: [TinnitusProfile] = []
    @ObservationIgnored private let fileURL: URL

    @ObservationIgnored private let matchProfilesURL: URL

    init(fileURL: URL = URL.applicationSupportDirectory.appending(path: "profiles.json")) {
        self.fileURL = fileURL
        matchProfilesURL = fileURL.deletingLastPathComponent().appending(path: "matchProfiles.json")
        load()
        loadMatchProfiles()
        migrateEarChoices()
    }

    /// Use one notch for both ears, from the newest matches of any ear.
    var sameForBothEars = UserDefaults.standard.bool(forKey: "sameNotchBothEars") {
        didSet { UserDefaults.standard.set(sameForBothEars, forKey: "sameNotchBothEars") }
    }

    /// Named sets of matches. Play, Music, and the match screens all use the active one.
    private(set) var matchProfiles: [MatchProfile] = []

    /// The profile Play and Music use. Nil means automatic: the median of recent matches.
    var activeProfileID = UserDefaults.standard.string(forKey: "activeMatchProfile").flatMap(UUID.init(uuidString:)) {
        didSet { UserDefaults.standard.set(activeProfileID?.uuidString, forKey: "activeMatchProfile") }
    }

    var activeProfile: MatchProfile? {
        activeProfileID.flatMap { id in matchProfiles.first { $0.id == id } }
    }

    /// Each ear's notches: every match in the active profile, or with no profile the median of that
    /// ear's last three matches, which is steadier than any single match.
    var ears: EarProfiles {
        if let profile = activeProfile {
            return ears(for: profile)
        }
        return automaticEars
    }

    /// The recent medians, ignoring any profile.
    var automaticEars: EarProfiles {
        EarProfiles.from(profiles, sameForBothEars: sameForBothEars)
    }

    /// A profile's matches in the order they were added. Matches that were deleted are skipped.
    func matches(in profile: MatchProfile) -> [TinnitusProfile] {
        profile.matchIDs.compactMap { id in profiles.first { $0.id == id } }
    }

    func ears(for profile: MatchProfile) -> EarProfiles {
        EarProfiles.combining(matches(in: profile), sameForBothEars: sameForBothEars)
    }

    /// Why a match can't be added to a profile, or nil if it can.
    func reasonCannotAdd(_ match: TinnitusProfile, to profile: MatchProfile) -> String? {
        guard !profile.contains(match.id) else { return nil }
        var candidate = profile
        candidate.matchIDs.append(match.id)
        let ears = ears(for: candidate)
        let limit = NotchDesign.maxNotchesPerEar
        let leftFull = ears.left.count > limit
        let rightFull = ears.right.count > limit
        guard leftFull || rightFull else { return nil }
        let side = leftFull && rightFull ? "each ear" : leftFull ? "your left ear" : "your right ear"
        return "\(profile.name) already has \(limit) matches for \(side). Take one out first."
    }

    @discardableResult
    func createProfile(named name: String, matchIDs: [UUID] = [], activate: Bool = true) -> MatchProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = MatchProfile(name: trimmed.isEmpty ? nextProfileName : trimmed, matchIDs: matchIDs)
        matchProfiles.append(profile)
        if activate { activeProfileID = profile.id }
        saveMatchProfiles()
        return profile
    }

    func renameProfile(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = matchProfiles.firstIndex(where: { $0.id == id }) else { return }
        matchProfiles[index].name = trimmed
        saveMatchProfiles()
    }

    /// Deletes the profile only. Its matches stay saved.
    func deleteProfile(_ id: UUID) {
        matchProfiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = nil }
        saveMatchProfiles()
    }

    /// Adds a saved match to a profile. Returns why it couldn't, if it couldn't.
    @discardableResult
    func load(_ matchID: UUID, into profileID: UUID) -> String? {
        guard let index = matchProfiles.firstIndex(where: { $0.id == profileID }),
              let match = profiles.first(where: { $0.id == matchID }) else { return nil }
        if let reason = reasonCannotAdd(match, to: matchProfiles[index]) { return reason }
        guard !matchProfiles[index].contains(matchID) else { return nil }
        matchProfiles[index].matchIDs.append(matchID)
        saveMatchProfiles()
        return nil
    }

    /// Takes a match out of a profile without deleting the match.
    func unload(_ matchID: UUID, from profileID: UUID) {
        guard let index = matchProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        matchProfiles[index].matchIDs.removeAll { $0 == matchID }
        saveMatchProfiles()
    }

    /// A default name for the next profile.
    var nextProfileName: String {
        var n = matchProfiles.count + 1
        while matchProfiles.contains(where: { $0.name == "Profile \(n)" }) { n += 1 }
        return "Profile \(n)"
    }

    func add(_ profile: TinnitusProfile) {
        profiles.insert(profile, at: 0)
        save()
    }

    func delete(at offsets: IndexSet) {
        let removed = Set(offsets.map { profiles[$0].id })
        profiles.remove(atOffsets: offsets)
        for index in matchProfiles.indices {
            matchProfiles[index].matchIDs.removeAll { removed.contains($0) }
        }
        save()
        saveMatchProfiles()
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

    private func loadMatchProfiles() {
        guard let data = try? Data(contentsOf: matchProfilesURL) else { return }
        matchProfiles = (try? JSONDecoder().decode([MatchProfile].self, from: data)) ?? []
    }

    private func saveMatchProfiles() {
        do {
            try FileManager.default.createDirectory(at: matchProfilesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(matchProfiles).write(to: matchProfilesURL, options: .atomic)
        } catch {
            print("Saving match profiles failed: \(error)")
        }
    }

    /// Earlier versions picked one match per ear. Those picks become a profile so nothing changes.
    private func migrateEarChoices() {
        let defaults = UserDefaults.standard
        let picks = ["leftMatchChoice", "rightMatchChoice"].compactMap {
            defaults.string(forKey: $0).flatMap(UUID.init(uuidString:))
        }
        guard defaults.object(forKey: "leftMatchChoice") != nil || defaults.object(forKey: "rightMatchChoice") != nil else { return }
        defaults.removeObject(forKey: "leftMatchChoice")
        defaults.removeObject(forKey: "rightMatchChoice")
        var ids: [UUID] = []
        for id in picks where !ids.contains(id) && profiles.contains(where: { $0.id == id }) {
            ids.append(id)
        }
        guard !ids.isEmpty else { return }
        createProfile(named: "My profile", matchIDs: ids)
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
