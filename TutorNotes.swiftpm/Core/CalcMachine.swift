import Foundation

// The fx-82AU PLUS II as a key-driven state machine: every key press goes through `press`, and
// `display` describes the screen. Memory (A–F, M, X, Y, Ans), setup, history and STAT data persist
// through `memory`, like the real calculator keeping them when switched off.

enum CalcKey: String, CaseIterable, Codable {
    case shift, alpha, left, right, up, down, mode, on
    case inverse, logBase
    case fraction, sqrt, square, power, log, ln
    case negative, dms, hyp, sin, cos, tan
    case rcl, eng, openParen, closeParen, sd, mPlus
    case d7, d8, d9, del, ac
    case d4, d5, d6, times, divide
    case d1, d2, d3, plus, minus
    case d0, point, exp, ans, equals

    var digit: Int? {
        switch self {
        case .d0: return 0
        case .d1: return 1
        case .d2: return 2
        case .d3: return 3
        case .d4: return 4
        case .d5: return 5
        case .d6: return 6
        case .d7: return 7
        case .d8: return 8
        case .d9: return 9
        default: return nil
        }
    }

    /// The memory letter printed (in red) above the key.
    var variable: String? {
        switch self {
        case .negative: return "A"
        case .dms: return "B"
        case .hyp: return "C"
        case .sin: return "D"
        case .cos: return "E"
        case .tan: return "F"
        case .closeParen: return "X"
        case .sd: return "Y"
        case .mPlus: return "M"
        default: return nil
        }
    }
}

enum CalcMode: String, Codable {
    case comp, stat, verif
}

struct CalcSettings: Codable, Equatable {
    var io: CalcIOMode = .lineO
    var angle: CalcAngle = .deg
    var format: CalcNumberFormat = .norm(2)
    var fractions: CalcFractionStyle = .improper
    var statFrequency = false
    var comma = false
    /// LCD contrast, 0…1.
    var contrast = 0.5

    var display: CalcDisplayOptions { CalcDisplayOptions(format: format, io: io, fractions: fractions) }
}

struct CalcHistoryItem: Codable, Hashable {
    var input: CalcLine
    var value: CalcValue
    /// For results that aren't a single number (TRUE/FALSE, Pol/Rec pairs).
    var special: CalcLine?
}

/// What survives switching off: setup, mode, memories, history and STAT data.
struct CalcMemory: Codable, Equatable {
    var settings = CalcSettings()
    var mode: CalcMode = .comp
    var statType: CalcStatType = .oneVar
    var variables: [String: CalcValue] = [:]
    var ans: CalcValue = .zero
    var history: [CalcHistoryItem] = []
    var statRows: [CalcStatRow] = []
}

enum CalcMenu: Equatable {
    case mode, setup1, setup2, mthIO, fix, sci, norm, statFrequency, disp, contrast
    case drg, hyp, clr, verify, statType, statEdit
    case statMain, statSum, statVar, statReg, statMinMax
    case clearConfirm(Int)
}

/// The screen, for the renderer.
struct CalcDisplay: Equatable {
    struct Indicators: Equatable {
        var shift = false, alpha = false, memory = false, sto = false, rcl = false, stat = false
        var angle: CalcAngle = .deg
        var fix = false, sci = false, math = false
        var historyUp = false, historyDown = false
    }

    struct StatTable: Equatable {
        var columns: [String]
        /// Visible rows: row number and cell texts.
        var rows: [(Int, [String])]
        var cursorRow: Int
        var cursorColumn: Int
        var cellInput: CalcLine?
        var cellCursor: CalcCursor?

        static func == (a: StatTable, b: StatTable) -> Bool {
            a.columns == b.columns && a.rows.map(\.0) == b.rows.map(\.0) && a.rows.map(\.1) == b.rows.map(\.1)
                && a.cursorRow == b.cursorRow && a.cursorColumn == b.cursorColumn && a.cellInput == b.cellInput && a.cellCursor == b.cellCursor
        }
    }

    enum Content: Equatable {
        case calc(input: CalcLine, cursor: CalcCursor?, result: CalcLine?, naturalInput: Bool, naturalOutput: Bool)
        case menu(items: [String], columns: Int)
        case message([String])
        case statEditor(StatTable)
    }

    var indicators = Indicators()
    var content: Content
    var contrast: Double
}

struct CalcMachine {
    var memory = CalcMemory()

    private var shift = false
    private var alpha = false
    private var pendingStore = false
    private var pendingRecall = false
    private(set) var editor = CalcEditor()
    private var result: ResultState?
    private var error: CalcError?
    private var menu: CalcMenu?
    /// Index into history while browsing with ▲▼ (0 is the newest).
    private var historyIndex: Int?
    private var inStatEditor = false
    private var statCursor = (row: 0, column: 0)
    private var cellEditor: CalcEditor?
    /// Where the STAT menu was opened from (the editor shows an extra Edit item).
    private var statMenuFromEditor = false
    var random: () -> Double = { Double.random(in: 0..<1) }

    private struct ResultState {
        var value: CalcValue
        var special: CalcLine?
        var decimal = false
        var eng: Int?
        var dms = false
        var fractions: CalcFractionStyle?
        var alternate: CalcValue?
        var factor: CalcLine?
    }

    init(memory: CalcMemory = CalcMemory()) {
        self.memory = memory
        if memory.mode == .stat { inStatEditor = true }
    }

    enum Effect { case switchOff }

    // MARK: Display

    var display: CalcDisplay {
        var ind = CalcDisplay.Indicators()
        ind.shift = shift
        ind.alpha = alpha
        ind.memory = !(memory.variables["M"]?.isZero ?? true)
        ind.sto = pendingStore
        ind.rcl = pendingRecall
        ind.stat = memory.mode == .stat
        ind.angle = memory.settings.angle
        if case .fix = memory.settings.format { ind.fix = true }
        if case .sci = memory.settings.format { ind.sci = true }
        ind.math = memory.settings.io.naturalInput
        if result != nil || (editor.line.isEmpty && menu == nil) {
            let idx = historyIndex ?? -1
            ind.historyUp = idx + 1 < memory.history.count
            ind.historyDown = idx > 0
        }
        return CalcDisplay(indicators: ind, content: content, contrast: memory.settings.contrast)
    }

    private var content: CalcDisplay.Content {
        if let error {
            return .message([error.message, "[AC] :Cancel", "[◀][▶]:Goto"])
        }
        if let menu { return menuContent(menu) }
        if inStatEditor { return .statEditor(statTable) }
        return .calc(input: editor.line, cursor: result == nil ? editor.cursor : nil, result: resultLine,
                     naturalInput: memory.settings.io.naturalInput, naturalOutput: memory.settings.io.naturalOutput)
    }

    private var resultLine: CalcLine? {
        guard let r = result else { return nil }
        if let f = r.factor { return f }
        if let s = r.special { return s }
        var options = memory.settings.display
        if let f = r.fractions { options.fractions = f }
        let line = CalcFormat.line(r.alternate ?? r.value, options: options, decimal: r.decimal, eng: r.eng, dms: r.dms)
        guard memory.settings.comma else { return line }
        return CalcLine(line.nodes.map { $0 == .token(.point) ? .token(.text(",")) : $0 })
    }

    /// The calculation on screen, for putting on the page: input and result, with the result in
    /// textbook form (fractions and surds) whatever the display setting.
    var currentCalculation: (input: CalcLine, result: CalcLine)? {
        guard let r = result, error == nil, menu == nil, !inStatEditor, !editor.line.isEmpty else { return nil }
        if let line = r.factor ?? r.special { return (editor.line, line) }
        var options = memory.settings.display
        options.io = .mathO
        if let f = r.fractions { options.fractions = f }
        return (editor.line, CalcFormat.line(r.alternate ?? r.value, options: options, decimal: r.decimal, eng: r.eng, dms: r.dms))
    }

    // MARK: Keys

    @discardableResult
    mutating func press(_ key: CalcKey) -> Effect? {
        if key == .shift { shift.toggle(); alpha = false; return nil }
        if key == .alpha { alpha.toggle(); shift = false; return nil }
        let (s, a) = (shift, alpha)
        shift = false
        alpha = false

        if key == .ac && s { return .switchOff }
        if key == .on {
            error = nil; menu = nil; pendingStore = false; pendingRecall = false
            clearCalc()
            return nil
        }
        if error != nil {
            switch key {
            case .ac: error = nil; clearCalc()
            case .left, .right: error = nil; result = nil; editor.moveToEnd()
            default: break
            }
            return nil
        }
        if let menu {
            handleMenu(menu, key: key, shift: s)
            return nil
        }
        if key == .mode {
            menu = s ? .setup1 : .mode
            return nil
        }
        if inStatEditor {
            handleStatEditor(key, shift: s, alpha: a)
            return nil
        }
        handleCalc(key, shift: s, alpha: a)
        return nil
    }

    private mutating func clearCalc() {
        editor.clear()
        result = nil
        historyIndex = nil
    }

    // MARK: Calc screen

    /// What a key does on the calc screen, after SHIFT/ALPHA.
    private enum Action: Equatable {
        case insert(CalcToken)
        case template(CalcTemplate)
        case left, right, up, down, del, ins, ac, equals
        case rcl, sto, eng, engLeft, sd, fractionToggle, mPlus, mMinus
        case dmsKey, fact, clr, verify, stat, drg, hyp
        case none
    }

    private func action(_ key: CalcKey, shift s: Bool, alpha a: Bool) -> Action {
        if a, let v = key.variable { return .insert(.variable(v)) }
        if let d = key.digit {
            if s {
                switch d {
                case 9: return .clr
                case 6: return .verify
                case 1: return .stat
                case 0: return .insert(.function(.rnd))
                default: return .none
                }
            }
            return .insert(.digit(d))
        }
        switch key {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        case .inverse: return a ? .insert(.colon) : .insert(.postfix(s ? .factorial : .inverse))
        case .logBase: return .template(.logBase)
        case .fraction: return .template(s ? .mixed : .fraction)
        case .sqrt: return .template(s ? .cbrt : .sqrt)
        case .square: return .insert(.postfix(s ? .cube : .square))
        case .power: return .template(s ? .root : .power)
        case .log: return s ? .template(.tenPower) : .insert(.function(.log))
        case .ln: return s ? .template(.ePower) : .insert(.function(.ln))
        case .negative: return .insert(.negative)
        case .dms: return s ? .fact : .dmsKey
        case .hyp: return s ? .template(.abs) : .hyp
        case .sin: return .insert(.function(s ? .asin : .sin))
        case .cos: return .insert(.function(s ? .acos : .cos))
        case .tan: return .insert(.function(s ? .atan : .tan))
        case .rcl: return s ? .sto : .rcl
        case .eng: return s ? .engLeft : .eng
        case .openParen: return s ? .insert(.postfix(.percent)) : .insert(.openParen)
        case .closeParen: return s ? .insert(.comma) : .insert(.closeParen)
        case .sd: return s ? .fractionToggle : .sd
        case .mPlus: return s ? .mMinus : .mPlus
        case .del: return s ? .ins : .del
        case .ac: return .ac
        case .times: return a ? .insert(.function(.gcd)) : .insert(.binary(s ? .nPr : .times))
        case .divide: return a ? .insert(.function(.lcm)) : .insert(.binary(s ? .nCr : .divide))
        case .plus: return s ? .insert(.function(.pol)) : .insert(.binary(.plus))
        case .minus: return s ? .insert(.function(.rec)) : .insert(.binary(.minus))
        case .point:
            if a { return .insert(.function(.ranInt)) }
            return s ? .insert(.ranNum) : .insert(.point)
        case .exp:
            if a { return .insert(.e) }
            return s ? .insert(.pi) : .template(.exp10)
        case .ans: return s ? .drg : .insert(.ans)
        case .equals: return .equals
        default: return .none
        }
    }

    /// Typing one of these straight after a result carries on from Ans.
    private static func continuesFromAns(_ act: Action) -> Bool {
        switch act {
        case .insert(.binary), .insert(.postfix), .template(.power): return true
        default: return false
        }
    }

    private mutating func handleCalc(_ key: CalcKey, shift s: Bool, alpha a: Bool) {
        if pendingStore || pendingRecall {
            let store = pendingStore
            pendingStore = false
            pendingRecall = false
            guard let v = key.variable else { return }
            store ? storeValue(into: v) : recall(v)
            return
        }
        let act = action(key, shift: s, alpha: a)
        switch act {
        case .none, .ins:
            return
        case .ac:
            clearCalc()
        case .equals:
            evaluate()
        case .left, .right:
            if result != nil {
                result = nil
                historyIndex = nil
                if act == .left { editor.moveToEnd() } else { editor.cursor = CalcCursor() }
            } else if act == .left { editor.moveLeft() } else { editor.moveRight() }
        case .up, .down:
            if result == nil, !editor.line.isEmpty {
                _ = editor.moveVertically(up: act == .up)
            } else {
                browseHistory(older: act == .up)
            }
        case .del:
            if result != nil { result = nil; historyIndex = nil; editor.moveToEnd() }
            editor.deleteBackward()
        case .insert(let t):
            beginTyping(act)
            editor.insert(t)
        case .template(let t):
            beginTyping(act)
            editor.insert(t)
        case .rcl:
            pendingRecall = true
        case .sto:
            pendingStore = true
        case .mPlus, .mMinus:
            addToMemory(subtract: act == .mMinus)
        case .eng, .engLeft:
            guard var r = result, r.special == nil else { return }
            r.factor = nil
            r.dms = false
            if let e = r.eng { r.eng = e + (act == .eng ? 1 : -1) } else { r.eng = act == .eng ? 0 : -1 }
            result = r
        case .sd:
            toggleExactDecimal()
        case .fractionToggle:
            guard var r = result, case .rational(let q) = r.alternate ?? r.value, !q.isInteger else { return }
            let current = r.fractions ?? memory.settings.fractions
            r.fractions = current == .mixed ? .improper : .mixed
            r.decimal = false
            result = r
        case .dmsKey:
            if var r = result, r.special == nil {
                r.dms.toggle()
                r.eng = nil
                result = r
            } else {
                beginTyping(act)
                editor.insert(.postfix(.dms))
            }
        case .fact:
            let value = result?.value ?? memory.ans
            guard let n = value.integerValue, let line = CalcFormat.factorLine(n) else {
                error = .math
                return
            }
            if result == nil { result = ResultState(value: value) }
            result?.factor = line
        case .clr: menu = .clr
        case .verify: if memory.mode == .verif { menu = .verify }
        case .stat:
            if memory.mode == .stat { statMenuFromEditor = false; menu = .statMain }
        case .drg: menu = .drg
        case .hyp: menu = .hyp
        }
    }

    /// Starts a new expression after a result (carrying on from Ans for operators).
    private mutating func beginTyping(_ act: Action) {
        let continues = CalcMachine.continuesFromAns(act)
        if result != nil {
            result = nil
            historyIndex = nil
            editor.clear()
            if continues { editor.insert(.ans) }
        } else if editor.line.isEmpty, continues {
            editor.insert(.ans)
        }
    }

    private var evaluator: CalcEvaluator {
        var ev = CalcEvaluator()
        ev.angle = memory.settings.angle
        ev.variables = memory.variables
        ev.ans = memory.ans
        ev.format = memory.settings.format
        ev.random = random
        if memory.mode == .stat {
            let rows = memory.statRows.map { r -> CalcStatRow in
                var row = r
                if !memory.settings.statFrequency { row.freq = 1 }
                return row
            }
            ev.statistics = try? CalcStatistics(type: memory.statType, rows: rows)
        }
        return ev
    }

    private mutating func evaluate() {
        guard !editor.line.isEmpty else { return }
        do {
            let statements = try CalcParser.parseStatements(editor.line)
            var ev = evaluator
            var value = memory.ans
            var special: CalcLine?
            for s in statements {
                special = nil
                if case .relation = s {
                    let ok = try ev.verify(s)
                    value = .int(ok ? 1 : 0)
                    special = .text(ok ? "TRUE" : "FALSE")
                } else {
                    value = try ev.evaluate(s)
                    if let (p, q) = ev.pair {
                        let isPol: Bool
                        if case .function(.pol, _) = s { isPol = true } else { isPol = false }
                        memory.variables["X"] = p
                        memory.variables["Y"] = q
                        special = pairLine(isPol ? ("r=", "θ=") : ("X=", "Y="), p, q)
                    }
                }
                ev.ans = value
            }
            memory.ans = value
            result = ResultState(value: value, special: special)
            memory.history.insert(CalcHistoryItem(input: editor.line, value: value, special: special), at: 0)
            if memory.history.count > 30 { memory.history.removeLast() }
            historyIndex = 0
        } catch let e as CalcError {
            error = e
        } catch {
            self.error = .math
        }
    }

    private func pairLine(_ labels: (String, String), _ p: CalcValue, _ q: CalcValue) -> CalcLine {
        var options = memory.settings.display
        options.io = .lineO
        let a = CalcFormat.line(p, options: options, decimal: true)
        let b = CalcFormat.line(q, options: options, decimal: true)
        return CalcLine([.token(.text(labels.0))] + a.nodes + [.token(.text(", " + labels.1))] + b.nodes)
    }

    private mutating func toggleExactDecimal() {
        guard var r = result, r.special == nil else { return }
        r.eng = nil
        r.dms = false
        r.factor = nil
        if r.value.isExact {
            if CalcFormat.hasExactForm(r.value, options: memory.settings.display) { r.decimal.toggle() }
        } else if r.alternate != nil {
            r.alternate = nil
        } else if let q = CalcRational.approximating(r.value.double), !q.isInteger {
            r.alternate = .rational(q)
        }
        result = r
    }

    private mutating func browseHistory(older: Bool) {
        guard !memory.history.isEmpty else { return }
        var idx = historyIndex ?? -1
        if result == nil && historyIndex == nil { idx = -1 }
        idx += older ? 1 : -1
        guard idx >= 0, idx < memory.history.count else { return }
        historyIndex = idx
        let item = memory.history[idx]
        editor.line = item.input
        editor.moveToEnd()
        result = ResultState(value: item.value, special: item.special)
    }

    /// STO: the expression (or the result on screen, or Ans) goes into a variable.
    private mutating func storeValue(into v: String) {
        let value: CalcValue
        if result == nil && !editor.line.isEmpty {
            evaluate()
            guard error == nil, let r = result else { return }
            value = r.value
        } else {
            value = result?.value ?? memory.ans
            if result == nil { editor.line = CalcLine([.token(.ans)]) }
        }
        memory.variables[v] = value
        editor.line = CalcLine(editor.line.nodes + [.token(.text("→" + v))])
        editor.moveToEnd()
        result = ResultState(value: value)
        historyIndex = nil
    }

    private mutating func recall(_ v: String) {
        let value = memory.variables[v] ?? .zero
        editor.line = CalcLine([.token(.variable(v))])
        editor.moveToEnd()
        result = ResultState(value: value)
        historyIndex = nil
    }

    private mutating func addToMemory(subtract: Bool) {
        var value: CalcValue
        if result == nil && !editor.line.isEmpty {
            evaluate()
            guard error == nil, let r = result else { return }
            value = r.value
        } else {
            value = result?.value ?? memory.ans
            if result == nil { editor.line = CalcLine([.token(.ans)]) }
        }
        do {
            let m = memory.variables["M"] ?? .zero
            memory.variables["M"] = subtract ? try CalcMath.sub(m, value) : try CalcMath.add(m, value)
            memory.ans = value
            editor.line = CalcLine(editor.line.nodes + [.token(.text(subtract ? "M−" : "M+"))])
            if let first = memory.history.first, first.value == value {
                memory.history[0].input = editor.line
            }
            editor.moveToEnd()
            result = ResultState(value: value)
        } catch {
            self.error = .math
        }
    }

    // MARK: Menus

    private func menuContent(_ m: CalcMenu) -> CalcDisplay.Content {
        let paired = memory.statType.isPaired
        switch m {
        case .mode: return .menu(items: ["1:COMP", "2:STAT", "3:VERIF"], columns: 2)
        case .setup1: return .menu(items: ["1:MthIO", "2:LineIO", "3:Deg", "4:Rad", "5:Gra", "6:Fix", "7:Sci", "8:Norm"], columns: 2)
        case .setup2: return .menu(items: ["1:ab/c", "2:d/c", "3:STAT", "4:Disp", "5:◀CONT▶"], columns: 2)
        case .mthIO: return .menu(items: ["1:MathO", "2:LineO"], columns: 1)
        case .fix: return .message(["Fix 0~9?"])
        case .sci: return .message(["Sci 0~9?"])
        case .norm: return .message(["Norm 1~2?"])
        case .statFrequency: return .menu(items: ["Frequency?", "1:ON", "2:OFF"], columns: 1)
        case .disp: return .menu(items: ["1:Dot", "2:Comma"], columns: 1)
        case .contrast: return .message(["CONTRAST", "LIGHT    DARK", "  [◀]    [▶]"])
        case .drg: return .menu(items: ["1:°", "2:r", "3:g"], columns: 3)
        case .hyp: return .menu(items: ["1:sinh", "2:cosh", "3:tanh", "4:sinh⁻¹", "5:cosh⁻¹", "6:tanh⁻¹"], columns: 2)
        case .clr: return .menu(items: ["1:Setup", "2:Memory", "3:All"], columns: 2)
        case .clearConfirm(let k):
            let what = ["Setup", "Memory", "All"][max(0, min(2, k - 1))]
            return .message(["Reset \(what)?", "[=] :Yes", "[AC] :Cancel"])
        case .verify: return .menu(items: CalcRelation.allCases.enumerated().map { "\($0.offset + 1):\($0.element.label)" }, columns: 3)
        case .statType:
            return .menu(items: CalcStatType.allCases.enumerated().map { "\($0.offset + 1):\($0.element.menuLabel)" }, columns: 2)
        case .statEdit: return .menu(items: ["1:Ins", "2:Del-A"], columns: 2)
        case .statMain: return .menu(items: statMainItems.enumerated().map { "\($0.offset + 1):\($0.element)" }, columns: 2)
        case .statSum: return .menu(items: numbered(paired ? [.sumX2, .sumX, .sumY2, .sumY, .sumXY, .sumX3, .sumX2Y, .sumX4] : [.sumX2, .sumX]), columns: 2)
        case .statVar: return .menu(items: numbered(paired ? [.n, .xMean, .sigmaX, .sX, .yMean, .sigmaY, .sY] : [.n, .xMean, .sigmaX, .sX]), columns: 2)
        case .statReg: return .menu(items: numbered(regItems), columns: 2)
        case .statMinMax: return .menu(items: numbered(paired ? [.minX, .maxX, .minY, .maxY] : [.minX, .maxX, .q1, .med, .q3]), columns: 2)
        }
    }

    private func numbered(_ vars: [CalcStatVar]) -> [String] {
        vars.enumerated().map { "\($0.offset + 1):\($0.element.label)" }
    }

    private var statMainItems: [String] {
        var items = ["Type", "Data"]
        if statMenuFromEditor { items.append("Edit") }
        items += ["Sum", "Var"]
        if memory.statType.isPaired { items.append("Reg") }
        items.append("MinMax")
        return items
    }

    private var regItems: [CalcStatVar] {
        memory.statType == .quadratic ? [.regA, .regB, .regC, .xHat1, .xHat2, .yHat] : [.regA, .regB, .regR, .xHat, .yHat]
    }

    private func statVars(for m: CalcMenu) -> [CalcStatVar] {
        let paired = memory.statType.isPaired
        switch m {
        case .statSum: return paired ? [.sumX2, .sumX, .sumY2, .sumY, .sumXY, .sumX3, .sumX2Y, .sumX4] : [.sumX2, .sumX]
        case .statVar: return paired ? [.n, .xMean, .sigmaX, .sX, .yMean, .sigmaY, .sY] : [.n, .xMean, .sigmaX, .sX]
        case .statReg: return regItems
        case .statMinMax: return paired ? [.minX, .maxX, .minY, .maxY] : [.minX, .maxX, .q1, .med, .q3]
        default: return []
        }
    }

    private mutating func handleMenu(_ m: CalcMenu, key: CalcKey, shift s: Bool) {
        if key == .ac {
            menu = nil
            return
        }
        let n = key.digit
        switch m {
        case .mode:
            guard let n, (1...3).contains(n) else { return }
            setMode([.comp, .stat, .verif][n - 1])
        case .setup1:
            if key == .down { menu = .setup2; return }
            guard let n else { return }
            switch n {
            case 1: menu = .mthIO
            case 2: memory.settings.io = .lineIO; settingsChanged()
            case 3: memory.settings.angle = .deg; settingsChanged()
            case 4: memory.settings.angle = .rad; settingsChanged()
            case 5: memory.settings.angle = .gra; settingsChanged()
            case 6: menu = .fix
            case 7: menu = .sci
            case 8: menu = .norm
            default: break
            }
        case .setup2:
            if key == .up { menu = .setup1; return }
            guard let n else { return }
            switch n {
            case 1: memory.settings.fractions = .mixed; settingsChanged()
            case 2: memory.settings.fractions = .improper; settingsChanged()
            case 3: menu = .statFrequency
            case 4: menu = .disp
            case 5: menu = .contrast
            default: break
            }
        case .mthIO:
            guard let n, n == 1 || n == 2 else { return }
            memory.settings.io = n == 1 ? .mathO : .lineO
            settingsChanged()
        case .fix, .sci:
            guard let n else { return }
            memory.settings.format = m == .fix ? .fix(n) : .sci(n)
            settingsChanged()
        case .norm:
            guard let n, n == 1 || n == 2 else { return }
            memory.settings.format = .norm(n)
            settingsChanged()
        case .statFrequency:
            guard let n, n == 1 || n == 2 else { return }
            memory.settings.statFrequency = n == 1
            if memory.mode == .stat { memory.statRows = [] }
            settingsChanged()
        case .disp:
            guard let n, n == 1 || n == 2 else { return }
            memory.settings.comma = n == 2
            settingsChanged()
        case .contrast:
            if key == .left { memory.settings.contrast = max(0, memory.settings.contrast - 0.1) }
            if key == .right { memory.settings.contrast = min(1, memory.settings.contrast + 0.1) }
        case .drg:
            guard let n, (1...3).contains(n) else { return }
            menu = nil
            insertFromMenu(.postfix([.degMark, .radMark, .gradMark][n - 1]))
        case .hyp:
            guard let n, (1...6).contains(n) else { return }
            menu = nil
            insertFromMenu(.function([.sinh, .cosh, .tanh, .asinh, .acosh, .atanh][n - 1]))
        case .verify:
            guard let n, (1...6).contains(n) else { return }
            menu = nil
            insertFromMenu(.relation(CalcRelation.allCases[n - 1]))
        case .clr:
            guard let n, (1...3).contains(n) else { return }
            menu = .clearConfirm(n)
        case .clearConfirm(let k):
            guard key == .equals else { return }
            if k == 1 || k == 3 { memory.settings = CalcSettings() }
            if k == 2 || k == 3 { memory.variables = [:]; memory.ans = .zero }
            if k == 3 { memory.history = []; memory.statRows = []; memory.mode = .comp; inStatEditor = false }
            menu = nil
            clearCalc()
        case .statType:
            guard let n, (1...8).contains(n) else { return }
            let type = CalcStatType.allCases[n - 1]
            if type.isPaired != memory.statType.isPaired { memory.statRows = [] }
            memory.statType = type
            menu = nil
            inStatEditor = true
            statCursor = (0, 0)
            cellEditor = nil
            clearCalc()
        case .statEdit:
            guard let n, n == 1 || n == 2 else { return }
            if n == 1 {
                let row = min(statCursor.row, memory.statRows.count)
                memory.statRows.insert(CalcStatRow(x: 0), at: row)
            } else {
                memory.statRows = []
                statCursor = (0, 0)
            }
            menu = nil
            inStatEditor = true
        case .statMain:
            guard let n, n >= 1, n <= statMainItems.count else { return }
            switch statMainItems[n - 1] {
            case "Type": menu = .statType
            case "Data":
                menu = nil
                inStatEditor = true
                cellEditor = nil
            case "Edit": menu = .statEdit
            case "Sum": menu = .statSum
            case "Var": menu = .statVar
            case "Reg": menu = .statReg
            default: menu = .statMinMax
            }
        case .statSum, .statVar, .statReg, .statMinMax:
            let vars = statVars(for: m)
            guard let n, n >= 1, n <= vars.count else { return }
            menu = nil
            inStatEditor = false
            insertFromMenu(.stat(vars[n - 1]))
        }
    }

    private mutating func insertFromMenu(_ token: CalcToken) {
        if inStatEditor {
            var cell = cellEditor ?? CalcEditor()
            cell.insert(token)
            cellEditor = cell
            return
        }
        beginTyping(.insert(token))
        editor.insert(token)
    }

    private mutating func settingsChanged() {
        menu = nil
        clearCalc()
    }

    private mutating func setMode(_ mode: CalcMode) {
        menu = nil
        clearCalc()
        memory.history = []
        memory.mode = mode
        inStatEditor = false
        if mode == .stat { menu = .statType }
    }

    // MARK: STAT editor

    private var statColumns: [String] {
        var c = ["X"]
        if memory.statType.isPaired { c.append("Y") }
        if memory.settings.statFrequency { c.append("FREQ") }
        return c
    }

    private var statRowLimit: Int {
        switch (memory.statType.isPaired, memory.settings.statFrequency) {
        case (false, false): return 40
        case (false, true): return 20
        case (true, false): return 40
        case (true, true): return 26
        }
    }

    private func cellText(_ row: CalcStatRow, column: Int) -> String {
        let name = statColumns[column]
        let v = name == "X" ? row.x : (name == "Y" ? row.y : row.freq)
        let (mantissa, exponent) = CalcFormat.decimalParts(v, format: .norm(1))
        let text = exponent.map { "\(mantissa)E\($0)" } ?? mantissa
        return text.count > 7 ? String(text.prefix(6)) + "…" : text
    }

    private var statTable: CalcDisplay.StatTable {
        let rows = memory.statRows
        let total = min(rows.count + 1, statRowLimit)
        let first = max(0, min(statCursor.row - 1, total - 3))
        var visible: [(Int, [String])] = []
        for r in first..<min(total, first + 3) {
            let cells = r < rows.count ? statColumns.indices.map { cellText(rows[r], column: $0) } : statColumns.map { _ in "" }
            visible.append((r + 1, cells))
        }
        return CalcDisplay.StatTable(columns: statColumns, rows: visible, cursorRow: statCursor.row + 1,
                                     cursorColumn: statCursor.column, cellInput: cellEditor?.line, cellCursor: cellEditor?.cursor)
    }

    private mutating func handleStatEditor(_ key: CalcKey, shift s: Bool, alpha a: Bool) {
        if s && key == .d1 {
            statMenuFromEditor = true
            menu = .statMain
            return
        }
        let rowCount = memory.statRows.count
        switch key {
        case .ac:
            if cellEditor != nil { cellEditor = nil } else { inStatEditor = false; clearCalc() }
        case .up:
            cellEditor = nil
            statCursor.row = max(0, statCursor.row - 1)
        case .down:
            cellEditor = nil
            statCursor.row = min(min(rowCount, statRowLimit - 1), statCursor.row + 1)
        case .left:
            if var c = cellEditor { c.moveLeft(); cellEditor = c; return }
            statCursor.column = max(0, statCursor.column - 1)
        case .right:
            if var c = cellEditor { c.moveRight(); cellEditor = c; return }
            statCursor.column = min(statColumns.count - 1, statCursor.column + 1)
        case .del:
            if var c = cellEditor {
                c.deleteBackward()
                cellEditor = c
            } else if statCursor.row < rowCount {
                memory.statRows.remove(at: statCursor.row)
            }
        case .equals:
            commitCell()
        default:
            let act = action(key, shift: s, alpha: a)
            var c = cellEditor ?? CalcEditor()
            switch act {
            case .insert(let t): c.insert(t)
            case .template(let t): c.insert(t)
            default: return
            }
            cellEditor = c
        }
    }

    private mutating func commitCell() {
        guard let c = cellEditor, !c.line.isEmpty else { return }
        do {
            var ev = evaluator
            ev.statistics = nil
            let v = try ev.evaluate(try CalcParser.parse(c.line)).double
            let column = statColumns[statCursor.column]
            if column == "FREQ" { guard v >= 0 else { throw CalcError.math } }
            if statCursor.row >= memory.statRows.count {
                guard memory.statRows.count < statRowLimit else { return }
                memory.statRows.append(CalcStatRow(x: 0))
            }
            switch column {
            case "X": memory.statRows[statCursor.row].x = v
            case "Y": memory.statRows[statCursor.row].y = v
            default: memory.statRows[statCursor.row].freq = v
            }
            cellEditor = nil
            statCursor.row = min(statCursor.row + 1, min(memory.statRows.count, statRowLimit - 1))
        } catch let e as CalcError {
            cellEditor = nil
            error = e
        } catch {
            cellEditor = nil
        }
    }
}
