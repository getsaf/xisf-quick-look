import QuickLookThumbnailing
import AppKit

class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let maxSize = request.maximumSize

        DispatchQueue.global(qos: .userInitiated).async {
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let image = try XISFBridge.thumbnailImage(for: url, maxSize: maxSize)
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    handler(nil, nil); return
                }
                // Use physical CGImage pixel dimensions for aspect-ratio maths.
                let cgW = CGFloat(cg.width)
                let cgH = CGFloat(cg.height)

                // Scale to fit within maxSize preserving aspect ratio, then tell QL
                // the exact context size so it shapes the thumbnail to match the image.
                let scale = min(maxSize.width / cgW, maxSize.height / cgH)
                let contextSize = CGSize(width: (cgW * scale).rounded(),
                                        height: (cgH * scale).rounded())

                let reply = QLThumbnailReply(contextSize: contextSize) { ctx -> Bool in
                    let clip = ctx.boundingBoxOfClipPath
                    let drawRect = CGRect(x: 0, y: 0, width: clip.width, height: clip.height)
                    // CGContextDrawImage maps the CGImage's first row to the rect's
                    // bottom-left in a non-flipped (y=0 at bottom) context, producing
                    // an upside-down image. Flip the CTM so it renders right-side-up.
                    ctx.saveGState()
                    ctx.translateBy(x: 0, y: clip.height)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(cg, in: drawRect)
                    ctx.restoreGState()
                    return true
                }
                handler(reply, nil)
            } catch {
                handler(nil, error)
            }
        }
    }
}
