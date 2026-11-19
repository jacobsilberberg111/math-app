import UIKit

/// The formatting bar above the keyboard while a text box is being edited (like Notability's):
/// box style, bold / italic / underline / strikethrough, smaller / larger, colour, alignment,
/// bullet list, and Done. With text selected, changes apply to the selection; with only a caret
/// they apply to what you type next (style and alignment apply to the box / paragraph).
final class TextFormatBar: UIInputView {
    weak var textView: CanvasTextView?
    var onDone: (() -> Void)?
    private let stack = UIStackView()
    private var traitButtons: [UIButton] = []

    static let colors = ["#1F2328", "#1C64F2", "#E03131", "#2F9E44", "#7048E8", "#F08C00", "#868E96"]

    init(textView: CanvasTextView) {
        self.textView = textView
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 48),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 9, bottom: 8, trailing: 9)
        config.baseForegroundColor = .label
        let b = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            action()
            self?.refresh()
        })
        b.accessibilityLabel = label
        return b
    }

    private func divider() -> UIView {
        let v = UIView()
        v.backgroundColor = .separator
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return v
    }

    private func build() {
        // Box style
        let styleButton = UIButton(configuration: .plain())
        styleButton.configuration?.title = "Text"
        styleButton.configuration?.image = UIImage(systemName: "textformat")
        styleButton.configuration?.imagePadding = 4
        styleButton.configuration?.baseForegroundColor = .label
        styleButton.showsMenuAsPrimaryAction = true
        styleButton.menu = UIMenu(children: [
            (TextStyle.typed, "Text", "textformat"), (.heading, "Heading", "textformat.size.larger"),
            (.note, "Side Note", "text.alignleft"), (.sticky, "Sticky Note", "note.text"),
        ].map { style, title, symbol in
            UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in
                self?.textView?.setBoxStyle(style)
                self?.refresh()
            }
        })
        styleButton.accessibilityLabel = "Box style"
        stack.addArrangedSubview(styleButton)
        stack.addArrangedSubview(divider())

        let bold = button("bold", "Bold") { [weak self] in self?.textView?.toggleTrait(.traitBold) }
        let italic = button("italic", "Italic") { [weak self] in self?.textView?.toggleTrait(.traitItalic) }
        let underline = button("underline", "Underline") { [weak self] in self?.textView?.toggleLine(.underlineStyle) }
        let strike = button("strikethrough", "Strikethrough") { [weak self] in self?.textView?.toggleLine(.strikethroughStyle) }
        traitButtons = [bold, italic, underline, strike]
        traitButtons.forEach(stack.addArrangedSubview)
        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(button("textformat.size.smaller", "Smaller") { [weak self] in self?.textView?.adjustSize(by: -2) })
        stack.addArrangedSubview(button("textformat.size.larger", "Larger") { [weak self] in self?.textView?.adjustSize(by: 2) })

        // Colour
        let colorButton = UIButton(configuration: .plain())
        colorButton.configuration?.image = UIImage(systemName: "paintpalette")
        colorButton.configuration?.baseForegroundColor = .label
        colorButton.showsMenuAsPrimaryAction = true
        colorButton.menu = UIMenu(title: "Colour", children: TextFormatBar.colors.map { hex in
            let swatch = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in
                UIColor(hex: hex).setFill()
                UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 18, height: 18)).fill()
            }.withRenderingMode(.alwaysOriginal)
            return UIAction(title: hex, image: swatch) { [weak self] _ in self?.textView?.setColor(UIColor(hex: hex)) }
        })
        colorButton.accessibilityLabel = "Colour"
        stack.addArrangedSubview(colorButton)
        stack.addArrangedSubview(divider())

        // Alignment and lists
        let align = UIButton(configuration: .plain())
        align.configuration?.image = UIImage(systemName: "text.alignleft")
        align.configuration?.baseForegroundColor = .label
        align.showsMenuAsPrimaryAction = true
        align.menu = UIMenu(children: [
            (NSTextAlignment.left, "Left", "text.alignleft"), (.center, "Centre", "text.aligncenter"),
            (.right, "Right", "text.alignright"),
        ].map { a, title, symbol in
            UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in self?.textView?.setAlignment(a) }
        })
        align.accessibilityLabel = "Alignment"
        stack.addArrangedSubview(align)
        stack.addArrangedSubview(button("list.bullet", "Bullet list") { [weak self] in self?.textView?.toggleList(numbered: false) })
        stack.addArrangedSubview(button("list.number", "Numbered list") { [weak self] in self?.textView?.toggleList(numbered: true) })
        stack.addArrangedSubview(divider())

        var done = UIButton.Configuration.filled()
        done.title = "Done"
        done.cornerStyle = .capsule
        done.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        stack.addArrangedSubview(UIButton(configuration: done, primaryAction: UIAction { [weak self] _ in self?.onDone?() }))
        refresh()
    }

    /// Highlights B / I / U / S when the selection (or what you'll type next) has them.
    func refresh() {
        guard let tv = textView else { return }
        let attrs = tv.currentAttributes
        let font = attrs[.font] as? UIFont
        let on = [
            font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true,
            font?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true,
            (attrs[.underlineStyle] as? Int ?? 0) != 0,
            (attrs[.strikethroughStyle] as? Int ?? 0) != 0,
        ]
        for (b, isOn) in zip(traitButtons, on) {
            b.configuration?.background.backgroundColor = isOn ? UIColor.tintColor.withAlphaComponent(0.18) : .clear
            b.configuration?.background.cornerRadius = 8
        }
    }
}

// MARK: - Formatting a text view

extension CanvasTextView {
    /// The selection, or nil when there's only a caret.
    private var formatRange: NSRange? { selectedRange.length > 0 ? selectedRange : nil }

    /// Attributes at the caret (what you'll type next) or at the start of the selection.
    var currentAttributes: [NSAttributedString.Key: Any] {
        if let r = formatRange, r.location < textStorage.length { return textStorage.attributes(at: r.location, effectiveRange: nil) }
        return typingAttributes
    }

    private func edit(_ change: (NSMutableAttributedString, NSRange) -> Void, typing: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]) {
        if let r = formatRange {
            let selection = selectedRange
            textStorage.beginEditing()
            change(textStorage, r)
            textStorage.endEditing()
            selectedRange = selection
        }
        typingAttributes = typing(typingAttributes)
        delegate?.textViewDidChange?(self)
    }

    func toggleTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        let font = currentAttributes[.font] as? UIFont
        let turnOn = !(font?.fontDescriptor.symbolicTraits.contains(trait) ?? false)
        func apply(_ f: UIFont) -> UIFont {
            var traits = f.fontDescriptor.symbolicTraits
            if turnOn { traits.insert(trait) } else { traits.remove(trait) }
            guard let d = f.fontDescriptor.withSymbolicTraits(traits) else { return f }
            return UIFont(descriptor: d, size: f.pointSize)
        }
        edit({ s, r in
            s.enumerateAttribute(.font, in: r) { v, sub, _ in
                if let f = v as? UIFont { s.addAttribute(.font, value: apply(f), range: sub) }
            }
        }, typing: { a in
            var a = a
            if let f = a[.font] as? UIFont { a[.font] = apply(f) }
            return a
        })
    }

    func toggleLine(_ key: NSAttributedString.Key) {
        let turnOn = (currentAttributes[key] as? Int ?? 0) == 0
        edit({ s, r in
            if turnOn { s.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: r) } else { s.removeAttribute(key, range: r) }
        }, typing: { a in
            var a = a
            a[key] = turnOn ? NSUnderlineStyle.single.rawValue : nil
            return a
        })
    }

    func adjustSize(by delta: CGFloat) {
        func apply(_ f: UIFont) -> UIFont { f.withSize(max(8, min(96, f.pointSize + delta))) }
        edit({ s, r in
            s.enumerateAttribute(.font, in: r) { v, sub, _ in
                if let f = v as? UIFont { s.addAttribute(.font, value: apply(f), range: sub) }
            }
        }, typing: { a in
            var a = a
            if let f = a[.font] as? UIFont { a[.font] = apply(f) }
            return a
        })
    }

    func setColor(_ color: UIColor) {
        edit({ s, r in s.addAttribute(.foregroundColor, value: color, range: r) },
             typing: { a in var a = a; a[.foregroundColor] = color; return a })
    }

    /// Alignment applies to whole paragraphs: the ones the selection touches, or the caret's.
    func setAlignment(_ alignment: NSTextAlignment) {
        let ns = textStorage.string as NSString
        let range = ns.paragraphRange(for: selectedRange)
        let p = NSMutableParagraphStyle()
        p.alignment = alignment
        let selection = selectedRange
        textStorage.beginEditing()
        if range.length > 0 { textStorage.addAttribute(.paragraphStyle, value: p, range: range) }
        textStorage.endEditing()
        selectedRange = selection
        typingAttributes[.paragraphStyle] = p
        delegate?.textViewDidChange?(self)
    }

    /// Bullet (•) or numbered list for the paragraphs the selection touches; again to remove it.
    func toggleList(numbered: Bool) {
        let ns = textStorage.string as NSString
        let range = ns.paragraphRange(for: selectedRange)
        let paragraphs = ns.substring(with: range).components(separatedBy: "\n")
        let filled = paragraphs.filter { !$0.isEmpty }
        let isListed = !filled.isEmpty && filled.allSatisfy { CanvasTextView.listPrefix(of: $0) != nil }
        var n = 0
        let rewritten = paragraphs.enumerated().map { i, line -> String in
            if i == paragraphs.count - 1 && line.isEmpty && paragraphs.count > 1 { return line }
            let bare = CanvasTextView.listPrefix(of: line).map { String(line.dropFirst($0.count)) } ?? line
            if isListed { return bare }
            n += 1
            return (numbered ? "\(n). " : "• ") + bare
        }.joined(separator: "\n")
        let attrs = range.location < textStorage.length ? textStorage.attributes(at: range.location, effectiveRange: nil) : typingAttributes
        textStorage.replaceCharacters(in: range, with: NSAttributedString(string: rewritten, attributes: attrs))
        selectedRange = NSRange(location: range.location + (rewritten as NSString).length, length: 0)
        delegate?.textViewDidChange?(self)
    }

    /// "• " or "12. " at the start of a line.
    static func listPrefix(of line: String) -> String? {
        if line.hasPrefix("• ") { return "• " }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") { return String(digits) + ". " }
        return nil
    }

    /// The box's style: its decoration, and for headings a bold, larger font.
    func setBoxStyle(_ style: TextStyle) {
        let base = baseSize
        self.style = style
        applyStyleDecoration()
        let font = StudentText.font(style: style, size: base)
        let all = NSRange(location: 0, length: textStorage.length)
        textStorage.beginEditing()
        textStorage.enumerateAttribute(.font, in: all) { v, sub, _ in
            guard let f = v as? UIFont else { return }
            // Keep italics; weight and size follow the style.
            var traits = font.fontDescriptor.symbolicTraits
            if f.fontDescriptor.symbolicTraits.contains(.traitItalic) { traits.insert(.traitItalic) }
            let d = font.fontDescriptor.withSymbolicTraits(traits) ?? font.fontDescriptor
            textStorage.addAttribute(.font, value: UIFont(descriptor: d, size: font.pointSize), range: sub)
        }
        textStorage.endEditing()
        typingAttributes[.font] = font
        delegate?.textViewDidChange?(self)
    }
}
