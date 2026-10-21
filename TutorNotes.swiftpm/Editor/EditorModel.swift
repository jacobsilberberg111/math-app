import SwiftUI
import PencilKit
import AVFoundation

struct QuickMenuRequest: Equatable {
    var page: Int
    var rect: CGRect      // page coordinates of the region it's about
    var anchor: CGRect    // in canvas view coordinates
}

/// State for an open note, and the bridge between the canvas, the toolbar and the tutor.
@MainActor
@Observable
final class EditorModel: CanvasHost {
    let document: NoteDocument
    let tutor: TutorEngine
    let tools = ToolState()
    let audio: AudioController

    @ObservationIgnored weak var canvas: NoteCanvasViewController? {
        didSet {
            tutor.canvas = canvas
            audio.canvas = canvas
        }
    }

    var showTutor = false
    var showPages = false
    var showPractice = false
    var showPaper = false
    var currentPage = 0
    var canUndo = false
    var canRedo = false
    var quickMenu: QuickMenuRequest?
    var selectedElement: CanvasElement?
    var toast: String?
    var palettePresented = false
    var pendingFocus: (page: Int, rect: CGRect)?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(document: NoteDocument) {
        self.document = document
        self.tutor = TutorEngine(document: document)
        self.audio = AudioController(document: document)
    }

    var pageCount: Int { document.content.pages.count }

    func flash(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func selectTool(_ kind: CanvasToolKind) {
        if kind == tools.kind && kind == .eraser {
            tools.eraserMode = tools.eraserMode == .stroke ? .pixel : .stroke
            flash(tools.eraserMode == .stroke ? "Stroke eraser" : "Pixel eraser")
            return
        }
        tools.kind = kind
        if kind != .tutor { quickMenu = nil }
    }

    func undo() { canvas?.undo() }
    func redo() { canvas?.redo() }

    // MARK: Tutor entry points from the canvas

    func runQuick(_ action: TutorQuickAction, on request: QuickMenuRequest?) {
        let focus = request.map { (page: $0.page, rect: $0.rect) }
        quickMenu = nil
        canvas?.clearRegion()
        if action == .practice {
            showPractice = true
            return
        }
        tutor.quick(action, focus: focus)
    }

    func askAboutRegion(_ request: QuickMenuRequest) {
        pendingFocus = (request.page, request.rect)
        quickMenu = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { showTutor = true }
    }

    func dismissQuickMenu() {
        quickMenu = nil
        canvas?.clearRegion()
    }

    // MARK: CanvasHost

    func canvasVisiblePageChanged(_ page: Int) {
        currentPage = page
        if case .offscreen(let p) = tutor.suggestion, p == page { tutor.dismissSuggestion() }
    }

    func canvasStudentWrote(docRects: [CGRect]) {
        tutor.studentWrote(docRects)
        if quickMenu != nil { dismissQuickMenu() }
    }

    func canvasPencilStateChanged(isDrawing: Bool) {
        tutor.pencilStateChanged(isDrawing: isDrawing)
        if isDrawing {
            canvas?.flushReveals()
        }
    }

    func canvasRegionSelected(page: Int, rect: CGRect, anchor: CGRect) {
        quickMenu = QuickMenuRequest(page: page, rect: rect, anchor: anchor)
    }

    func canvasTutorMenuRequested(docPoint: CGPoint, anchor: CGRect) {
        let (page, p) = document.pagePoint(fromDoc: docPoint)
        let region = canvas?.regionAround(pagePoint: p, page: page) ?? CGRect(x: p.x - 140, y: p.y - 70, width: 280, height: 140)
        canvas?.showRegion(document.docRect(region, page: page))
        quickMenu = QuickMenuRequest(page: page, rect: region, anchor: anchor)
    }

    func canvasElementAction(_ action: ElementAction, element: CanvasElement) {
        canvas?.select(nil)
        switch action {
        case .askTutor, .explain:
            let request = QuickMenuRequest(page: element.pageIndex, rect: element.frame.insetBy(dx: -8, dy: -8),
                                           anchor: canvas?.viewRect(fromDoc: document.docRect(for: element)) ?? .zero)
            canvas?.showRegion(document.docRect(request.rect, page: request.page))
            quickMenu = request
        case .revealHint:
            tutor.revealHint(for: element)
        case .revealSolution:
            tutor.revealSolution(for: element)
        case .checkAnswer:
            tutor.checkAnswer(for: element)
        default:
            break
        }
    }

    func canvasRequestTool(_ kind: CanvasToolKind?) {
        guard let kind else { return }
        tools.kind = kind
        flash(kind.title)
    }

    func canvasRequestPalette(anchor: CGRect) {
        palettePresented = true
    }

    func canvasUndoStateChanged() {
        canUndo = document.undoManager.canUndo
        canRedo = document.undoManager.canRedo
    }

    func canvasSelectionChanged(_ element: CanvasElement?) {
        selectedElement = element
    }

    func canvasReplayTapped(at docPoint: CGPoint) {
        audio.seek(toStrokeNear: docPoint)
    }

    func canvasShapeSnapped(_ name: String) {
        flash(name)
    }

    func canvasOffscreenTutorEdit(page: Int, docRect: CGRect) {
        tutor.suggestion = .offscreen(page: page)
    }

    // MARK: Lifecycle

    func close(library: LibraryStore) {
        audio.stopAll()
        tutor.shutdown()
        document.saveNow()
        let thumb = PageRenderer.thumbnail(document)
        library.setThumbnail(thumb, for: document.id)
        library.update(document.meta)
        let doc = document
        Task {
            if let text = await HandwritingIndexer.index(doc) {
                var meta = doc.meta
                meta.searchText = text
                library.persist(meta)
            }
        }
    }
}

/// Lecture recording synced to the ink, Notability style: during playback, strokes appear as
/// they were written, and tapping a stroke jumps the audio to that moment.
@MainActor
@Observable
final class AudioController: NSObject, AVAudioPlayerDelegate {
    let document: NoteDocument
    @ObservationIgnored weak var canvas: NoteCanvasViewController?

    var isRecording = false
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var activeRecordingID: String?
    var replayInk = true
    var permissionDenied = false

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var tick: Task<Void, Never>?
    @ObservationIgnored private var recordingStart = Date()

    init(document: NoteDocument) {
        self.document = document
        super.init()
        activeRecordingID = document.content.recordings.last?.id
        duration = document.content.recordings.last?.duration ?? 0
    }

    var recordings: [AudioRecording] { document.content.recordings }

    var activeRecording: AudioRecording? {
        recordings.first { $0.id == activeRecordingID } ?? recordings.last
    }

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        stopPlayback()
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard granted else {
                    self.permissionDenied = true
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        let id = "rec-\(UUID().uuidString.prefix(6))"
        let file = "\(id).m4a"
        let url = document.assetURL(file)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 32000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.record()
            recorder = r
            recordingStart = Date()
            isRecording = true
            activeRecordingID = id
            document.content.recordings.append(AudioRecording(id: id, fileName: file, startedAt: recordingStart, duration: 0))
            document.markDirty()
            startTick()
        } catch {
            isRecording = false
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        recorder?.stop()
        let elapsed = Date().timeIntervalSince(recordingStart)
        if let id = activeRecordingID, let i = document.content.recordings.firstIndex(where: { $0.id == id }) {
            document.content.recordings[i].duration = elapsed
        }
        duration = elapsed
        recorder = nil
        isRecording = false
        tick?.cancel()
        document.markDirty()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard let rec = activeRecording else { return }
        do {
            if player == nil || player?.url != document.assetURL(rec.fileName) {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                let p = try AVAudioPlayer(contentsOf: document.assetURL(rec.fileName))
                p.delegate = self
                p.prepareToPlay()
                player = p
                duration = p.duration
            }
            player?.play()
            isPlaying = true
            startTick()
        } catch {
            isPlaying = false
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
        canvas?.setReplay(time: nil)
    }

    func stopAll() {
        stopRecording()
        stopPlayback()
        tick?.cancel()
    }

    func seek(to t: TimeInterval) {
        guard let p = player ?? preparedPlayer() else { return }
        p.currentTime = max(0, min(t, p.duration))
        currentTime = p.currentTime
        updateReplay()
    }

    private func preparedPlayer() -> AVAudioPlayer? {
        guard let rec = activeRecording, let p = try? AVAudioPlayer(contentsOf: document.assetURL(rec.fileName)) else { return nil }
        p.delegate = self
        p.prepareToPlay()
        player = p
        duration = p.duration
        return p
    }

    /// Jumps to the moment the stroke under the point was written.
    func seek(toStrokeNear docPoint: CGPoint) {
        guard let rec = activeRecording else { return }
        let probe = CGRect(x: docPoint.x - 12, y: docPoint.y - 12, width: 24, height: 24)
        let strokes = document.drawing.strokes.filter { $0.renderBounds.intersects(probe) }
        guard let s = strokes.min(by: { $0.renderBounds.center.distance(to: docPoint) < $1.renderBounds.center.distance(to: docPoint) }) else { return }
        let offset = s.path.creationDate.timeIntervalSince(rec.startedAt)
        guard offset >= 0, offset <= max(rec.duration, duration) + 1 else { return }
        seek(to: max(0, offset - 1.5))
        if !isPlaying { play() }
    }

    private func startTick() {
        tick?.cancel()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                if self.isRecording {
                    self.currentTime = Date().timeIntervalSince(self.recordingStart)
                } else if self.isPlaying, let p = self.player {
                    self.currentTime = p.currentTime
                    self.updateReplay()
                } else {
                    return
                }
            }
        }
    }

    private func updateReplay() {
        guard replayInk, let rec = activeRecording else { return }
        canvas?.setReplay(time: rec.startedAt.addingTimeInterval(currentTime))
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.isPlaying = false
            self?.canvas?.setReplay(time: nil)
        }
    }
}
