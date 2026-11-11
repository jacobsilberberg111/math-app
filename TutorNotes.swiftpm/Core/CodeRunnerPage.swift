import Foundation

/// The hidden page that runs Python for code blocks (see PythonRunner).
///
/// Pyodide (CPython compiled to WebAssembly) runs in a Web Worker made from a Blob URL, so a
/// program that never stops can be killed: on timeout the page terminates the worker and starts
/// a fresh one. The page is loaded with the Pyodide CDN folder as its base URL, which makes the
/// Blob worker same-origin with the CDN, so `importScripts` and Pyodide's own fetches of its
/// .wasm and standard library just work.
///
/// Calls from Swift (callAsyncJavaScript, which awaits the returned Promise):
///   `await marginBoot(indexURL)` → {ok, version} or {ok: false, reason, message, online}
///   `await marginRun(indexURL, code, stdin, timeoutMs)` → {status, output, error, truncated, ms, …}
///       status: "ok" | "error" (error = raw traceback) | "timeout" | "crashed" | "unavailable" | "cancelled"
///   `marginCancel()` stops the program that's running.
/// Every call resolves to an object (never undefined): WebKit's Swift overlay traps if a call
/// resolves with no value on some iOS versions.
enum CodeRunnerPage {
    static let pyodideVersion = "0.29.5"
    static let indexURL = "https://cdn.jsdelivr.net/pyodide/v\(pyodideVersion)/full/"

    /// Python run inside Pyodide once, defining `_margin_run(code, stdin_text, write)`. Output goes
    /// straight to `write` (a JS function) through a text stream, so it keeps its exact order and
    /// a last line without a newline isn't held back. Returns None when the program finishes, or
    /// the formatted traceback when it raises.
    static let driver = #"""
import sys, io, builtins, traceback, linecache

_margin_builtin_input = builtins.input

class _MarginInput:
    """input() fed from the block's Program input, echoing each answer like IDLE does."""
    def __init__(self, text):
        self.stream = io.StringIO(text)

    def __call__(self, prompt=""):
        sys.stdout.write(str(prompt))
        line = self.stream.readline()
        if not line:
            sys.stdout.write("\n")
            raise EOFError("input() ran out of program input. Add another line under Program input (one line for each input() call).")
        if line.endswith("\n"):
            line = line[:-1]
        sys.stdout.write(line + "\n")
        return line

class _MarginStream(io.TextIOBase):
    """sys.stdout and sys.stderr while a program runs: text goes straight to the page."""
    def __init__(self, write):
        self._write = write

    def writable(self):
        return True

    def write(self, s):
        if not isinstance(s, str):
            raise TypeError("write() argument must be str, not " + type(s).__name__)
        if s:
            self._write(s)
        return len(s)

    def flush(self):
        pass

    @property
    def encoding(self):
        return "utf-8"

def _margin_run(code, stdin_text, write):
    feeder = _MarginInput(stdin_text)
    saved = (sys.stdin, sys.stdout, sys.stderr)
    stream = _MarginStream(write)
    sys.stdin = feeder.stream
    sys.stdout = stream
    sys.stderr = stream
    builtins.input = feeder
    # Lets tracebacks show the student's source lines.
    linecache.cache["main.py"] = (len(code), None, code.splitlines(True), "main.py")
    namespace = {"__name__": "__main__", "__file__": "main.py", "__builtins__": builtins}
    try:
        exec(compile(code, "main.py", "exec"), namespace)
        return None
    except SystemExit as e:
        if e.code is None or e.code == 0:
            return None
        if isinstance(e.code, int):
            return "SystemExit: exit code " + str(e.code)
        sys.stderr.write(str(e.code) + "\n")
        return None
    except BaseException as e:
        return "".join(traceback.format_exception(type(e), e, e.__traceback__))
    finally:
        try:
            sys.stdout.flush()
            sys.stderr.flush()
        except Exception:
            pass
        sys.stdin, sys.stdout, sys.stderr = saved
        builtins.input = _margin_builtin_input
"""#

    /// The worker: loads Pyodide, then runs one program per "run" message, posting output in
    /// batches as it's printed (so a program stopped by the timeout still shows what it printed).
    static let worker = #"""
"use strict";
let pyodide = null;
let runner = null;
let jobID = 0;
let buffer = "";
let total = 0;
let lastFlush = 0;
const OUTPUT_CAP = 200000;

function errorText(err) {
  if (!err) return "unknown error";
  if (err.message) return String(err.message);
  return String(err);
}

function flush(force) {
  if (!buffer) return;
  const now = Date.now();
  if (force || buffer.length >= 4096 || now - lastFlush >= 100) {
    self.postMessage({ type: "output", id: jobID, text: buffer });
    buffer = "";
    lastFlush = now;
  }
}

function write(text) {
  if (total >= OUTPUT_CAP) return;
  if (total + text.length > OUTPUT_CAP) text = text.slice(0, OUTPUT_CAP - total);
  total += text.length;
  buffer += text;
  flush(false);
}

// Called from Python for everything the program prints.
function writeOutput(text) {
  write(String(text));
}

async function boot(indexURL, driver) {
  try {
    importScripts(indexURL + "pyodide.js");
  } catch (err) {
    self.postMessage({ type: "boot-error", stage: "script", message: errorText(err) });
    return;
  }
  try {
    pyodide = await loadPyodide({ indexURL: indexURL });
    // Programs print through _MarginStream; these catch anything written to the raw file
    // descriptors instead (rare: C extensions).
    pyodide.setStdout({ batched: (line) => write(line + "\n") });
    pyodide.setStderr({ batched: (line) => write(line + "\n") });
    pyodide.runPython(driver);
    runner = pyodide.globals.get("_margin_run");
    self.postMessage({ type: "ready", version: String(pyodide.version || "") });
  } catch (err) {
    self.postMessage({ type: "boot-error", stage: "load", message: errorText(err) });
  }
}

async function run(msg) {
  jobID = msg.id;
  buffer = "";
  total = 0;
  lastFlush = Date.now();
  if (msg.packages) {
    // Fetches packages the program imports that aren't in the standard library (numpy…).
    try {
      await pyodide.loadPackagesFromImports(msg.code, { messageCallback: () => {}, errorCallback: () => {} });
    } catch (err) {}
  }
  self.postMessage({ type: "started", id: msg.id });
  let error = null;
  let fatal = false;
  try {
    const result = runner(msg.code, msg.stdin, writeOutput);
    if (typeof result === "string") error = result;
  } catch (err) {
    error = "InternalError: " + errorText(err);
    fatal = true;
  }
  flush(true);
  self.postMessage({ type: "done", id: msg.id, error: error, fatal: fatal, capped: total >= OUTPUT_CAP });
}

self.onmessage = (event) => {
  const msg = event.data;
  if (msg.type === "boot") boot(msg.indexURL, msg.driver);
  else if (msg.type === "run") run(msg);
};
"""#

    /// The page script: owns the worker, the run queue and the timeouts.
    static let script = #"""
"use strict";
(function () {
  const WORKER_SOURCE = document.getElementById("margin-worker").textContent;
  const DRIVER = document.getElementById("margin-driver").textContent;
  const OUTPUT_LIMIT = 100000;
  let indexURL = "";
  let worker = null;
  let booting = null;
  let current = null;
  let queue = Promise.resolve();
  let nextID = 1;

  function startWorker() {
    const url = URL.createObjectURL(new Blob([WORKER_SOURCE], { type: "text/javascript" }));
    const w = new Worker(url);
    worker = w;
    const promise = new Promise((resolve) => {
      let settled = false;
      const timer = setTimeout(() => settle({ ok: false, reason: "timeout", message: "Python took too long to start." }), 120000);
      function settle(result) {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (!result.ok) {
          result.online = navigator.onLine;
          if (worker === w) { w.terminate(); worker = null; booting = null; }
        }
        resolve(result);
      }
      w.onmessage = (event) => {
        const m = event.data;
        if (m.type === "ready") settle({ ok: true, version: m.version });
        else if (m.type === "boot-error") settle({ ok: false, reason: m.stage, message: m.message });
        else onJobMessage(w, m);
      };
      w.onerror = (event) => {
        const message = (event && event.message) ? String(event.message) : "The Python worker stopped.";
        if (event && event.preventDefault) event.preventDefault();
        settle({ ok: false, reason: "crash", message: message });
        if (current && current.worker === w) {
          if (worker === w) { w.terminate(); worker = null; booting = null; }
          finish(current, "crashed", message, false);
        }
      };
      w.postMessage({ type: "boot", indexURL: indexURL, driver: DRIVER });
    });
    booting = promise;
    return promise;
  }

  function ensureWorker() {
    if (worker && booting) return booting;
    return startWorker();
  }

  function killWorker() {
    if (worker) worker.terminate();
    worker = null;
    booting = null;
  }

  function warmUp() {
    setTimeout(() => { if (!worker) ensureWorker(); }, 0);
  }

  function onJobMessage(w, m) {
    const job = current;
    if (!job || job.worker !== w || m.id !== job.id) return;
    if (m.type === "output") {
      if (job.output.length + m.text.length > OUTPUT_LIMIT) {
        job.output = (job.output + m.text).slice(0, OUTPUT_LIMIT);
        job.truncated = true;
      } else {
        job.output += m.text;
      }
    } else if (m.type === "started") {
      job.startedAt = Date.now();
      job.timer = setTimeout(() => timeOut(job), job.timeoutMs);
    } else if (m.type === "done") {
      if (m.fatal) { killWorker(); warmUp(); }
      finish(job, m.error ? "error" : "ok", m.error || "", !!m.capped);
    }
  }

  function timeOut(job) {
    if (current !== job || job.done) return;
    killWorker();
    finish(job, "timeout", "", false);
    warmUp();
  }

  function finish(job, status, error, capped) {
    if (job.done) return;
    job.done = true;
    clearTimeout(job.timer);
    clearTimeout(job.guard);
    if (current === job) current = null;
    job.resolve({
      status: status,
      output: job.output,
      error: error || "",
      message: status === "crashed" ? (error || "") : "",
      truncated: !!(job.truncated || capped),
      ms: job.startedAt ? Date.now() - job.startedAt : 0
    });
  }

  function runOne(code, stdin, timeoutMs) {
    return ensureWorker().then((boot) => {
      if (!boot.ok) {
        return { status: "unavailable", reason: boot.reason || "", message: boot.message || "", online: !!boot.online,
                 output: "", error: "", truncated: false, ms: 0 };
      }
      return new Promise((resolve) => {
        const job = { id: nextID++, worker: worker, output: "", truncated: false, resolve: resolve, timeoutMs: timeoutMs,
                      startedAt: 0, done: false, timer: null, guard: null };
        current = job;
        // In case the worker never reports back (stuck fetching a package): give up eventually.
        job.guard = setTimeout(() => timeOut(job), timeoutMs + 90000);
        worker.postMessage({ type: "run", id: job.id, code: code, stdin: stdin, packages: true });
      });
    });
  }

  window.marginBoot = function (url) {
    if (url) indexURL = url;
    return ensureWorker().then((r) => r, (err) => ({ ok: false, reason: "exception", message: String(err), online: navigator.onLine }));
  };

  window.marginRun = function (url, code, stdin, timeoutMs) {
    if (url) indexURL = url;
    const p = queue.then(() => runOne(String(code), String(stdin), Math.max(1000, Number(timeoutMs) || 10000)))
      .then((r) => r, (err) => ({ status: "crashed", message: String(err), output: "", error: String(err), truncated: false, ms: 0 }));
    queue = p.then(() => {}, () => {});
    return p;
  };

  window.marginCancel = function () {
    const job = current;
    if (!job) return { cancelled: false };
    killWorker();
    finish(job, "cancelled", "", false);
    warmUp();
    return { cancelled: true };
  };

  window.marginState = function () {
    return { hasWorker: !!worker, running: !!current };
  };
})();
"""#

    /// The whole page. Worker and driver sources sit in text/plain script tags (never run by the
    /// page itself); neither contains "</script".
    static var html: String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Python</title></head>
        <body>
        <script id="margin-driver" type="text/plain">
        \(driver)
        </script>
        <script id="margin-worker" type="text/plain">
        \(worker)
        </script>
        <script>
        \(script)
        </script>
        </body></html>
        """
    }
}
