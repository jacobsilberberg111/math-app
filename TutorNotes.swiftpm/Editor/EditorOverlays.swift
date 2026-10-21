import SwiftUI

/// Floating pill at the top of the canvas showing what the tutor is doing right now.
struct TutorStatusPill: View {
    @Bindable var model: EditorModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        let tutor = model.tutor
        let visible = tutor.isBusy || tutor.isObserving
        if visible {
            HStack(spacing: 10) {
                TutorOrb(active: true, size: 20)
                Text(tutor.statusText ?? (tutor.isObserving ? "Glancing at your work…" : "Thinking…"))
                    .font(.system(size: 14, weight: .medium))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: tutor.statusText)
                if tutor.isBusy {
                    Button {
                        tutor.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop tutor")
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, tutor.isBusy ? 6 : 14)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { model.showTutor = true }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// The menu that appears when the student selects a region, taps with the Ask tool, or squeezes
/// the Apple Pencil.
struct QuickMenuView: View {
    let request: QuickMenuRequest
    @Bindable var model: EditorModel
    @EnvironmentObject var settings: AppSettings

    static let actions: [TutorQuickAction] = [.check, .hint, .nextStep, .explain, .solve, .graphIt, .similar]

    var body: some View {
        let tint = Color(hex: settings.tutorInkHex)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TutorOrb(active: false, size: 22)
                Text("Ask your tutor").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    model.dismissQuickMenu()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 26, height: 26).background(Circle().fill(Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(QuickMenuView.actions) { action in
                    Button {
                        model.runQuick(action, on: request)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: action.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                            Text(action.title).font(.system(size: 13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    model.askAboutRegion(request)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.cursor").font(.system(size: 13, weight: .semibold))
                        Text("Ask…").font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
    }

    /// Position near the anchor, preferring below it, clamped inside the canvas.
    static func position(for anchor: CGRect, in size: CGSize) -> CGPoint {
        let w: CGFloat = 320, h: CGFloat = 260
        var x = anchor.midX
        x = min(max(x, w / 2 + 12), size.width - w / 2 - 12)
        var y = anchor.maxY + 16 + h / 2
        if y + h / 2 > size.height - 12 { y = anchor.minY - 16 - h / 2 }
        y = min(max(y, h / 2 + 12), size.height - h / 2 - 12)
        return CGPoint(x: x, y: y)
    }
}

struct SuggestionPill: View {
    let suggestion: TutorSuggestion
    let action: () -> Void
    let dismiss: () -> Void
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: suggestion.symbol)
                    Text(suggestion.title).font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color(hex: settings.tutorInkHex)))
            }
            .buttonStyle(.plain)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28).background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Recording / playback bar with ink replay.
struct AudioBar: View {
    @Bindable var audio: AudioController

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        HStack(spacing: 12) {
            if audio.isRecording {
                Circle().fill(Color.red).frame(width: 10, height: 10)
                Text("Recording  \(AudioBar.format(audio.currentTime))").font(.system(size: 14, weight: .semibold).monospacedDigit())
                Button("Stop") { audio.stopRecording() }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
            } else if audio.activeRecording != nil {
                Button {
                    audio.togglePlayback()
                } label: {
                    Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                Text(AudioBar.format(audio.currentTime)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Slider(value: Binding(get: { audio.currentTime }, set: { audio.seek(to: $0) }), in: 0...max(1, audio.duration))
                    .frame(minWidth: 160)
                Text(AudioBar.format(audio.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Toggle(isOn: $audio.replayInk) {
                    Image(systemName: "scribble")
                }
                .toggleStyle(.button)
                .help("Replay ink in sync with audio")
                Button {
                    audio.closePlayer()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close playback")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .frame(maxWidth: 560)
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

/// Paper style picker for one page or the whole note.
struct PaperPicker: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var pattern: PaperPattern = .ruled
    @State private var color: PaperColor = .white
    @State private var applyToAll = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Pattern") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 12) {
                        ForEach(PaperPattern.allCases) { p in
                            Button {
                                pattern = p
                            } label: {
                                VStack(spacing: 6) {
                                    PaperSwatch(style: PaperStyle(pattern: p, color: color))
                                        .frame(width: 70, height: 90)
                                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(p == pattern ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: p == pattern ? 3 : 1))
                                    Text(p.title).font(.caption).foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section("Colour") {
                    HStack(spacing: 14) {
                        ForEach(PaperColor.allCases) { c in
                            Button {
                                color = c
                            } label: {
                                Circle().fill(Color(hex: c.hex))
                                    .overlay(Circle().strokeBorder(c == color ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: c == color ? 3 : 1))
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    Toggle("Apply to all pages", isOn: $applyToAll)
                }
            }
            .navigationTitle("Paper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        model.document.setPaper(PaperStyle(pattern: pattern, color: color), forPage: applyToAll ? nil : model.currentPage)
                        dismiss()
                    }
                }
            }
            .onAppear {
                let current = model.document.content.pages[safe: model.currentPage]?.paper ?? .standard
                pattern = current.pattern
                color = current.color
            }
        }
    }
}

struct PaperSwatch: View {
    let style: PaperStyle

    var body: some View {
        Canvas { ctx, size in
            let full = PageSize.letter
            let scale = size.width / full.width
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: style.color.hex)))
            let paths = PaperRenderer.patternPaths(style.pattern, size: CGSize(width: full.width, height: full.height))
            ctx.scaleBy(x: scale, y: scale)
            let line = Color(uiColor: PaperRenderer.lineColor(style))
            if let l = paths.light { ctx.stroke(Path(l), with: .color(line), lineWidth: 2.5) }
            if let s = paths.strong { ctx.stroke(Path(s), with: .color(line), lineWidth: 4) }
            if let d = paths.dots { ctx.fill(Path(d), with: .color(line)) }
            if let a = paths.accent { ctx.stroke(Path(a), with: .color(Color(uiColor: PaperRenderer.accentColor(style))), lineWidth: 3) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
