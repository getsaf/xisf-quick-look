import Cocoa
import QuickLookUI

// Centers the document view inside the scroll view when smaller than the viewport.
final class CenteredClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let docFrame = documentView?.frame else { return rect }
        if rect.width > docFrame.width {
            rect.origin.x = floor((docFrame.width - rect.width) / 2)
        }
        if rect.height > docFrame.height {
            rect.origin.y = floor((docFrame.height - rect.height) / 2)
        }
        return rect
    }
}

class PreviewViewController: NSViewController, QLPreviewingController {

    private var scrollView: NSScrollView!
    private var imageView: NSImageView!
    private var overlayView: MetadataOverlayView!

    private let spinner: NSProgressIndicator = {
        let s = NSProgressIndicator()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.style = .spinning
        s.isIndeterminate = true
        s.isHidden = true
        return s
    }()

    private let errorLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.isHidden = true
        l.alignment = .center
        l.textColor = .secondaryLabelColor
        l.font = .systemFont(ofSize: 14)
        return l
    }()

    // Set to true when the user pinches/zooms so we stop auto-fitting on resize.
    // Reset by double-click (zoom-to-fit).
    private var userHasZoomed = false

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor

        let clip = CenteredClipView()
        clip.drawsBackground = false

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView = clip
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02   // updated dynamically to fit-scale
        scrollView.maxMagnification = 32.0
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.backgroundColor = .black
        scrollView.drawsBackground = true

        imageView = NSImageView()
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignTopLeft
        imageView.animates = false
        scrollView.documentView = imageView

        overlayView = MetadataOverlayView()
        overlayView.isHidden = true
        overlayView.onDismiss = { [weak self] in self?.overlayView.isHidden = true }

        root.addSubview(scrollView)
        root.addSubview(spinner)
        root.addSubview(errorLabel)
        root.addSubview(overlayView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -40),

            // Overlay: bottom-left corner with 12pt margin.
            overlayView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            overlayView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        // Mark that the user has taken over zoom so we stop auto-fitting.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDidBeginManualZoom),
            name: NSScrollView.willStartLiveMagnifyNotification,
            object: scrollView
        )

        // Single-click on image: re-show overlay if dismissed.
        let singleClick = NSClickGestureRecognizer(target: self, action: #selector(showOverlay))
        singleClick.numberOfClicksRequired = 1
        scrollView.addGestureRecognizer(singleClick)

        // Double-click: zoom back to fit and re-enable auto-fit on resize.
        let dblClick = NSClickGestureRecognizer(target: self, action: #selector(resetToFit))
        dblClick.numberOfClicksRequired = 2
        scrollView.addGestureRecognizer(dblClick)

        self.view = root
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Zoom

    // The scale that fits the entire image in the current scroll view bounds.
    private var fitScale: CGFloat {
        guard let img = imageView.image else { return 0.02 }
        let s = scrollView.bounds.size
        guard s.width > 0, s.height > 0,
              img.size.width > 0, img.size.height > 0 else { return 0.02 }
        return min(s.width / img.size.width, s.height / img.size.height)
    }

    // Called on every layout pass. Keeps min-magnification clamped to the
    // fit-to-window scale, and re-fits the image as long as the user hasn't
    // manually zoomed. This handles QL resizing the view after
    // preparePreviewOfFile fires.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard scrollView.bounds.width > 1 else { return }

        // Always clamp minimum zoom to fit-to-window scale.
        let scale = fitScale
        if scale > 0.001 { scrollView.minMagnification = scale }

        guard !userHasZoomed, imageView?.image != nil else { return }
        applyZoomToFit()
    }

    @objc private func userDidBeginManualZoom() {
        userHasZoomed = true
    }

    @objc private func showOverlay() {
        guard imageView.image != nil else { return }
        overlayView.isHidden = false
    }

    @objc private func resetToFit() {
        userHasZoomed = false
        applyZoomToFit()
    }

    private func applyZoomToFit() {
        guard let img = imageView.image else { return }
        let scale = fitScale
        guard scale > 0 else { return }
        imageView.frame = NSRect(origin: .zero, size: img.size)
        scrollView.minMagnification = scale
        scrollView.magnification = scale
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL,
                              completionHandler handler: @escaping (Error?) -> Void) {
        userHasZoomed = false
        overlayView.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            // Fast header-only read for metadata, then full pixel read for image.
            let meta = (try? XISFBridge.metadata(for: url)) ?? [:]

            do {
                let image = try XISFBridge.previewImage(for: url)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.spinner.stopAnimation(nil)
                    self.spinner.isHidden = true
                    self.imageView.image = image
                    self.imageView.frame = NSRect(origin: .zero, size: image.size)
                    self.overlayView.configure(with: meta)
                    self.view.needsLayout = true
                    handler(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.spinner.stopAnimation(nil)
                    self.spinner.isHidden = true
                    self.errorLabel.stringValue = error.localizedDescription
                    self.errorLabel.isHidden = false
                    handler(error)
                }
            }
        }
    }
}
