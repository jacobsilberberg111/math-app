import UIKit
import WebKit

/// Runs Python for code blocks: Pyodide (CPython compiled to WebAssembly) inside a Web Worker in
/// a hidden WKWebView. The page itself is CodeRunnerPage (Core), which owns the worker and kills
/// it when a program runs too long.
///
/// The web view is attached to the key window as a 1×1, nearly transparent, non-interactive view
/// behind everything. A WKWebView that isn't in a window is treated by WebKit as a hidden page,
/// whose timers and JavaScript can be throttled or suspended, which would stall Python's start-up
/// and the timeout that stops runaway loops. In a window it's a normal visible page, and the
/// student never sees or touches it.
///
/// Runs are serialized: one program at a time, in the order they were asked for.
@MainActor
@Observable
final class PythonRunner {
    static let shared = PythonRunner()

    enum Phase: Equatable {
        case idle
        /// Loading Pyodide (several seconds the first time; it downloads ~12 MB once).
        case starting
        case running
        case ready
        /// The last attempt to start failed (usually no internet the first time).
        case unavailable
    }

    private(set) var phase: Phase = .idle
    /// Python has started at least once since the app launched (restarts are quicker).
    private(set) var hasStarted = false

    /// How long a program may run before it's stopped (seconds). Also run(_:stdin:timeout:)'s default.
    static let defaultTimeout: TimeInterval = 10

    /// What the UI shows while a run is under way.
    var statusText: String? {
        switch phase {
        case .starting: return hasStarted ? "Restarting Python…" : "Starting Python… the first run takes a few seconds"
        case .running: return "Running…"
        default: return nil
        }
    }

    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var navigationDelegate: PythonWebViewDelegate?
    @ObservationIgnored private var pageLoaded = false
    /// Bumped whenever the web view is replaced, so stale callbacks are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var restarting = false
    @ObservationIgnored private var waiting: [CheckedContinuation<Void, Never>] = []

    private init() {}

    // MARK: Running

    /// Runs a program and returns what it printed. `stdin` is the program input, one line per
    /// input() call. `onPhase` reports progress (starting Python, running) for status displays.
    /// Cancelling the calling task stops the program.
    func run(_ code: String, stdin: [String], timeout: TimeInterval = 10,
             onPhase: ((Phase) -> Void)? = nil) async -> CodeRunResult {
        await acquire()
        defer { release() }
        if Task.isCancelled { return CodeRunResult(status: .cancelled, error: "Stopped.") }
        if !hasStarted || restarting || phase == .unavailable || webView == nil || !pageLoaded { setPhase(.starting, onPhase) }
        let boot = await start()
        guard boot.ok else {
            setPhase(.unavailable, onPhase)
            return CodeRunResult.fromRunner(["status": "unavailable", "message": boot.message], timeout: timeout)
        }
        setPhase(.running, onPhase)
        let args: [String: Any] = [
            "indexURL": CodeRunnerPage.indexURL,
            "code": CodeText.normalized(code),
            "stdin": CodeText.stdinText(stdin),
            "timeoutMs": Int(timeout * 1000),
        ]
        let reply = await withTaskCancellationHandler {
            await self.call("const r = await window.marginRun(indexURL, code, stdin, timeoutMs); return JSON.stringify(r);",
                            args, limit: timeout + 150)
        } onCancel: {
            Task { @MainActor in PythonRunner.shared.cancelCurrentRun() }
        }
        let result: CodeRunResult
        switch reply {
        case .success(let json):
            result = CodeRunResult.fromRunner(PythonRunner.dictionary(json), timeout: timeout)
        case .failure(let error):
            // The page stopped answering (its process was suspended or ended): start afresh next time.
            resetWebView()
            result = CodeRunResult.fromRunner(["status": "crashed", "message": error.localizedDescription], timeout: timeout)
        }
        // After a timeout or crash the page is already starting a fresh Python for next time.
        restarting = [.timedOut, .crashed, .cancelled].contains(result.status)
        setPhase(.ready, onPhase)
        return result
    }

    /// Starts Python in the background (e.g. when the code editor opens) so the first Run is
    /// quicker. Failures are silent; a real run reports them.
    func warmUp() {
        guard !busy, !hasStarted else { return }
        Task { @MainActor in
            await self.acquire()
            defer { self.release() }
            guard !self.hasStarted else { return }
            if self.phase == .idle { self.phase = .starting }
            let ok = await self.start().ok
            // A failure stays quiet here (no "couldn't start" before the student has tapped Run).
            if self.phase == .starting { self.phase = ok ? .ready : .idle }
        }
    }

    /// Stops the program that's running, if any.
    func cancelCurrentRun() {
        guard busy, pageLoaded, let webView else { return }
        webView.callAsyncJavaScript("return JSON.stringify(window.marginCancel());", arguments: [:], in: nil, in: .page, completionHandler: nil)
    }

    private func setPhase(_ p: Phase, _ onPhase: ((Phase) -> Void)?) {
        if phase != p { phase = p }
        onPhase?(p)
    }

    // MARK: Serializing runs

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in waiting.append(c) }
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    // MARK: Starting Python

    /// Makes sure the page is loaded and Python has booted in its worker (quick when it already
    /// has; after a timeout the page is already booting a fresh worker, and this waits for it).
    private func start() async -> (ok: Bool, message: String) {
        guard await ensurePage() else { return (false, "The Python page didn't load.") }
        let reply = await call("const r = await window.marginBoot(indexURL); return JSON.stringify(r);",
                               ["indexURL": CodeRunnerPage.indexURL], limit: 150)
        switch reply {
        case .success(let json):
            let d = PythonRunner.dictionary(json)
            if PythonRunner.bool(d["ok"]) {
                hasStarted = true
                restarting = false
                return (true, "")
            }
            return (false, d["message"] as? String ?? "Python couldn't start.")
        case .failure(let error):
            resetWebView()
            return (false, error.localizedDescription)
        }
    }

    private func ensurePage() async -> Bool {
        if webView == nil { makeWebView() }
        attachToWindow()
        if pageLoaded { return true }
        // Poll until the page script has defined its entry points (about 20 s at most). Polling
        // doesn't depend on navigation-delegate timing and copes with a reload in between.
        let gen = generation
        for _ in 0..<80 {
            if case .success(let state) = await call("return (typeof window.marginRun === 'function') ? 'ready' : 'loading';", [:], limit: 5),
               state == "ready", gen == generation {
                pageLoaded = true
                return true
            }
            if gen != generation { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        resetWebView()
        return false
    }

    private func makeWebView() {
        generation += 1
        let config = WKWebViewConfiguration()
        // The default store keeps WebKit's HTTP cache between launches, so Pyodide's files are
        // normally downloaded only once.
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.isUserInteractionEnabled = false
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.alpha = 0.01
        wv.isAccessibilityElement = false
        wv.accessibilityElementsHidden = true
        #if DEBUG
        wv.isInspectable = true
        #endif
        let delegate = PythonWebViewDelegate()
        delegate.onProcessEnded = { [weak self] in self?.webContentProcessEnded() }
        wv.navigationDelegate = delegate
        navigationDelegate = delegate
        webView = wv
        pageLoaded = false
        attachToWindow()
        // The CDN folder as base URL: the page (and the Blob worker it makes) is then same-origin
        // with Pyodide's files, so importScripts and Pyodide's fetches need no CORS.
        wv.loadHTMLString(CodeRunnerPage.html, baseURL: URL(string: CodeRunnerPage.indexURL))
    }

    private func attachToWindow() {
        guard let wv = webView else { return }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return }
        if wv.window === window { return }
        wv.removeFromSuperview()
        wv.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        window.insertSubview(wv, at: 0)
    }

    private func resetWebView() {
        generation += 1
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        navigationDelegate = nil
        pageLoaded = false
    }

    private func webContentProcessEnded() {
        // iOS reclaims a background web process when memory is short. Start over on the next run.
        resetWebView()
    }

    // MARK: Talking to the page

    private enum PageError: LocalizedError {
        case noPage, noReply
        var errorDescription: String? {
            switch self {
            case .noPage: return "The Python page isn't loaded."
            case .noReply: return "Python stopped responding."
            }
        }
    }

    /// Runs an async JavaScript function body on the page and returns its (string) result. Every
    /// call returns a string (JSON.stringify), never undefined: some WebKit versions trap when an
    /// async call resolves with no value. `limit` guards against a page that never answers.
    private func call(_ body: String, _ args: [String: Any], limit: TimeInterval) async -> Result<String, Error> {
        guard let webView else { return .failure(PageError.noPage) }
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<String, Error>, Never>) in
            let once = ResumeOnce()
            let watchdog = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                if once.claim() { cont.resume(returning: .failure(PageError.noReply)) }
            }
            webView.callAsyncJavaScript(body, arguments: args, in: nil, in: .page) { result in
                watchdog.cancel()
                guard once.claim() else { return }
                switch result {
                case .success(let value):
                    cont.resume(returning: .success(value as? String ?? ""))
                case .failure(let error):
                    cont.resume(returning: .failure(error))
                }
            }
        }
    }

    static func dictionary(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    static func bool(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return false
    }
}

/// Resumes a continuation exactly once (whichever of the reply and the watchdog comes first).
private final class ResumeOnce {
    private var done = false
    func claim() -> Bool {
        if done { return false }
        done = true
        return true
    }
}

/// Hears when the web content process ends (iOS can reclaim it while the app is in the background).
@MainActor
final class PythonWebViewDelegate: NSObject, WKNavigationDelegate {
    var onProcessEnded: (() -> Void)?

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor [weak self] in self?.onProcessEnded?() }
    }
}

// MARK: - Running a block

/// Running a code block on the page (the selection bar's Run, and the tutor's run_code).
@MainActor
enum CodeExecution {
    /// Runs the code block `elementID` and stores its output in the element (undoable).
    static func run(elementID: String, in document: NoteDocument) async {
        guard let e = document.element(elementID), case .code(let c) = e.kind else { return }
        let badge = CodeRunBadge.show(on: document, elementID: elementID)
        guard c.isRunnable else {
            badge?.finish("Pseudocode isn't run: trace it with a table", symbol: "info.circle", tint: CodeRenderer.quietColor, after: 3)
            return
        }
        guard !c.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            badge?.finish("Nothing to run yet: tap Edit Code", symbol: "info.circle", tint: CodeRenderer.quietColor, after: 3)
            return
        }
        Haptics.tap()
        let result = await PythonRunner.shared.run(c.code, stdin: c.stdinLines) { phase in badge?.update(phase) }
        if result.ran {
            store(result, ranWith: c, into: elementID, in: document)
            badge?.finish(result.headline, symbol: result.status == .finished ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                          tint: result.status == .finished ? UIColor(hex: "#1A7F37") : CodeRenderer.errorColor, after: 2)
        } else if result.status == .unavailable {
            badge?.finish("Python needs the internet the first time it starts", symbol: "wifi.exclamationmark", tint: CodeRenderer.errorColor, after: 5)
        } else {
            badge?.finish(result.headline, symbol: "stop.circle", tint: CodeRenderer.quietColor, after: 2)
        }
    }

    /// Stores a run on a block in one undoable step, resizing it to fit the new output. Skipped
    /// (returns false) if the block's code or input changed while it ran.
    @discardableResult
    static func store(_ result: CodeRunResult, ranWith c: CodeContent, into id: String, in document: NoteDocument,
                      actionName: String = "Run Code") -> Bool {
        guard let e = document.element(id), case .code(let now) = e.kind,
              now.code == c.code, now.stdin == c.stdin, now.language == c.language else { return false }
        let updated = result.applied(to: now, at: Date())
        let height = CodeRenderer.size(for: updated, width: e.frame.width).height
        document.update(id, actionName: actionName) {
            $0.kind = .code(updated)
            $0.frame.size.height = height
        }
        return true
    }
}

/// A small status pill over a code block's header while it runs ("Starting Python…",
/// "Running…", then the result for a moment).
@MainActor
final class CodeRunBadge: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let icon = UIImageView()
    private let label = UILabel()

    static func show(on document: NoteDocument, elementID: String) -> CodeRunBadge? {
        guard let canvas = document.canvas as? NoteCanvasViewController, let host = canvas.elementViews[elementID] else { return nil }
        for old in host.subviews.compactMap({ $0 as? CodeRunBadge }) { old.removeFromSuperview() }
        let badge = CodeRunBadge(frame: .zero)
        host.addSubview(badge)
        badge.set("Running…", spinning: true, symbol: nil, tint: .secondaryLabel)
        return badge
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.white.withAlphaComponent(0.96)
        layer.borderColor = CodeRenderer.borderColor.cgColor
        layer.borderWidth = 1
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.08
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
        spinner.hidesWhenStopped = true
        spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        icon.contentMode = .scaleAspectFit
        label.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        addSubview(spinner)
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ phase: PythonRunner.Phase) {
        switch phase {
        case .starting:
            set(PythonRunner.shared.hasStarted ? "Restarting Python…" : "Starting Python…", spinning: true, symbol: nil, tint: .secondaryLabel)
        case .running:
            set("Running…", spinning: true, symbol: nil, tint: .secondaryLabel)
        default:
            break
        }
    }

    func finish(_ text: String, symbol: String, tint: UIColor, after seconds: TimeInterval) {
        set(text, spinning: false, symbol: symbol, tint: tint)
        UIView.animate(withDuration: 0.3, delay: seconds, options: [], animations: { self.alpha = 0 }) { _ in
            self.removeFromSuperview()
        }
    }

    private func set(_ text: String, spinning: Bool, symbol: String?, tint: UIColor) {
        label.text = text
        label.textColor = spinning ? .secondaryLabel : tint
        if spinning {
            spinner.startAnimating()
            icon.isHidden = true
        } else {
            spinner.stopAnimating()
            icon.image = symbol.flatMap { UIImage(systemName: $0) }
            icon.tintColor = tint
            icon.isHidden = icon.image == nil
        }
        relayout()
    }

    private func relayout() {
        guard let host = superview else { return }
        let scale = max(host.contentScaleFactor, traitCollection.displayScale)
        label.contentScaleFactor = scale
        let h: CGFloat = 22
        let leading: CGFloat = 26
        label.sizeToFit()
        let maxW = max(60, host.bounds.width - 2 * ElementView.padding - 120)
        let w = min(maxW, leading + ceil(label.bounds.width) + 10)
        frame = CGRect(x: host.bounds.maxX - ElementView.padding - 10 - w,
                       y: ElementView.padding + (CodeCardMetrics.headerHeight - h) / 2, width: w, height: h)
        layer.cornerRadius = h / 2
        spinner.center = CGPoint(x: 15, y: h / 2)
        icon.frame = CGRect(x: 8, y: (h - 14) / 2, width: 14, height: 14)
        label.frame = CGRect(x: leading, y: (h - label.bounds.height) / 2, width: w - leading - 10, height: label.bounds.height)
    }
}
