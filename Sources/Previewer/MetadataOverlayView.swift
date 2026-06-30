import Cocoa

/// Compact, tap-to-expand metadata overlay for the Quick Look preview.
/// Uses a translucent dark background so the image shows through while text stays solid.
final class MetadataOverlayView: NSView {

    // MARK: - Model

    private struct Row { let label: String; let value: String }

    // MARK: - Subviews

    private let outerStack   = NSStackView()
    private let primaryStack = NSStackView()
    private let divider      = NSBox()
    private let detailStack  = NSStackView()
    private let footerRow    = NSStackView()
    private let chevron      = NSTextField(labelWithString: "▸ More")
    private let closeLabel   = NSTextField(labelWithString: "✕")

    // MARK: - State

    private var primaryRows: [Row] = []
    private var detailRows:  [Row] = []
    private var isExpanded = false

    // MARK: - Public

    var onDismiss: (() -> Void)?

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildLayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func buildLayout() {
        translatesAutoresizingMaskIntoConstraints = false

        // Fixed width; height grows from content.
        widthAnchor.constraint(equalToConstant: 204).isActive = true

        // Translucent background on this view's own layer.
        // Setting the layer's background (not alphaValue) keeps child views — the
        // text labels — fully opaque even though the backing rectangle is see-through.
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.05, alpha: 0.30).cgColor
        layer?.cornerRadius = 10

        // Content stack laid out directly inside this view.
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.orientation = .vertical
        outerStack.spacing = 2
        outerStack.alignment = .leading
        addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.leadingAnchor.constraint(equalTo: leadingAnchor,  constant: 10),
            outerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            outerStack.topAnchor.constraint(equalTo: topAnchor,    constant: 8),
            outerStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])

        // Stack-view sections – constrain each to outerStack's width so rows fill it.
        primaryStack.orientation = .vertical
        primaryStack.spacing = 1
        outerStack.addArrangedSubview(primaryStack)
        primaryStack.widthAnchor.constraint(equalTo: outerStack.widthAnchor).isActive = true

        divider.boxType = .separator
        divider.isHidden = true
        outerStack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: outerStack.widthAnchor).isActive = true

        detailStack.orientation = .vertical
        detailStack.spacing = 1
        detailStack.isHidden = true
        outerStack.addArrangedSubview(detailStack)
        detailStack.widthAnchor.constraint(equalTo: outerStack.widthAnchor).isActive = true

        // Footer row: spacer + chevron label.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        chevron.font = .systemFont(ofSize: 9, weight: .regular)
        chevron.textColor = NSColor.white.withAlphaComponent(0.4)
        footerRow.orientation = .horizontal
        footerRow.spacing = 0
        footerRow.addArrangedSubview(spacer)
        footerRow.addArrangedSubview(chevron)
        footerRow.isHidden = true
        outerStack.addArrangedSubview(footerRow)
        footerRow.widthAnchor.constraint(equalTo: outerStack.widthAnchor).isActive = true
        footerRow.heightAnchor.constraint(equalToConstant: 13).isActive = true

        // Close button — top-right corner, sits above the stack.
        closeLabel.translatesAutoresizingMaskIntoConstraints = false
        closeLabel.font = .systemFont(ofSize: 10, weight: .regular)
        closeLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        addSubview(closeLabel)
        NSLayoutConstraint.activate([
            closeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            closeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
        ])
        let closeTap = NSClickGestureRecognizer(target: self, action: #selector(handleClose))
        closeLabel.addGestureRecognizer(closeTap)

        // Tap anywhere else to expand/collapse.
        let tap = NSClickGestureRecognizer(target: self, action: #selector(toggleExpanded(_:)))
        addGestureRecognizer(tap)
    }

    // MARK: - Public API

    func configure(with metadata: [String: String]) {
        (primaryRows, detailRows) = Self.parse(metadata)
        rebuildContent()
    }

    // MARK: - Toggle

    @objc private func handleClose() {
        onDismiss?()
    }

    @objc private func toggleExpanded(_ sender: NSClickGestureRecognizer) {
        guard !detailRows.isEmpty else { return }
        // Ignore clicks that land on the close button.
        if closeLabel.frame.contains(sender.location(in: self)) { return }
        isExpanded.toggle()
        chevron.stringValue = isExpanded ? "▾ Less" : "▸ More"
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            divider.isHidden     = !isExpanded
            detailStack.isHidden = !isExpanded
        }
    }

    // MARK: - Content

    private func rebuildContent() {
        primaryStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        detailStack.arrangedSubviews.forEach  { $0.removeFromSuperview() }

        for r in primaryRows {
            let row = makeRow(r)
            primaryStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: primaryStack.widthAnchor).isActive = true
        }
        for r in detailRows {
            let row = makeRow(r)
            detailStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        }

        let hasDetail = !detailRows.isEmpty
        footerRow.isHidden   = !hasDetail
        divider.isHidden     = !isExpanded || !hasDetail
        detailStack.isHidden = !isExpanded || !hasDetail
        chevron.stringValue  = isExpanded ? "▾ Less" : "▸ More"

        isHidden = primaryRows.isEmpty
    }

    // MARK: - Row Factory

    private static let rowFont    = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private static let labelWidth: CGFloat = 55

    private func makeRow(_ row: Row) -> NSStackView {
        let h = NSStackView()
        h.translatesAutoresizingMaskIntoConstraints = false
        h.orientation = .horizontal
        h.spacing = 6
        h.alignment = .centerY
        h.heightAnchor.constraint(equalToConstant: 15).isActive = true

        let lbl = NSTextField(labelWithString: row.label)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.font = Self.rowFont
        lbl.textColor = NSColor.white.withAlphaComponent(0.52)
        lbl.alignment = .right
        lbl.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        lbl.setContentHuggingPriority(.required, for: .horizontal)

        let val = NSTextField(labelWithString: row.value)
        val.translatesAutoresizingMaskIntoConstraints = false
        val.font = Self.rowFont
        val.textColor = .white
        val.lineBreakMode = .byTruncatingTail
        val.setContentHuggingPriority(.defaultLow, for: .horizontal)
        val.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        h.addArrangedSubview(lbl)
        h.addArrangedSubview(val)
        return h
    }

    // MARK: - Metadata Parsing

    private static func parse(_ m: [String: String]) -> ([Row], [Row]) {
        var p: [Row] = []
        var d: [Row] = []

        // Primary: filter, exposure (always seconds), focal length, temp, date.
        if let v = m["FILTER"]?.fits, !v.isEmpty {
            p.append(Row(label: "Filter", value: v))
        }
        if let raw = m["EXPTIME"] ?? m["EXPOSURE"], let s = Double(raw) {
            p.append(Row(label: "Exp", value: String(format: "%.1f s", s)))
        }
        if let raw = m["FOCALLEN"], let f = Double(raw), f > 0 {
            p.append(Row(label: "Focal", value: String(format: "%.0f mm", f)))
        }
        if let raw = m["CCD-TEMP"] ?? m["SET-TEMP"], let t = Double(raw) {
            p.append(Row(label: "Temp", value: String(format: "%.1f°C", t)))
        }
        if let raw = m["DATE-OBS"] {
            p.append(Row(label: "Date", value: formatDate(raw)))
        }

        // Detail: object, camera, scope, gain, binning, size, frames.
        if let v = m["OBJECT"]?.fits, !v.isEmpty {
            d.append(Row(label: "Object", value: v))
        }
        if let v = m["INSTRUME"]?.fits, !v.isEmpty {
            d.append(Row(label: "Camera", value: v))
        }
        if let v = m["TELESCOP"]?.fits, !v.isEmpty {
            d.append(Row(label: "Scope",  value: v))
        }
        // Camera gain: show as integer if >1 (gain setting), else as e⁻/ADU.
        if let raw = m["GAIN"]?.fits, let gv = Double(raw), gv > 1.0 {
            d.append(Row(label: "Gain", value: String(Int(gv.rounded()))))
        } else if let raw = m["EGAIN"]?.fits, let gv = Double(raw) {
            d.append(Row(label: "e⁻/ADU", value: String(format: "%.3f", gv)))
        }
        if let bx = m["XBINNING"]?.fits, let by = m["YBINNING"]?.fits {
            d.append(Row(label: "Bin", value: "\(bx)×\(by)"))
        }
        if let w = m["__WIDTH__"], let h = m["__HEIGHT__"] {
            d.append(Row(label: "Size", value: "\(w) × \(h)"))
        }
        if let v = (m["STACKCNT"] ?? m["NCOMBINE"])?.fits, !v.isEmpty {
            d.append(Row(label: "Frames", value: v))
        }
        return (p, d)
    }

    private static func formatDate(_ raw: String) -> String {
        let s = raw.fits
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
                    "yyyy-MM-dd'T'HH:mm:ss.SSS",
                    "yyyy-MM-dd'T'HH:mm:ss"] {
            let df = DateFormatter()
            df.dateFormat = fmt
            df.timeZone = TimeZone(identifier: "UTC")
            if let d = df.date(from: s) {
                let out = DateFormatter()
                out.dateFormat = "yyyy-MM-dd  HH:mm"
                out.timeZone = TimeZone(identifier: "UTC")
                return out.string(from: d)
            }
        }
        return String(s.prefix(10))
    }
}

// Strip FITS quoting/whitespace from a string value.
private extension String {
    var fits: String {
        trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            .trimmingCharacters(in: .whitespaces)
    }
}
