import Foundation

/// Code blocks: the model, highlighting, wrapping and card layout, traceback cleaning, output
/// truncation, the runner page and the editor's indent rules.
func runCodeTests() {
    codeModelTests()
    codeHighlightTests()
    codeWrapTests()
    codeLayoutTests()
    codeTracebackTests()
    codeOutputTests()
    codeRunResultTests()
    codeEditingTests()
    codePageTests()
}

private func spansText(_ line: [CodeSpan]) -> String { line.map(\.text).joined() }
private func kinds(_ line: [CodeSpan], _ kind: CodeTokenKind) -> [String] { line.filter { $0.kind == kind }.map(\.text) }

private func codeModelTests() {
    // Old notes (the stub stored language, code and output only) still decode.
    let old = #"{"language":"python","code":"print(1)","output":"1\n"}"#
    let decoded = try? JSONDecoder().decode(CodeContent.self, from: Data(old.utf8))
    check(decoded?.code == "print(1)" && decoded?.output == "1\n" && decoded?.title == nil && decoded?.hasRun == true, "old code block decodes")
    let minimal = try? JSONDecoder().decode(CodeContent.self, from: Data(#"{"code":"x = 1"}"#.utf8))
    check(minimal?.lang == .python && minimal?.hasRun == false, "code-only block decodes with defaults")
    let empty = CodeContent(code: "")
    check(empty.language == "python" && empty.lang.isRunnable && !empty.hasRun, "CodeContent(code:) defaults")

    var c = CodeContent(language: "pseudocode", code: "BEGIN\nEND", title: "  Max  ", stdin: "3\n4\n")
    c.ranAt = Date(timeIntervalSince1970: 1_800_000_000)
    c.error = "x"
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    let round = try? dec.decode(CodeContent.self, from: enc.encode(c))
    check(round == c, "round trip")
    check(c.displayTitle == "Max" && !c.isRunnable && c.errored, "title, pseudocode, errored")
    check(c.stdinLines == ["3", "4"], "stdin lines drop final newline: \(c.stdinLines)")
    check(CodeText.inputLines("a\n\nb") == ["a", "", "b"], "blank input lines kept")
    check(CodeText.inputLines("a\r\nb\r\n") == ["a", "b"], "CRLF input")
    check(CodeText.stdinText(["a", "b"]) == "a\nb\n", "stdin text")
    check(c.clearingRun().hasRun == false, "clearing run")
    check(CodeLanguage(loose: "Pseudo-code") == .pseudocode && CodeLanguage(loose: "PYTHON") == .python && CodeLanguage(loose: nil) == .python, "loose language")
    check(CodeText.expandTabs("\tx\ty") == "    x   y", "tab expansion: \(CodeText.expandTabs("\tx\ty"))")
    check(CodeText.indentWidth("\t  x") == 6, "indent width")
    check(CodeText.lines("a\r\nb\rc") == ["a", "b", "c"], "line endings")
}

private func codeHighlightTests() {
    let src = """
    @dataclass
    def add(a, b=2):  # sum
        return a + b * 3.5e2 if a else None
    name = input(f"Hi {user.name!r}, {{literal}} ") + r'\\d' + b"x"
    print(len("it's"), 0x1F, x1)
    class Point:
        s = \"\"\"multi
    line # not a comment
    end\"\"\" + 'tail'
    """
    let hl = CodeHighlighter.highlight(src, language: .python)
    let lines = src.components(separatedBy: "\n")
    check(hl.count == lines.count, "one span list per line")
    for (i, l) in hl.enumerated() { check(spansText(l) == lines[i], "line \(i + 1) spans rebuild the line") }
    check(kinds(hl[0], .decorator) == ["@dataclass"], "decorator \(hl[0])")
    check(kinds(hl[1], .keyword) == ["def"] && kinds(hl[1], .definition) == ["add"], "def + name \(hl[1])")
    check(kinds(hl[1], .comment) == ["# sum"] && kinds(hl[1], .number) == ["2"], "comment, default number")
    check(kinds(hl[2], .keyword) == ["return", "if", "else"] && kinds(hl[2], .constant) == ["None"], "keywords and None \(hl[2])")
    check(kinds(hl[2], .number) == ["3.5e2"], "float with exponent \(kinds(hl[2], .number))")
    check(kinds(hl[3], .builtin) == ["input"], "builtin input \(hl[3])")
    let strings3 = kinds(hl[3], .string)
    check(strings3.first == "f\"Hi " && strings3.contains(", {{literal}} \"") && strings3.contains("r'\\d'") && strings3.contains("b\"x\""),
          "f-string, raw and bytes strings \(strings3)")
    check(kinds(hl[3], .plain).contains("{user.name!r}"), "f-string field is code, not string \(hl[3])")
    check(kinds(hl[4], .string) == ["\"it's\""] && kinds(hl[4], .number) == ["0x1F"] && kinds(hl[4], .builtin) == ["print", "len"],
          "apostrophe inside string, hex, no number in x1 \(hl[4])")
    check(kinds(hl[5], .definition) == ["Point"], "class name")
    check(hl[7].allSatisfy { $0.kind == .string }, "triple-quoted string continues across lines \(hl[7])")
    check(kinds(hl[8], .string) == ["end\"\"\"", "'tail'"], "triple string closes, then a new string \(hl[8])")
    let method = CodeHighlighter.highlight("obj.print(x)", language: .python)[0]
    check(kinds(method, .builtin).isEmpty, "attribute named like a builtin isn't a builtin")
    let unterminated = CodeHighlighter.highlight("s = 'abc\nx = 1", language: .python)
    check(kinds(unterminated[1], .string).isEmpty, "unterminated single-quoted string ends at the line")
    let matmul = CodeHighlighter.highlight("c = a @ b", language: .python)[0]
    check(kinds(matmul, .decorator).isEmpty, "@ mid-line is an operator")

    let pseudo = """
    BEGIN MaxOfTwo
        GET num1
        IF num1 > 10 THEN
            Display "big" // comment
        ENDIF
        FOR i = 1 TO 10 STEP 2
        NEXT i
        total = count and next
    END MaxOfTwo
    """
    let ph = CodeHighlighter.highlight(pseudo, language: .pseudocode)
    check(kinds(ph[0], .keyword) == ["BEGIN"], "BEGIN")
    check(kinds(ph[2], .keyword) == ["IF", "THEN"] && kinds(ph[2], .number) == ["10"], "IF THEN \(ph[2])")
    check(kinds(ph[3], .keyword) == ["Display"] && kinds(ph[3], .string) == ["\"big\""] && kinds(ph[3], .comment) == ["// comment"], "Display, string, comment")
    check(kinds(ph[5], .keyword) == ["FOR", "TO", "STEP"], "FOR TO STEP \(ph[5])")
    check(kinds(ph[7], .keyword).isEmpty, "lowercase short words are variables \(ph[7])")
    for (i, l) in ph.enumerated() { check(spansText(l) == pseudo.components(separatedBy: "\n")[i], "pseudocode line \(i + 1) rebuilds") }

    // UTF-16 runs for the editor line up with the text.
    let text = "x = \"é😀\"  # ok\nprint(x)"
    let ns = text as NSString
    let runs = CodeHighlighter.utf16Runs(text, language: .python)
    let byKind = Dictionary(grouping: runs, by: { $0.kind }).mapValues { $0.map { ns.substring(with: NSRange(location: $0.location, length: $0.length)) } }
    check(byKind[.string] == ["\"é😀\""] && byKind[.comment] == ["# ok"] && byKind[.builtin] == ["print"], "utf16 runs \(byKind)")
}

private func codeWrapTests() {
    func rows(_ s: String, _ cols: Int) -> [String] {
        let chars = Array(s)
        return CodeWrap.wrap(chars, maxColumns: cols).map { String(repeating: " ", count: $0.indent) + String(chars[$0.start..<$0.end]) }
    }
    check(rows("short", 20) == ["short"], "no wrap")
    check(rows("", 20) == [""], "empty line is one row")
    let r = rows("    total = first_value + second_value + third", 24)
    check(r.count == 3, "wrapped rows \(r)")
    check(r.allSatisfy { CodeWrap.columns($0) <= 24 }, "rows fit \(r)")
    check(r[1].hasPrefix(String(repeating: " ", count: 8)) && !r[1].hasPrefix(String(repeating: " ", count: 9)), "continuation indent = indent + 4 \(r)")
    check(r[0].hasSuffix(" "), "breaks after a space \(r)")
    let joined = CodeWrap.wrap(Array("    total = first_value + second_value + third"), maxColumns: 24)
    check(joined.first?.start == 0 && joined.last?.end == 46 && zip(joined, joined.dropFirst()).allSatisfy { $0.end == $1.start }, "rows cover the line")
    let hard = rows(String(repeating: "x", count: 50), 20)
    check(hard.count == 3 && hard[0].count == 20 && hard[1] == "    " + String(repeating: "x", count: 16), "hard wrap \(hard)")
    check(CodeWrap.columns(Character("中")) == 2 && CodeWrap.columns(Character("😀")) == 2 && CodeWrap.columns(Character("é")) == 1, "wide columns")
    let wide = rows(String(repeating: "中", count: 15), 20)
    check(wide.allSatisfy { CodeWrap.columns($0) <= 20 }, "wide characters fit \(wide)")
    let tiny = CodeWrap.wrap(Array("abcdef"), maxColumns: 1)
    check(tiny.count == 6, "1-column wrap terminates")
    let narrow = CodeWrap.wrap(Array("        deep indentation wraps here"), maxColumns: 10)
    check(narrow.allSatisfy { $0.indent == 0 }, "no continuation indent when very narrow")
}

private func codeLayoutTests() {
    let m = CodeCardMetrics(charWidth: 8, lineHeight: 20, outputCharWidth: 8, outputLineHeight: 18)
    let code = "for i in range(3):\n    print(\"a fairly long line that will certainly need to wrap around\", i)\nprint(\"done\")"
    let c = CodeContent(code: code)
    let w: CGFloat = 400
    let l = CodeCardLayout(c, width: w, metrics: m)
    check(l.gutterWidth == 16 && l.codeX == 12 + 16 + 12, "gutter \(l.gutterWidth) codeX \(l.codeX)")
    check(l.codeColumns == Int((400 - 40 - 12) / 8), "columns \(l.codeColumns)")
    check(l.lines.count == 3 && l.rowCount(ofLine: 0) == 1 && l.rowCount(ofLine: 1) == 2 && l.rowCount(ofLine: 2) == 1, "row counts")
    check(l.lineTop(0) == CodeCardMetrics.headerHeight + CodeCardMetrics.codeTopPadding, "first line top")
    check(l.lineTop(2) == l.lineTop(0) + 3 * 20, "third line after a wrapped line")
    check(l.outputRows == [CodeCardLayout.OutputRow(text: "", style: .notRun)], "not run yet row")
    let expected = (l.lineTop(0) + 4 * 20 + CodeCardMetrics.codeBottomPadding + CodeCardMetrics.outputLabelHeight + 18 + CodeCardMetrics.outputBottomPadding).rounded(.up)
    check(l.height == expected, "height \(l.height) vs \(expected)")
    // Wider card: no wrapping, shorter.
    check(CodeCardLayout(c, width: 900, metrics: m).height == l.height - 20, "height follows width")
    // Pseudocode has no output panel.
    let p = CodeCardLayout(CodeContent(language: "pseudocode", code: "BEGIN\nEND"), width: 400, metrics: m)
    check(p.outputTop == nil && p.outputRows.isEmpty && p.height == (p.lineTop(0) + 40 + CodeCardMetrics.codeBottomPadding).rounded(.up), "pseudocode layout")
    // Empty code still has one row.
    check(CodeCardLayout(CodeContent(code: ""), width: 300, metrics: m).rows.count == 1, "empty code one row")
    // Gutter grows past 99 lines.
    let many = CodeCardLayout(CodeContent(code: Array(repeating: "x", count: 120).joined(separator: "\n")), width: 400, metrics: m)
    check(many.gutterWidth == 24, "3-digit gutter")

    // Output rows: run with output and an error.
    var ran = c
    ran.ranAt = Date()
    ran.output = "a 0\na 1\n"
    ran.error = "Traceback (most recent call last):\n  Line 2\n    print(x)\nNameError: name 'x' is not defined"
    let o = CodeCardLayout(ran, width: 400, metrics: m)
    check(o.outputRows.count == 6 && o.outputRows[0] == .init(text: "a 0", style: .normal) && o.outputRows.last?.style == .error, "output rows \(o.outputRows)")
    check(o.height == (o.outputTextTop + 6 * 18 + CodeCardMetrics.outputBottomPadding).rounded(.up), "output height")
    ran.output = nil
    ran.error = nil
    check(CodeCardLayout(ran, width: 400, metrics: m).outputRows == [.init(text: "", style: .noOutput)], "ran with no output")
    // Long output is cut to maxOutputRows, keeping the error's last rows.
    ran.output = (1...40).map { "line \($0)" }.joined(separator: "\n")
    ran.error = "Traceback (most recent call last):\n  Line 9\n    boom()\nValueError: bad"
    let cut = CodeCardLayout(ran, width: 400, metrics: m).outputRows
    check(cut.count == CodeCardMetrics.maxOutputRows, "capped rows \(cut.count)")
    check(cut.first?.text == "line 1" && cut.last?.text == "ValueError: bad", "keeps head of output and the error")
    if let more = cut.first(where: { if case .more = $0.style { return true }; return false }), case .more(let n) = more.style {
        check(n == 40 + 4 - (CodeCardMetrics.maxOutputRows - 1), "more count \(n)")
    } else { check(false, "has a more row") }
    let fitted = CodeCardLayout.fit([], (1...30).map { .init(text: "e\($0)", style: .error) }, limit: 14)
    check(fitted.count == 14 && fitted.last?.text == "e30", "error-only fit")
    // Long output lines wrap without continuation indent.
    ran.error = nil
    ran.output = String(repeating: "y", count: 100)
    let wrapped = CodeCardLayout(ran, width: 400, metrics: m)
    check(wrapped.outputRows.count == Int((100 + wrapped.outputColumns - 1) / wrapped.outputColumns), "output wraps \(wrapped.outputRows.count)")

    let pos = l.linePositions(origin: CGPoint(x: 100, y: 200))
    check(pos.contains("1:\(Int(200 + l.lineTop(0)))") && pos.contains("2:\(Int(200 + l.lineTop(1))) (wraps to 2 rows)") && pos.contains("x=140"), "line positions: \(pos)")
}

private func codeTracebackTests() {
    let nameError = """
    Traceback (most recent call last):
      File "<exec>", line 55, in _margin_run
      File "main.py", line 4, in <module>
        print(totl)
              ^^^^
    NameError: name 'totl' is not defined. Did you mean: 'total'?

    """
    let n = CodeTraceback.clean(nameError)
    check(n == "Traceback (most recent call last):\n  Line 4\n    print(totl)\n          ^^^^\nNameError: name 'totl' is not defined. Did you mean: 'total'?",
          "name error cleaned:\n\(n)")
    let s = CodeTraceback.summary(n)
    check(s.line == 4 && s.message.hasPrefix("NameError: name 'totl'"), "summary \(s)")

    let zeroDiv = """
    Traceback (most recent call last):
      File "<exec>", line 55, in _margin_run
      File "main.py", line 5, in <module>
        print(average([]))
              ~~~~~~~^^^^
      File "main.py", line 2, in average
        return sum(xs) / len(xs)
               ~~~~~~~~^~~~~~~~~
    ZeroDivisionError: division by zero
    """
    let z = CodeTraceback.clean(zeroDiv)
    check(z == "Traceback (most recent call last):\n  Line 5\n    print(average([]))\n  Line 2, in average\n    return sum(xs) / len(xs)\nZeroDivisionError: division by zero",
          "zero division cleaned:\n\(z)")
    check(CodeTraceback.summary(z).line == 2, "innermost frame line")

    let syntax = """
    Traceback (most recent call last):
      File "<exec>", line 55, in _margin_run
      File "main.py", line 1
        print("hi"
             ^
    SyntaxError: '(' was never closed
    """
    let sy = CodeTraceback.clean(syntax)
    check(sy == "  Line 1\n    print(\"hi\"\n         ^\nSyntaxError: '(' was never closed", "syntax error cleaned (no header, caret kept):\n\(sy)")
    check(CodeTraceback.summary(sy) == ("SyntaxError: '(' was never closed", 1), "syntax summary")

    let eof = """
    Traceback (most recent call last):
      File "<exec>", line 55, in _margin_run
      File "main.py", line 2, in <module>
        b = input("Second: ")
      File "<exec>", line 15, in __call__
    EOFError: input() ran out of program input. Add another line under Program input (one line for each input() call).
    """
    let e = CodeTraceback.clean(eof)
    check(e == "Traceback (most recent call last):\n  Line 2\n    b = input(\"Second: \")\nEOFError: input() ran out of program input. Add another line under Program input (one line for each input() call).",
          "runner frames dropped:\n\(e)")

    let chained = """
    Traceback (most recent call last):
      File "main.py", line 2, in <module>
        int("x")
        ~~~^^^^^
    ValueError: invalid literal for int() with base 10: 'x'

    During handling of the above exception, another exception occurred:

    Traceback (most recent call last):
      File "<exec>", line 55, in _margin_run
      File "main.py", line 4, in <module>
        raise RuntimeError("bad number")
    RuntimeError: bad number
    """
    let ch = CodeTraceback.clean(chained)
    check(ch.components(separatedBy: "Traceback (most recent call last):").count == 3 && ch.contains("During handling") && ch.hasSuffix("RuntimeError: bad number")
          && !ch.contains("<exec>") && !ch.contains("~"), "chained:\n\(ch)")
    check(CodeTraceback.summary(ch).message == "RuntimeError: bad number", "chained summary")

    let recursion = """
    Traceback (most recent call last):
      File "<exec>", line 55, in _margin_run
      File "main.py", line 3, in <module>
        f(0)
        ~^^^
      File "main.py", line 2, in f
        return f(n + 1)
      [Previous line repeated 995 more times]
    RecursionError: maximum recursion depth exceeded
    """
    let rc = CodeTraceback.clean(recursion)
    check(rc == "Traceback (most recent call last):\n  Line 3\n    f(0)\n  Line 2, in f\n    return f(n + 1)\n  [Previous line repeated 995 more times]\nRecursionError: maximum recursion depth exceeded",
          "recursion:\n\(rc)")

    let turtle = "Traceback (most recent call last):\n  File \"<exec>\", line 55, in _margin_run\n  File \"main.py\", line 1, in <module>\n    import turtle\nModuleNotFoundError: No module named 'turtle'\n"
    let t = CodeTraceback.clean(turtle)
    check(t.hasSuffix("(Turtle graphics and windows can't open inside a code block: there's no screen to draw on here.)"), "turtle hint")
    check(CodeTraceback.summary(t).message == "ModuleNotFoundError: No module named 'turtle'", "hint isn't the summary")

    let internalOnly = "Traceback (most recent call last):\n  File \"/lib/python313.zip/_pyodide/_base.py\", line 573, in eval_code\n    x\nKeyboardInterrupt"
    check(CodeTraceback.clean(internalOnly) == "KeyboardInterrupt", "internal-only traceback")
    check(CodeTraceback.parseFrame("  File \"main.py\", line 12, in f")! == ("main.py", 12, "f"), "parse frame")
    check(CodeTraceback.parseFrame("    print(\"File \\\"x\\\"\")") == nil, "source line isn't a frame")
}

private func codeOutputTests() {
    let long = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
    let l = CodeOutputText.limited(long, maxChars: 1000, maxLines: 3)
    check(l.truncated && l.text == "line 1\nline 2\nline 3\n… (7 more lines not shown)", "line limit:\n\(l.text)")
    let c = CodeOutputText.limited(String(repeating: "a", count: 50), maxChars: 10, maxLines: 100)
    check(c.truncated && c.text.hasPrefix(String(repeating: "a", count: 10) + "\n…"), "char limit \(c.text)")
    check(CodeOutputText.limited("ok\n", maxChars: 10, maxLines: 10) == ("ok\n", false), "short output unchanged")
    check(CodeOutputText.limited("abc", maxChars: 3, maxLines: 1) == ("abc", false), "exactly at the limit")
    check(CodeOutputText.firstLines("a\nb\nc", 2) == "a\nb\n…", "first lines")
}

private func codeRunResultTests() {
    let ok = CodeRunResult.fromRunner(["status": "ok", "output": "hi\n", "error": "", "truncated": false, "ms": 312.0], timeout: 10)
    check(ok.status == .finished && ok.output == "hi\n" && ok.error == nil && abs(ok.seconds - 0.312) < 1e-9 && ok.ran, "ok result")
    let err = CodeRunResult.fromRunner(["status": "error", "output": "start\n", "error": "Traceback (most recent call last):\n  File \"<exec>\", line 55, in _margin_run\n  File \"main.py\", line 3, in <module>\n    x\nNameError: name 'x' is not defined\n", "ms": 5], timeout: 10)
    check(err.status == .failed && err.error == "Traceback (most recent call last):\n  Line 3\n    x\nNameError: name 'x' is not defined", "error cleaned \(err.error ?? "nil")")
    check(err.headline == "Error on line 3", "headline \(err.headline)")
    let to = CodeRunResult.fromRunner(["status": "timeout", "output": "0\n1\n", "truncated": true], timeout: 10)
    check(to.status == .timedOut && to.error?.hasPrefix("Stopped after 10 seconds") == true && to.output.hasSuffix("… (output cut short)"), "timeout \(to)")
    let un = CodeRunResult.fromRunner(["status": "unavailable", "message": "Load failed", "online": false], timeout: 10)
    check(un.status == .unavailable && !un.ran && un.error == CodeRunResult.unavailableMessage && un.detail == "Load failed", "unavailable")
    check(un.report(subject: "e3", inputLines: 0).contains("internet connection"), "unavailable report")
    let crash = CodeRunResult.fromRunner(["status": "crashed", "message": "Maximum call stack size exceeded"], timeout: 10)
    check(crash.status == .crashed && crash.error?.contains("Maximum call stack") == true, "crashed")
    let weird = CodeRunResult.fromRunner([:], timeout: 10)
    check(weird.status == .crashed, "missing status")

    let rep = err.report(subject: "e5", inputLines: 2)
    check(rep.hasPrefix("Ran e5 with 2 lines of program input. It stopped with an error on line 3: NameError: name 'x' is not defined") && rep.contains("Output before it stopped") && rep.contains("Error:\nTraceback"), "report:\n\(rep)")
    let quiet = CodeRunResult(status: .finished, output: "", seconds: 0.1)
    check(quiet.report(subject: "the snippet", inputLines: 0).contains("It printed nothing."), "quiet report")
    let big = CodeRunResult(status: .finished, output: String(repeating: "x\n", count: 5000))
    check(big.report(subject: "x", inputLines: 0).count < 4_000, "report is capped")

    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let applied = err.applied(to: CodeContent(code: "x"), at: date)
    check(applied.output == "start\n" && applied.error == err.error && applied.ranAt == date, "applied")
    check(ok.applied(to: CodeContent(code: "x", output: "old", error: "old"), at: date).error == nil, "a clean run clears the old error")
    check(CodeRunResult(status: .finished, output: "").applied(to: CodeContent(code: "x"), at: date).output == nil, "empty output stored as nil")
}

private func codeEditingTests() {
    check(CodeEditing.newlineIndent(after: "for i in range(3):", language: .python) == "    ", "indent after colon")
    check(CodeEditing.newlineIndent(after: "    if x == 1:  # check", language: .python) == "        ", "indent after colon with comment")
    check(CodeEditing.newlineIndent(after: "    print(\"a:\")", language: .python) == "    ", "keep indent")
    check(CodeEditing.newlineIndent(after: "print('#:')", language: .python) == "", "colon inside a string doesn't indent")
    check(CodeEditing.newlineIndent(after: "        return total", language: .python) == "    ", "dedent after return")
    check(CodeEditing.newlineIndent(after: "    pass", language: .python) == "", "dedent after pass")
    check(CodeEditing.newlineIndent(after: "\tx = 1", language: .python) == "    ", "tab counts as 4")
    check(CodeEditing.newlineIndent(after: "BEGIN", language: .pseudocode) == "    ", "pseudocode BEGIN")
    check(CodeEditing.newlineIndent(after: "    IF x > 3 THEN", language: .pseudocode) == "        ", "pseudocode IF")
    check(CodeEditing.newlineIndent(after: "    Display x", language: .pseudocode) == "    ", "pseudocode statement")
    check(CodeEditing.dedent("        x") == ("    x", 4), "dedent 4")
    check(CodeEditing.dedent("      x") == ("    x", 2), "dedent to a multiple of 4")
    check(CodeEditing.dedent("x") == ("x", 0), "nothing to dedent")
}

private func codePageTests() {
    let html = CodeRunnerPage.html
    check(html.components(separatedBy: "</script").count - 1 == 3, "three script tags, sources don't close them early")
    check(!CodeRunnerPage.worker.contains("<!--") && !CodeRunnerPage.driver.contains("</"), "raw script text is safe")
    check(CodeRunnerPage.indexURL == "https://cdn.jsdelivr.net/pyodide/v0.29.5/full/", "CDN url")
    check(html.contains("window.marginRun") && html.contains("window.marginBoot") && html.contains("window.marginCancel"), "entry points")
    // The driver's Python starts at column 0 inside the page (it's interpolated, not indented).
    check(html.contains("\nimport sys, io, builtins, traceback, linecache\n") && html.contains("\ndef _margin_run(code, stdin_text, write):\n"), "driver unindented")
}
