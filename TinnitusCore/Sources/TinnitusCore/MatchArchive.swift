import Foundation

/// The saved-file format for matches and profiles: a version number around the list, so a future
/// version of the app can tell an old file from a new one instead of failing to read it.
public enum MatchArchive {
    public static let currentVersion = 1

    public enum ReadError: Error, Equatable {
        /// The file was written by a newer version of the app.
        case newerVersion(Int)
    }

    private struct Envelope<Item: Codable>: Codable {
        var version: Int
        var items: [Item]
    }

    private struct VersionOnly: Decodable {
        var version: Int
    }

    /// Everything saved, in one file, for backing up.
    public struct Export: Codable, Equatable, Sendable {
        public var version: Int
        public var exportedAt: Date
        public var matches: [TinnitusProfile]
        public var profiles: [MatchProfile]

        public init(matches: [TinnitusProfile], profiles: [MatchProfile], exportedAt: Date = Date()) {
            version = MatchArchive.currentVersion
            self.exportedAt = exportedAt
            self.matches = matches
            self.profiles = profiles
        }
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode<Item: Codable>(_ items: [Item]) throws -> Data {
        try encoder().encode(Envelope(version: currentVersion, items: items))
    }

    /// Reads a versioned file, or the bare list that earlier versions of the app wrote.
    /// Throws rather than returning an empty list, so a file that can't be read is never overwritten.
    public static func decode<Item: Codable>(_ type: Item.Type, from data: Data) throws -> [Item] {
        let decoder = decoder()
        if let envelope = try? decoder.decode(Envelope<Item>.self, from: data) {
            guard envelope.version <= currentVersion else { throw ReadError.newerVersion(envelope.version) }
            return envelope.items
        }
        if let header = try? decoder.decode(VersionOnly.self, from: data), header.version > currentVersion {
            throw ReadError.newerVersion(header.version)
        }
        return try decoder.decode([Item].self, from: data)
    }
}
