import SwiftUI

/// The calculator's state, shared by every note: like a real calculator, its memories, setup and
/// history are kept when it's put away (and across launches).
@MainActor
@Observable
final class CalculatorModel {
    static let shared = CalculatorModel()

    private var machine: CalcMachine
    private(set) var display: CalcDisplay
    private static let storageKey = "calculatorMemory"

    private init() {
        var memory = CalcMemory()
        if let data = UserDefaults.standard.data(forKey: CalculatorModel.storageKey),
           let saved = try? JSONDecoder().decode(CalcMemory.self, from: data) {
            memory = saved
        }
        let m = CalcMachine(memory: memory)
        machine = m
        display = m.display
    }

    /// Returns true when the key switches the calculator off (SHIFT AC).
    func press(_ key: CalcKey) -> Bool {
        let before = machine.memory
        let effect = machine.press(key)
        display = machine.display
        if machine.memory != before, let data = try? JSONEncoder().encode(machine.memory) {
            UserDefaults.standard.set(data, forKey: CalculatorModel.storageKey)
        }
        return effect == .switchOff
    }

    var currentCalculation: (input: CalcLine, result: CalcLine)? { machine.currentCalculation }
}

extension EditorModel {
    /// Puts the calculation on screen onto the page as typeset math ("input = result").
    func insertCalculation(input: CalcLine, result: CalcLine) {
        let latex = CalcLatex.latex(input) + " = " + CalcLatex.latex(result)
        let color = tools.config(settings: AppSettings.shared).penColorHex
        let m = MathContent(lines: [latex], fontSize: 26, colorHex: color)
        insertStudentElement(.math(m), size: ElementRenderer.measureMath(m), actionName: "Insert Calculation")
        flash("Calculation added to the page")
    }
}

// MARK: - Floating panel

/// The calculator floating over the page. Drag it by its top edge; it scales down to fit short
/// windows.
struct CalculatorOverlay: View {
    let model: EditorModel
    @State private var offset: CGSize = CalculatorOverlay.savedOffset
    @State private var dragStart: CGSize?
    private static var savedOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let scale = min(1, (geo.size.height - 24) / CalculatorPanel.height)
            CalculatorPanel(model: model, onDrag: { t in
                let start = dragStart ?? offset
                if dragStart == nil { dragStart = offset }
                offset = CGSize(width: start.width + t.width / scale, height: start.height + t.height / scale)
            }, onDragEnd: {
                dragStart = nil
                offset = clamped(offset, in: geo.size, scale: scale)
                CalculatorOverlay.savedOffset = offset
            })
            .offset(offset)
            .scaleEffect(scale, anchor: .topTrailing)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 12)
            .padding(.trailing, 16)
        }
    }

    /// Keeps most of the calculator on screen. The offset is applied before scaling, so it's in
    /// unscaled points.
    private func clamped(_ o: CGSize, in size: CGSize, scale: CGFloat) -> CGSize {
        let w = CalculatorPanel.width
        let minX = -(size.width / scale - w - 32)
        let maxX = w * 0.6
        let minY: CGFloat = -12
        let maxY = size.height / scale - 120
        return CGSize(width: min(max(o.width, minX), maxX), height: min(max(o.height, minY), maxY))
    }
}

struct CalculatorPanel: View {
    let model: EditorModel
    var onDrag: (CGSize) -> Void = { _ in }
    var onDragEnd: () -> Void = {}

    private let calc = CalculatorModel.shared

    static let width: CGFloat = 340
    static let height: CGFloat = 664

    var body: some View {
        VStack(spacing: 0) {
            header
            LCDScreen(display: calc.display)
                .frame(height: 118)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.55), lineWidth: 3))
                .padding(.horizontal, 18)
                .padding(.top, 4)
            Text("NATURAL DISPLAY")
                .font(.system(size: 8, weight: .heavy))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 20)
                .padding(.top, 5)
            controlCluster
                .padding(.top, 6)
            functionGrid
                .padding(.top, 8)
            numberGrid
                .padding(.top, 12)
        }
        .padding(.bottom, 16)
        .frame(width: CalculatorPanel.width)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "#2B3242"), Color(hex: "#161A24")], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }

    // MARK: Top

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("MARGIN")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.92))
                Text("fx-82 · scientific")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            // Solar cell, for the look.
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(colors: [Color(hex: "#3B2A22"), Color(hex: "#1E1512")], startPoint: .top, endPoint: .bottom))
                .overlay(HStack(spacing: 2) { ForEach(0..<4, id: \.self) { _ in Rectangle().fill(Color.black.opacity(0.35)).frame(width: 1) } })
                .frame(width: 66, height: 18)
            Button {
                if let c = calc.currentCalculation { model.insertCalculation(input: c.input, result: c.result) }
            } label: {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .disabled(calc.currentCalculation == nil)
            .accessibilityLabel("Put this calculation on the page")
            Button { model.showCalculator = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel("Close calculator")
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { onDrag($0.translation) }
            .onEnded { _ in onDragEnd() })
    }

    // MARK: Keys

    private func press(_ key: CalcKey) {
        Haptics.tap()
        if calc.press(key) { model.showCalculator = false }
    }

    private var controlCluster: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    key(.shift, "SHIFT", style: .shift)
                    key(.alpha, "ALPHA", style: .alpha)
                }
                HStack(spacing: 8) {
                    key(.inverse, "x⁻¹", shift: "x!", alpha: ":")
                    key(.logBase, "log□□")
                }
            }
            .frame(width: 112)
            Spacer(minLength: 0)
            ReplayPad(press: press)
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    key(.mode, "MODE", shift: "SETUP")
                    key(.on, "ON", style: .function)
                }
                Color.clear.frame(height: 38)
            }
            .frame(width: 112)
        }
        .padding(.horizontal, 16)
    }

    private var functionGrid: some View {
        Grid(horizontalSpacing: 7, verticalSpacing: 9) {
            GridRow {
                key(.fraction, "□/□", shift: "□□/□")
                key(.sqrt, "√□", shift: "∛□")
                key(.square, "x²", shift: "x³")
                key(.power, "x□", shift: "□√□")
                key(.log, "log", shift: "10□")
                key(.ln, "ln", shift: "e□")
            }
            GridRow {
                key(.negative, "(−)", alpha: "A")
                key(.dms, "°'\"", shift: "FACT", alpha: "B")
                key(.hyp, "hyp", shift: "Abs", alpha: "C")
                key(.sin, "sin", shift: "sin⁻¹", alpha: "D")
                key(.cos, "cos", shift: "cos⁻¹", alpha: "E")
                key(.tan, "tan", shift: "tan⁻¹", alpha: "F")
            }
            GridRow {
                key(.rcl, "RCL", shift: "STO")
                key(.eng, "ENG", shift: "←")
                key(.openParen, "(", shift: "%")
                key(.closeParen, ")", shift: ",", alpha: "X")
                key(.sd, "S⇔D", shift: "a⇔d/c", alpha: "Y")
                key(.mPlus, "M+", shift: "M−", alpha: "M")
            }
        }
        .padding(.horizontal, 14)
    }

    private var numberGrid: some View {
        Grid(horizontalSpacing: 9, verticalSpacing: 9) {
            GridRow {
                key(.d7, "7", style: .number)
                key(.d8, "8", style: .number)
                key(.d9, "9", shift: "CLR", style: .number)
                key(.del, "DEL", shift: "INS", style: .accent)
                key(.ac, "AC", shift: "OFF", style: .accent)
            }
            GridRow {
                key(.d4, "4", style: .number)
                key(.d5, "5", style: .number)
                key(.d6, "6", shift: "VERIFY", style: .number)
                key(.times, "×", shift: "nPr", alpha: "GCD", style: .number)
                key(.divide, "÷", shift: "nCr", alpha: "LCM", style: .number)
            }
            GridRow {
                key(.d1, "1", shift: "STAT", style: .number)
                key(.d2, "2", style: .number)
                key(.d3, "3", style: .number)
                key(.plus, "+", shift: "Pol", style: .number)
                key(.minus, "−", shift: "Rec", style: .number)
            }
            GridRow {
                key(.d0, "0", shift: "Rnd", style: .number)
                key(.point, ".", shift: "Ran#", alpha: "RanInt", style: .number)
                key(.exp, "×10ˣ", shift: "π", alpha: "e", style: .number)
                key(.ans, "Ans", shift: "DRG▶", style: .number)
                key(.equals, "=", style: .number)
            }
        }
        .padding(.horizontal, 14)
    }

    private func key(_ k: CalcKey, _ label: String, shift: String? = nil, alpha: String? = nil, style: CalcKeyStyle = .function) -> some View {
        CalcKeyButton(label: label, shiftLabel: shift, alphaLabel: alpha, style: style) { press(k) }
    }
}

// MARK: - Pieces

enum CalcKeyStyle {
    case function, number, accent, shift, alpha
}

private struct CalcKeyButton: View {
    let label: String
    let shiftLabel: String?
    let alphaLabel: String?
    let style: CalcKeyStyle
    let action: () -> Void

    private static let gold = Color(hex: "#E9B949")
    private static let red = Color(hex: "#F0645A")

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Text(shiftLabel ?? " ").foregroundStyle(CalcKeyButton.gold)
                if let alphaLabel { Text(alphaLabel).foregroundStyle(CalcKeyButton.red) }
            }
            .font(.system(size: 8.5, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(height: 10)
            Button(action: action) {
                Text(label)
                    .font(.system(size: fontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(textColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            }
            .buttonStyle(CalcKeyPressStyle(fill: fill))
            .accessibilityLabel(label)
        }
    }

    private var height: CGFloat { style == .number || style == .accent ? 40 : 28 }

    private var fontSize: CGFloat {
        switch style {
        case .number: return label.count > 2 ? 15 : 21
        case .accent: return 15
        case .shift, .alpha: return 11
        case .function: return label.count > 3 ? 12 : 14
        }
    }

    private var fill: Color {
        switch style {
        case .number: return Color(hex: "#DADDE3")
        case .accent: return Color(hex: "#E2873F")
        default: return Color(hex: "#3A4152")
        }
    }

    private var textColor: Color {
        switch style {
        case .number: return Color(hex: "#15181F")
        case .shift: return CalcKeyButton.gold
        case .alpha: return CalcKeyButton.red
        default: return .white
        }
    }
}

private struct CalcKeyPressStyle: ButtonStyle {
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill)
                    .brightness(configuration.isPressed ? -0.12 : 0)
                    .shadow(color: .black.opacity(configuration.isPressed ? 0.1 : 0.45), radius: configuration.isPressed ? 0 : 1.5, y: configuration.isPressed ? 0 : 2)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// The round REPLAY cursor pad.
private struct ReplayPad: View {
    let press: (CalcKey) -> Void

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(hex: "#4A5163"), Color(hex: "#2C3241")], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.45), radius: 2, y: 2)
            Circle()
                .fill(Color(hex: "#232835"))
                .frame(width: 30, height: 30)
                .overlay(Text("REPLAY").font(.system(size: 5.5, weight: .heavy)).foregroundStyle(.white.opacity(0.5)))
            arrow("chevron.up", .up).offset(y: -27)
            arrow("chevron.down", .down).offset(y: 27)
            arrow("chevron.left", .left).offset(x: -27)
            arrow("chevron.right", .right).offset(x: 27)
        }
        .frame(width: 86, height: 86)
    }

    private func arrow(_ symbol: String, _ key: CalcKey) -> some View {
        Button { press(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(describing: key))
    }
}

private struct LCDScreen: UIViewRepresentable {
    let display: CalcDisplay

    func makeUIView(context: Context) -> CalculatorLCDView { CalculatorLCDView() }

    func updateUIView(_ view: CalculatorLCDView, context: Context) {
        view.display = display
    }
}
