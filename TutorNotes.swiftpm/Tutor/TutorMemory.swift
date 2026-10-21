import Foundation
import AVFoundation
import Speech

/// Durable notes the tutor keeps about the student across all notes and sessions.
final class TutorMemoryStore: ObservableObject {
    static let shared = TutorMemoryStore()

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var text: String
        var date = Date()
    }

    @Published private(set) var entries: [Entry] = []

    private init() {
        entries = Storage.read([Entry].self, from: Storage.memoryURL) ?? []
    }

    func add(_ text: String) {
        let t = text.trimmed
        guard !t.isEmpty else { return }
        if entries.contains(where: { $0.text.caseInsensitiveCompare(t) == .orderedSame }) { return }
        entries.append(Entry(text: String(t.prefix(240))))
        // Keep the memory small enough to include in every request.
        if entries.count > 40 { entries.removeFirst(entries.count - 40) }
        save()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        let snapshot = entries
        Storage.ioQueue.async { try? Storage.write(snapshot, to: Storage.memoryURL) }
    }

    var promptText: String {
        guard !entries.isEmpty else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return entries.map { "- \(f.string(from: $0.date)): \($0.text)" }.joined(separator: "\n")
    }
}

/// Reads short tutor feedback aloud when "Speak feedback" is on.
@MainActor
final class TutorVoice {
    static let shared = TutorVoice()
    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let t = text.trimmed
        guard !t.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .word) }
        let session = AVAudioSession.sharedInstance()
        // Play-and-record (a lecture recording) can already play speech; switching it to
        // playback would stop the recording.
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .mixWithOthers])
        }
        let u = AVSpeechUtterance(string: String(t.prefix(600)))
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        u.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "en-US")
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }
}

/// Push-to-talk dictation for asking the tutor questions without putting the pencil down.
@MainActor
final class SpeechDictation: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var errorMessage: String?

    // Created on first use: the engine opens the audio hardware, which isn't free and isn't
    // needed until someone actually dictates.
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer()
    /// True while a lecture recording owns the audio session: dictate inside it instead of
    /// reconfiguring or deactivating it (either would stop the recording).
    private var sharesRecordingSession = false

    func start(duringRecording: Bool = false) {
        guard !isRecording else { return }
        errorMessage = nil
        sharesRecordingSession = duringRecording
        SpeechDictation.requestAuthorization { [weak self] authorized in
            guard let self else { return }
            guard authorized else {
                self.errorMessage = "Speech recognition isn't allowed. Enable it in Settings."
                return
            }
            self.beginSession()
        }
    }

    // Callbacks from Speech/AVFoundation arrive on background queues, so they are set up in
    // nonisolated helpers and hop back to the main actor explicitly.
    nonisolated private static func requestAuthorization(_ completion: @escaping @MainActor (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            let ok = status == .authorized
            Task { @MainActor in completion(ok) }
        }
    }

    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat,
                                               request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    nonisolated private static func startTask(_ recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                             update: @escaping @MainActor (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in update(text, done) }
        }
    }

    private func beginSession() {
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available right now."
            return
        }
        do {
            if !sharesRecordingSession {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            }
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = false }
            request = req
            let engine = self.engine ?? AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                // installTap traps on an invalid format (no usable microphone).
                errorMessage = "No microphone is available."
                stop()
                return
            }
            input.removeTap(onBus: 0)
            SpeechDictation.installTap(on: input, format: format, request: req)
            engine.prepare()
            try engine.start()
            transcript = ""
            isRecording = true
            task = SpeechDictation.startTask(recognizer, request: req) { [weak self] text, done in
                guard let self else { return }
                if let text { self.transcript = text }
                if done { self.stop() }
            }
        } catch {
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        // `request` is set early in beginSession, so this also cleans up a start that failed.
        guard isRecording || engine?.isRunning == true || request != nil else { return }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        isRecording = false
        if !sharesRecordingSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
