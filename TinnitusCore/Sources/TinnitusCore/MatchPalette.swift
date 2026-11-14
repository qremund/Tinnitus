import Foundation

/// An sRGB color as 0...1 components, so the palette can be tested without SwiftUI.
public struct RGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From hue (degrees), saturation and lightness (0...1).
    public init(hue: Double, saturation: Double, lightness: Double) {
        let a = saturation * min(lightness, 1 - lightness)
        func channel(_ n: Double) -> Double {
            let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
            return lightness - a * max(-1, min(k - 3, 9 - k, 1))
        }
        self.init(red: channel(0), green: channel(8), blue: channel(4))
    }

    public init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public static let white = RGB(red: 1, green: 1, blue: 1)
    public static let nearBlack = RGB(hex: 0x111111)

    /// White or near-black, whichever reads better on this color.
    public var readableText: RGB {
        contrast(with: .white) >= contrast(with: .nearBlack) ? .white : .nearBlack
    }
}

/// Colors for the saved-match rows and notch diagrams. Pitch and width each use one hue, shaded
/// lighter to darker, so the shade alone tells you roughly where a match sits.
public enum MatchPalette {
    public static let pitchHue = 178.0
    public static let widthHue = 330.0

    public static func ear(_ ear: Ear) -> RGB {
        switch ear {
        case .left: RGB(hex: 0x2457C5)
        case .right: RGB(hex: 0xF2A33A)
        case .both: RGB(hex: 0x5B2A86)
        }
    }

    /// Light at 250 Hz to dark at 16 kHz.
    public static func pitch(_ hz: Double) -> RGB {
        let t = min(1, max(0, NotchScale.position(hz)))
        return RGB(hue: pitchHue, saturation: 0.62, lightness: 0.88 - t * 0.66)
    }

    /// Lightest for a pure tone, then light at 1/32 octave to dark at 1 octave.
    public static func width(_ octaves: Double) -> RGB {
        guard octaves > 0 else { return RGB(hue: widthHue, saturation: 0.65, lightness: 0.94) }
        let t = min(1, max(0, log2(octaves * 32) / 5))
        return RGB(hue: widthHue, saturation: 0.65, lightness: 0.82 - t * 0.54)
    }

    /// The removed bands in the notch diagrams.
    public static let notch = RGB(hue: widthHue, saturation: 0.65, lightness: 0.55)
}

/// The log frequency axis shared by every notch diagram: 250 Hz at the left edge, 16 kHz at the right.
public enum NotchScale {
    public static let lowHz = TunerMath.minPitchHz
    public static let highHz = TunerMath.maxPitchHz

    /// 0 at `lowHz`, 1 at `highHz`. Not clamped.
    public static func position(_ hz: Double) -> Double {
        log2(hz / lowHz) / log2(highHz / lowHz)
    }

    /// Octave gridlines between the edges.
    public static let gridHz: [Double] = [500, 1000, 2000, 4000, 8000]
}
