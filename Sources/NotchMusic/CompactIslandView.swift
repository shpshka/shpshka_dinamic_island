import AppKit
import Combine
import QuartzCore

/// The window grows once; these layers animate inside its fixed backing surface.
@MainActor
final class CompactIslandView: NSView {
    var pointerChanged: (() -> Void)?
    private var notchSize = CGSize(width: 88, height: 24)
    private var expanded = false
    private var targetSize: CGSize?
    private var hoverArea: NSTrackingArea?
    private var subscriptions: Set<AnyCancellable> = []
    private var accent = NSColor.lightGray
    private var playing = false
    private var hasTrack = false

    private let silhouette = CAShapeLayer()
    private let cover = CALayer()
    private let note = CAShapeLayer()
    private let bars = (0..<4).map { _ in CALayer() }
    private let restingHeights: [CGFloat] = [3, 6, 8, 4]
    private let beatDurations = [0.39, 0.48, 0.43, 0.54]

    init(player: PlayerController, artwork: TrackArtwork) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        // The same animated outline clips the black fill, the artwork and every AppKit subview.
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.mask = silhouette
        cover.cornerRadius = 4
        cover.borderWidth = 0.5
        cover.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        cover.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
        cover.contentsGravity = .resizeAspectFill
        cover.masksToBounds = true
        layer?.addSublayer(cover)
        note.fillColor = NSColor(white: 0.65, alpha: 1).cgColor
        let glyph = CGMutablePath()
        glyph.addEllipse(in: CGRect(x: 0, y: 0, width: 3.5, height: 2.5))
        glyph.addRect(CGRect(x: 2.5, y: 1.2, width: 1, height: 5.4))
        glyph.addRect(CGRect(x: 2.5, y: 5.3, width: 2.8, height: 1.4))
        note.bounds = glyph.boundingBox
        note.path = glyph
        cover.addSublayer(note)
        for bar in bars {
            bar.cornerRadius = 1
            layer?.addSublayer(bar)
        }

        player.$track.sink { [weak self] track in
            guard let self else { return }
            let playing = track?.isPlaying == true
            let hasTrack = track != nil
            guard self.playing != playing || self.hasTrack != hasTrack else { return }
            self.playing = playing
            self.hasTrack = hasTrack
            self.updateBars()
        }.store(in: &subscriptions)
        artwork.$image.sink { [weak self] image in
            self?.withoutActions {
                self?.cover.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                self?.note.isHidden = image != nil
            }
        }.store(in: &subscriptions)
        artwork.$accent.sink { [weak self] color in
            self?.accent = color
            self?.updateBars()
        }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateBars),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    func update(notchSize: CGSize, expanded: Bool = false) {
        guard self.notchSize != notchSize || self.expanded != expanded else { return }
        self.notchSize = notchSize
        self.expanded = expanded
        targetSize = nil
        needsLayout = true
    }

    func animateShape(from oldSize: CGSize, expanded wasExpanded: Bool,
                      to newSize: CGSize, expanded willExpand: Bool, duration: CFTimeInterval) {
        expanded = willExpand
        targetSize = newSize
        let oldRect = topCentered(oldSize)
        let newRect = topCentered(newSize)
        var startPath = outline(oldRect, expanded: wasExpanded)
        if silhouette.animation(forKey: "resize") != nil, let visible = silhouette.presentation()?.path {
            let box = visible.boundingBoxOfPath
            var align = CGAffineTransform(translationX: bounds.midX - box.midX, y: bounds.maxY - box.maxY)
            startPath = visible.copy(using: &align) ?? startPath
        }
        let startRect = startPath.boundingBoxOfPath
        let startOpacity = cover.animation(forKey: "opacity") != nil ? cover.presentation()?.opacity : nil

        layoutGraphics()
        func transition(_ layer: CALayer, _ key: String, from: Any, to: Any) {
            guard duration > 0 else { layer.removeAnimation(forKey: key); return }
            let motion = CABasicAnimation(keyPath: key == "resize" ? "path" : key)
            motion.fromValue = from
            motion.toValue = to
            motion.duration = duration
            motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(motion, forKey: key)
        }
        transition(silhouette, "resize", from: startPath, to: outline(newRect, expanded: willExpand))
        let oldCover = coverCenter(in: startRect)
        transition(cover, "position", from: oldCover, to: cover.position)
        transition(cover, "opacity", from: startOpacity ?? (wasExpanded ? 0 : 1), to: willExpand ? 0 : 1)
        for (index, bar) in bars.enumerated() {
            transition(bar, "position", from: barCenter(index, in: startRect), to: bar.position)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBars()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if targetSize == bounds.size { targetSize = nil }
        layoutGraphics()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // AppKit follows resizes automatically for an inVisibleRect tracking area.
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { pointerChanged?() }
    override func mouseExited(with event: NSEvent) { pointerChanged?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func topCentered(_ size: CGSize) -> CGRect {
        CGRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height,
               width: size.width, height: size.height)
    }

    private func coverCenter(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + (rect.width - notchSize.width) / 4, y: rect.maxY - notchSize.height / 2)
    }

    private func barCenter(_ index: Int, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.maxX - (rect.width - notchSize.width) / 4 - 6 + CGFloat(index * 4),
                y: rect.maxY - notchSize.height / 2)
    }

    private func layoutGraphics() {
        guard !bounds.isEmpty else { return }
        let rect = topCentered(targetSize ?? bounds.size)
        let side = min(18, max(12, notchSize.height - 6))
        withoutActions {
            silhouette.contentsScale = window?.backingScaleFactor ?? 1
            silhouette.frame = bounds
            silhouette.path = outline(rect, expanded: expanded)
            cover.bounds.size = CGSize(width: side, height: side)
            cover.position = coverCenter(in: rect)
            cover.opacity = expanded ? 0 : 1
            note.position = CGPoint(x: side / 2, y: side / 2)
            for (index, bar) in bars.enumerated() {
                bar.position = barCenter(index, in: rect)
            }
        }
    }

    @objc private func updateBars() {
        let animate = playing && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let tint = (hasTrack ? accent : NSColor.gray).cgColor
        withoutActions {
            for (index, bar) in bars.enumerated() {
                bar.bounds.size = CGSize(width: 2, height: animate ? 11 : restingHeights[index])
                bar.backgroundColor = tint
                if animate && bar.animation(forKey: "playback") == nil {
                    let motion = CABasicAnimation(keyPath: "transform.scale.y")
                    motion.fromValue = index.isMultiple(of: 2) ? 0.34 : 1
                    motion.toValue = index.isMultiple(of: 2) ? 1 : 0.34
                    motion.duration = beatDurations[index]
                    motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    motion.autoreverses = true
                    motion.repeatCount = .infinity
                    bar.add(motion, forKey: "playback")
                } else if !animate {
                    bar.removeAnimation(forKey: "playback")
                }
            }
        }
    }

    private func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    private func outline(_ rect: CGRect, expanded: Bool) -> CGPath {
        let left = rect.minX, right = rect.maxX, bottom = rect.minY, top = rect.maxY
        let shoulder: CGFloat = 6, radius = min(expanded ? 25 : 11, max(0, rect.height - shoulder))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: top))
        path.addQuadCurve(to: CGPoint(x: left + shoulder, y: top - shoulder), control: CGPoint(x: left + shoulder, y: top))
        path.addLine(to: CGPoint(x: left + shoulder, y: bottom + radius))
        path.addQuadCurve(to: CGPoint(x: left + shoulder + radius, y: bottom), control: CGPoint(x: left + shoulder, y: bottom))
        path.addLine(to: CGPoint(x: right - shoulder - radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: right - shoulder, y: bottom + radius), control: CGPoint(x: right - shoulder, y: bottom))
        path.addLine(to: CGPoint(x: right - shoulder, y: top - shoulder))
        path.addQuadCurve(to: CGPoint(x: right, y: top), control: CGPoint(x: right - shoulder, y: top))
        path.closeSubpath()
        return path
    }
}
