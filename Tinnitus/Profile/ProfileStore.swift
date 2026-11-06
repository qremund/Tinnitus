import Foundation
import Observation
import SwiftUI
import TinnitusCore
import UniformTypeIdentifiers

/// Saved matching sessions, newest first, stored as JSON in Application Support.
///
/// A file that can't be read is set aside with a dated name rather than overwritten, and the problem
/// is shown, so a bug or a future format change can never quietly wipe saved matches.
@MainActor
@Observable
final class ProfileStore {
    private(set) var profiles: [TinnitusProfile] = []
    @ObservationIgnored private let fileURL: URL

    /// Set when a saved file couldn't be read at launch. Explains where the original was kept.
    var loadProblem: String?

    /// The matches removed by the last delete, so it can be undone.
    struct RecentDeletion {
        let id = UUID()
        var matches: [(index: Int, match: TinnitusProfile)]
        /// For each profile, the matches it lost and where they were in its list.
        var memberships: [UUID: [(index: Int, id: UUID)]]
        var title: String
    }

    private(set) var recentDeletion: RecentDeletion?

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

    /// Deletes matches and takes them out of every profile. `undoDelete()` puts everything back.
    func delete(at offsets: IndexSet) {
        let removedMatches = offsets.sorted().map { (index: $0, match: profiles[$0]) }
        let removed = Set(removedMatches.map(\.match.id))
        var memberships: [UUID: [(index: Int, id: UUID)]] = [:]
        for profile in matchProfiles {
            let lost = profile.matchIDs.enumerated().filter { removed.contains($0.element) }.map { (index: $0.offset, id: $0.element) }
            if !lost.isEmpty { memberships[profile.id] = lost }
        }
        let title = removedMatches.count == 1 ? Format.matchTitle(removedMatches[0].match) : "\(removedMatches.count) matches"
        recentDeletion = RecentDeletion(matches: removedMatches, memberships: memberships, title: title)

        profiles.remove(atOffsets: offsets)
        for index in matchProfiles.indices {
            matchProfiles[index].matchIDs.removeAll { removed.contains($0) }
        }
        save()
        saveMatchProfiles()
    }

    /// Profiles a delete of these matches would change, for the confirmation.
    func profilesContaining(_ offsets: IndexSet) -> [MatchProfile] {
        let ids = Set(offsets.map { profiles[$0].id })
        return matchProfiles.filter { profile in profile.matchIDs.contains { ids.contains($0) } }
    }

    func undoDelete() {
        guard let deletion = recentDeletion else { return }
        recentDeletion = nil
        for (index, match) in deletion.matches.sorted(by: { $0.index < $1.index }) where !profiles.contains(where: { $0.id == match.id }) {
            profiles.insert(match, at: min(index, profiles.count))
        }
        for (profileID, lost) in deletion.memberships {
            guard let p = matchProfiles.firstIndex(where: { $0.id == profileID }) else { continue }
            for (index, id) in lost.sorted(by: { $0.index < $1.index }) where !matchProfiles[p].matchIDs.contains(id) {
                matchProfiles[p].matchIDs.insert(id, at: min(index, matchProfiles[p].matchIDs.count))
            }
        }
        save()
        saveMatchProfiles()
    }

    func clearRecentDeletion() {
        recentDeletion = nil
    }

    /// Everything saved, for the Export button.
    var export: MatchExport {
        MatchExport(archive: MatchArchive.Export(matches: profiles, profiles: matchProfiles))
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
        profiles = read([TinnitusProfile].self, from: fileURL, what: "saved matches") ?? []
    }

    private func loadMatchProfiles() {
        matchProfiles = read([MatchProfile].self, from: matchProfilesURL, what: "profiles") ?? []
    }

    /// Reads a saved list. A file that exists but can't be read is moved aside so the next save can't
    /// overwrite it, and `loadProblem` says where it went.
    private func read<Item: Codable>(_ type: [Item].Type, from url: URL, what: String) -> [Item]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try MatchArchive.decode(Item.self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            let reason = (error as? MatchArchive.ReadError).map { _ in "It was saved by a newer version of the app." } ?? "The file may be damaged."
            let note = "Your \(what) couldn't be read. \(reason) The original was kept as \(backup.lastPathComponent) in the app's files, and nothing was deleted."
            loadProblem = [loadProblem, note].compactMap { $0 }.joined(separator: "\n\n")
            return nil
        }
    }

    private func saveMatchProfiles() {
        write(matchProfiles, to: matchProfilesURL, what: "profiles")
    }

    private func write<Item: Codable>(_ items: [Item], to url: URL, what: String) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try MatchArchive.encode(items).write(to: url, options: .atomic)
        } catch {
            loadProblem = "Saving your \(what) failed: \(error.localizedDescription)"
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
        write(profiles, to: fileURL, what: "saved matches")
    }
}

/// The Export button's file: every match and profile, as JSON.
struct MatchExport: Transferable {
    let archive: MatchArchive.Export

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { export in
            let day = export.archive.exportedAt.formatted(.iso8601.year().month().day())
            let name = "Tinnitus matches \(day).json"
            let url = FileManager.default.temporaryDirectory.appending(path: name)
            try MatchArchive.encoder().encode(export.archive).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
