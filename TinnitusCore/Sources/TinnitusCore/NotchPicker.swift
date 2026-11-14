import Foundation

/// Which notch a tap on a notch diagram selects. Notches can overlap, so a tap that lands on several
/// steps through them, one per tap.
public enum NotchPicker {
    public struct Notch<ID: Hashable>: Equatable {
        public var id: ID
        public var lowHz: Double
        public var highHz: Double

        public init(id: ID, lowHz: Double, highHz: Double) {
            self.id = id
            self.lowHz = lowHz
            self.highHz = highHz
        }

        var centerPosition: Double { (NotchScale.position(lowHz) + NotchScale.position(highHz)) / 2 }
    }

    /// The notches under a tap at `position` (0 at 250 Hz, 1 at 16 kHz), lowest pitch first. Each
    /// notch counts as at least `minimumSpan` wide, so a narrow one is still easy to hit.
    public static func hits<ID>(at position: Double, in notches: [Notch<ID>], minimumSpan: Double) -> [ID] {
        notches
            .filter { notch in
                let low = NotchScale.position(notch.lowHz)
                let high = NotchScale.position(notch.highHz)
                let pad = max(0, minimumSpan - (high - low)) / 2
                return position >= low - pad && position <= high + pad
            }
            .sorted { $0.centerPosition < $1.centerPosition }
            .map(\.id)
    }

    /// The one a tap selects: the next after the current selection when that is under the tap too,
    /// otherwise the first.
    public static func pick<ID: Equatable>(_ hits: [ID], current: ID?) -> ID? {
        guard !hits.isEmpty else { return nil }
        guard let current, let index = hits.firstIndex(of: current) else { return hits[0] }
        return hits[(index + 1) % hits.count]
    }
}
