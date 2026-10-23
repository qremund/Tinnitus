import Foundation
import TinnitusCore

enum Format {
    static func frequency(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.2f kHz", hz / 1000) : String(format: "%.0f Hz", hz)
    }

    static func bandwidth(_ octaves: Double) -> String {
        if octaves <= 0 { return "Pure tone" }
        if octaves >= 0.99 { return "1 octave" }
        return "1/\(Int((1 / octaves).rounded())) octave"
    }

    static func level(_ db: Double) -> String {
        "\(Int(db.rounded())) dB"
    }
}

extension Ear {
    var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .both: "Both / in my head"
        }
    }
}

extension TinnitusSoundType {
    var title: String {
        switch self {
        case .tone: "Tone or whine"
        case .narrowHiss: "Narrow hiss"
        case .broadHiss: "Broad hiss"
        }
    }

    var detail: String {
        switch self {
        case .tone: "A clear pitch, like a whistle or a TV whine."
        case .narrowHiss: "A pitched hiss or buzz, like steam from a kettle."
        case .broadHiss: "A wide rush, like wind or a distant waterfall."
        }
    }
}
