import Foundation

enum LiveEngineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple
    case nemotron
    case parakeet

    var id: String { rawValue }

    static let `default`: LiveEngineKind = .apple

    var label: String {
        switch self {
        case .apple: return "Apple"
        case .nemotron: return "Nemotron"
        case .parakeet: return "Parakeet"
        }
    }

    var usesLanguagePicker: Bool {
        self == .apple
    }
}
