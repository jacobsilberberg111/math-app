import SwiftUI

enum TutorEffort: String, CaseIterable, Identifiable, Codable {
    case low, medium, high, max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Quick"
        case .medium: return "Balanced"
        case .high: return "Deep"
        case .max: return "Max"
        }
    }

    var subtitle: String {
        switch self {
        case .low: return "Fastest replies"
        case .medium: return "Good for most tutoring"
        case .high: return "Harder problems"
        case .max: return "Slowest, most thorough"
        }
    }
}

struct ClaudeModelOption: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    /// Server-side refusal fallbacks (`fallbacks: "default"`) are offered for these models.
    let supportsFallbacks: Bool

    static let sonnet = ClaudeModelOption(id: "claude-sonnet-5-5", name: "Sonnet 5.5", subtitle: "Fast and smart · default", supportsFallbacks: true)
    static let opus = ClaudeModelOption(id: "claude-opus-5-5", name: "Opus 5.5", subtitle: "Deepest reasoning", supportsFallbacks: true)
    static let haiku = ClaudeModelOption(id: "claude-haiku-5-5", name: "Haiku 5.5", subtitle: "Fastest and cheapest", supportsFallbacks: false)
    static let fable = ClaudeModelOption(id: "claude-fable-5-1", name: "Fable 5.1", subtitle: "Most capable · premium", supportsFallbacks: true)

    static let all: [ClaudeModelOption] = [sonnet, opus, haiku, fable]

    static func option(for id: String) -> ClaudeModelOption {
        all.first { $0.id == id } ?? ClaudeModelOption(id: id, name: id, subtitle: "Custom model", supportsFallbacks: false)
    }
}

enum Proactivity: String, CaseIterable, Identifiable {
    case quiet, balanced, handsOn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quiet: return "Quiet"
        case .balanced: return "Balanced"
        case .handsOn: return "Hands-on"
        }
    }

    var detail: String {
        switch self {
        case .quiet: return "Steps in only for clear mistakes and finished answers."
        case .balanced: return "Catches mistakes, marks answers, and encourages now and then."
        case .handsOn: return "Coaches every step, like a tutor sitting next to you."
        }
    }

    /// Minimum seconds between proactive looks.
    var cooldown: TimeInterval {
        switch self {
        case .quiet: return 25
        case .balanced: return 12
        case .handsOn: return 6
        }
    }
}

enum ObserverModelChoice: String, CaseIterable, Identifiable {
    case sameAsTutor, haiku

    var id: String { rawValue }
    var title: String { self == .sameAsTutor ? "Same as tutor" : "Haiku 5.5 (cheaper)" }
}

enum TutorHandStyle: String, CaseIterable, Identifiable {
    case handwriting, typed

    var id: String { rawValue }
    var title: String { self == .handwriting ? "Handwritten" : "Typed" }
}

enum PencilTapAction: String, CaseIterable, Identifiable {
    case system, eraser, previous, askTutor, nothing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Use system setting"
        case .eraser: return "Switch to eraser"
        case .previous: return "Previous tool"
        case .askTutor: return "Ask tutor"
        case .nothing: return "Do nothing"
        }
    }
}

enum PencilSqueezeAction: String, CaseIterable, Identifiable {
    case tutorMenu, toolPalette, nothing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tutorMenu: return "Tutor quick menu"
        case .toolPalette: return "Tool palette"
        case .nothing: return "Do nothing"
        }
    }
}

/// How the app reaches Claude: through your own tutor server (which holds the API key, e.g. on
/// Railway) or directly with an API key stored on this iPad.
enum TutorConnection: String, CaseIterable, Identifiable {
    case server, apiKey

    var id: String { rawValue }
    var title: String { self == .server ? "Tutor server" : "Own API key" }
}

/// App-wide preferences. Persisted in UserDefaults; secrets (API key, server token) live in the Keychain.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var connection: TutorConnection { didSet { defaults.set(connection.rawValue, forKey: "connection") } }
    @Published var apiKey: String { didSet { Keychain.write(apiKey.trimmed, for: "apiKey") } }
    @Published var serverURL: String { didSet { defaults.set(serverURL.trimmed, forKey: "serverURL") } }
    @Published var serverToken: String { didSet { Keychain.write(serverToken.trimmed, for: "serverToken") } }
    @Published var tutorModel: String { didSet { defaults.set(tutorModel, forKey: "tutorModel") } }
    @Published var effort: TutorEffort { didSet { defaults.set(effort.rawValue, forKey: "effort") } }
    @Published var proactive: Bool { didSet { defaults.set(proactive, forKey: "proactive") } }
    @Published var proactivity: Proactivity { didSet { defaults.set(proactivity.rawValue, forKey: "proactivity") } }
    @Published var observerModel: ObserverModelChoice { didSet { defaults.set(observerModel.rawValue, forKey: "observerModel") } }
    @Published var pauseDelay: Double { didSet { defaults.set(pauseDelay, forKey: "pauseDelay") } }
    @Published var speakFeedback: Bool { didSet { defaults.set(speakFeedback, forKey: "speakFeedback") } }
    @Published var tutorHand: TutorHandStyle { didSet { defaults.set(tutorHand.rawValue, forKey: "tutorHand") } }
    @Published var tutorInkHex: String { didSet { defaults.set(tutorInkHex, forKey: "tutorInkHex") } }
    @Published var studentLevel: String { didSet { defaults.set(studentLevel, forKey: "studentLevel") } }
    @Published var studentGoals: String { didSet { defaults.set(studentGoals, forKey: "studentGoals") } }
    @Published var fingerDrawing: Bool { didSet { defaults.set(fingerDrawing, forKey: "fingerDrawing") } }
    @Published var shapeRecognition: Bool { didSet { defaults.set(shapeRecognition, forKey: "shapeRecognition") } }
    @Published var hoverPreview: Bool { didSet { defaults.set(hoverPreview, forKey: "hoverPreview") } }
    @Published var gestureUndo: Bool { didSet { defaults.set(gestureUndo, forKey: "gestureUndo") } }
    @Published var doubleTapAction: PencilTapAction { didSet { defaults.set(doubleTapAction.rawValue, forKey: "doubleTapAction") } }
    @Published var squeezeAction: PencilSqueezeAction { didSet { defaults.set(squeezeAction.rawValue, forKey: "squeezeAction") } }
    @Published var defaultPattern: PaperPattern { didSet { defaults.set(defaultPattern.rawValue, forKey: "defaultPattern") } }
    @Published var defaultPaperColor: PaperColor { didSet { defaults.set(defaultPaperColor.rawValue, forKey: "defaultPaperColor") } }
    @Published var autoAddPages: Bool { didSet { defaults.set(autoAddPages, forKey: "autoAddPages") } }
    @Published var hasSeenOnboarding: Bool { didSet { defaults.set(hasSeenOnboarding, forKey: "hasSeenOnboarding") } }

    private init() {
        let d = UserDefaults.standard
        let storedKey = Keychain.read("apiKey") ?? ""
        apiKey = storedKey
        let storedURL = d.string(forKey: "serverURL") ?? ""
        serverURL = storedURL.isEmpty ? BuildConfig.serverURL : storedURL
        let storedToken = Keychain.read("serverToken") ?? ""
        serverToken = storedToken.isEmpty ? BuildConfig.serverToken : storedToken
        connection = TutorConnection(rawValue: d.string(forKey: "connection") ?? "") ?? (storedKey.isEmpty ? .server : .apiKey)
        tutorModel = d.string(forKey: "tutorModel") ?? ClaudeModelOption.sonnet.id
        effort = TutorEffort(rawValue: d.string(forKey: "effort") ?? "") ?? .medium
        proactive = d.object(forKey: "proactive") as? Bool ?? true
        proactivity = Proactivity(rawValue: d.string(forKey: "proactivity") ?? "") ?? .balanced
        observerModel = ObserverModelChoice(rawValue: d.string(forKey: "observerModel") ?? "") ?? .sameAsTutor
        pauseDelay = d.object(forKey: "pauseDelay") as? Double ?? 3.5
        speakFeedback = d.bool(forKey: "speakFeedback")
        tutorHand = TutorHandStyle(rawValue: d.string(forKey: "tutorHand") ?? "") ?? .typed
        tutorInkHex = d.string(forKey: "tutorInkHex") ?? "#7048E8"
        studentLevel = d.string(forKey: "studentLevel") ?? ""
        studentGoals = d.string(forKey: "studentGoals") ?? ""
        fingerDrawing = d.bool(forKey: "fingerDrawing")
        shapeRecognition = d.object(forKey: "shapeRecognition") as? Bool ?? true
        hoverPreview = d.object(forKey: "hoverPreview") as? Bool ?? true
        gestureUndo = d.object(forKey: "gestureUndo") as? Bool ?? true
        doubleTapAction = PencilTapAction(rawValue: d.string(forKey: "doubleTapAction") ?? "") ?? .system
        squeezeAction = PencilSqueezeAction(rawValue: d.string(forKey: "squeezeAction") ?? "") ?? .tutorMenu
        defaultPattern = PaperPattern(rawValue: d.string(forKey: "defaultPattern") ?? "") ?? .ruled
        defaultPaperColor = PaperColor(rawValue: d.string(forKey: "defaultPaperColor") ?? "") ?? .white
        autoAddPages = d.object(forKey: "autoAddPages") as? Bool ?? true
        hasSeenOnboarding = d.bool(forKey: "hasSeenOnboarding")
    }

    /// The tutor server's base URL, accepting input with or without a scheme.
    var normalizedServerURL: URL? {
        var t = serverURL.trimmed
        guard !t.isEmpty else { return nil }
        if !t.lowercased().hasPrefix("http://") && !t.lowercased().hasPrefix("https://") { t = "https://" + t }
        while t.hasSuffix("/") { t.removeLast() }
        guard let url = URL(string: t), url.host != nil else { return nil }
        return url
    }

    /// Whether the tutor can make requests with the current connection settings.
    var isTutorConfigured: Bool {
        switch connection {
        case .apiKey: return !apiKey.trimmed.isEmpty
        case .server: return normalizedServerURL != nil && !serverToken.trimmed.isEmpty
        }
    }

    func makeClient() -> AnthropicClient {
        switch connection {
        case .apiKey:
            return AnthropicClient(apiKey: apiKey.trimmed)
        case .server:
            return AnthropicClient(serverURL: normalizedServerURL ?? AnthropicClient.anthropicURL, appToken: serverToken.trimmed)
        }
    }
    var defaultPaper: PaperStyle { PaperStyle(pattern: defaultPattern, color: defaultPaperColor) }
    var modelOption: ClaudeModelOption { ClaudeModelOption.option(for: tutorModel) }

    var observerModelID: String {
        observerModel == .haiku ? ClaudeModelOption.haiku.id : tutorModel
    }
}
