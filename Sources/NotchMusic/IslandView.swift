import AppKit
import Combine

/// The panel creates these controls on expansion and releases them on collapse.
@MainActor
final class ExpandedIslandView: NSView {
    private let player: PlayerController
    private let island: IslandPresentation
    private let artwork: TrackArtwork
    private let lyrics: LyricsLookup
    private var observations: Set<AnyCancellable> = []
    private var updateScheduled = false
    private var request: LyricsLookup.Request?
    private var search: Task<Void, Never>?
    private var copyFeedback: DispatchWorkItem?

    private let metadata = NSView()
    private let cover = NSImageView()
    private let source = label(10, .semibold)
    private let title = label(18, .semibold)
    private let artist = label(12)
    private let pin = IslandButton()
    private let previous = IslandButton()
    private let play = IslandButton()
    private let next = IslandButton()
    private let connect = IslandButton()
    private let words = IslandButton()
    private let open = IslandButton()
    private var wordsView: LyricsPane?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(player: PlayerController, island: IslandPresentation, artwork: TrackArtwork, lyrics: LyricsLookup) {
        self.player = player
        self.island = island
        self.artwork = artwork
        self.lyrics = lyrics
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        for view in [metadata, pin, previous, play, next, connect, words, open] { addSubview(view) }
        for view in [cover, source, title, artist] { metadata.addSubview(view) }
        cover.wantsLayer = true
        cover.layer?.cornerRadius = 10
        cover.layer?.masksToBounds = true
        cover.layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        cover.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        cover.layer?.borderWidth = 0.5
        for button in [pin, previous, play, next, connect, words, open] { button.target = self }
        pin.action = #selector(togglePin)
        previous.action = #selector(goPrevious)
        play.action = #selector(playPause)
        next.action = #selector(goNext)
        connect.action = #selector(connectPlayer)
        words.action = #selector(toggleWords)
        open.action = #selector(openPlayer)
        artist.textColor = .init(white: 0.72, alpha: 1)
        title.maximumNumberOfLines = 2
        title.cell?.wraps = true
        title.lineBreakMode = .byWordWrapping
        artist.maximumNumberOfLines = 2
        let menu = NSMenu()
        menu.delegate = self
        metadata.menu = menu
        for view in [cover, source, title, artist] { view.menu = menu }
        // Published values arrive before assignment. Coalesce all fields of a song change.
        player.objectWillChange.sink { [weak self] in self?.scheduleUpdate() }.store(in: &observations)
        artwork.objectWillChange.sink { [weak self] in self?.scheduleUpdate() }.store(in: &observations)
        update()
    }

    required init?(coder: NSCoder) { nil }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.update()
        }
    }

    func close() {
        search?.cancel()
        copyFeedback?.cancel()
        observations.removeAll()
        wordsView?.removeFromSuperview()
        wordsView = nil
    }

    func update() {
        let track = player.track
        let tint = artwork.accent
        cover.image = artwork.image ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 23, weight: .medium))
        cover.imageScaling = artwork.image == nil ? .scaleNone : .scaleProportionallyUpOrDown
        cover.contentTintColor = artwork.image == nil ? .lightGray : nil
        source.stringValue = track == nil ? "" : player.sourceName
        source.textColor = tint
        title.stringValue = track?.title ?? idleTitle
        title.toolTip = title.stringValue
        artist.stringValue = track.map { $0.artist.isEmpty ? $0.album : $0.artist } ?? player.statusDetail
        artist.lineBreakMode = track == nil ? .byWordWrapping : .byTruncatingTail
        artist.toolTip = artist.stringValue

        pin.style(island.isPinned ? "pin.fill" : "pin", help: island.isPinned ? "Открепить остров" : "Закрепить остров открытым",
                  ink: island.isPinned ? tint : .lightGray, size: 11)
        previous.style("backward.fill", help: "Предыдущий трек")
        next.style("forward.fill", help: "Следующий трек")
        let playing = track?.isPlaying == true
        play.style(playing ? "pause.fill" : "play.fill", help: playing ? "Пауза" : "Воспроизвести", ink: .black, fill: tint)
        previous.isEnabled = player.canSkipPrevious
        next.isEnabled = player.canSkipNext
        play.isEnabled = player.canPlayPause
        if let name = player.connectTitle {
            connect.style(nil, title: name, help: name, ink: .black, fill: .white)
        }
        connect.isHidden = player.connectTitle == nil
        for button in [previous, play, next] { button.isHidden = !connect.isHidden }
        words.style("text.quote", title: "Текст", help: "Текст песни из плеера или LRCLIB",
                    ink: island.showsLyrics ? tint : .white,
                    fill: island.showsLyrics ? tint.withAlphaComponent(0.2) : .init(white: 0.15, alpha: 1), size: 12)
        words.isEnabled = track != nil || island.showsLyrics
        open.style("arrow.up.forward.app", help: "Открыть " + player.sourceName, ink: .lightGray, size: 15)
        open.isHidden = !player.canOpenPlayer
        updateWords()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, band = island.notchSize.height
        let left: CGFloat = 22, right = w - left
        let wing = (w - island.notchSize.width) / 2
        pin.frame = CGRect(x: (wing - 30) / 2, y: (band - 24) / 2, width: 30, height: 24)
        // Metadata is an unflipped AppKit container.
        metadata.frame = CGRect(x: left, y: band + 2, width: right - left, height: 76)
        cover.frame = CGRect(x: 0, y: 7, width: 62, height: 62)
        let tw = max(0, metadata.bounds.width - 74)
        let withSource = !source.stringValue.isEmpty
        let textBounds = (title.stringValue as NSString).boundingRect(
            with: CGSize(width: max(1, tw - 4), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: title.font!])
        let titleHeight = min(43, max(22, ceil(textBounds.height)))
        let artistHeight: CGFloat = player.track == nil ? 30 : 16
        let total = (withSource ? 15 : 0) + titleHeight + 3 + artistHeight
        var top = (metadata.bounds.height + total) / 2
        source.isHidden = !withSource
        if withSource {
            source.frame = CGRect(x: 74, y: top - 13, width: tw, height: 13)
            top -= 15
        }
        title.frame = CGRect(x: 74, y: top - titleHeight, width: tw, height: titleHeight)
        artist.frame = CGRect(x: 74, y: top - titleHeight - 3 - artistHeight, width: tw, height: artistHeight)
        let y = band + 84
        previous.frame = CGRect(x: left, y: y, width: 31, height: 32)
        play.frame = CGRect(x: left + 34, y: y, width: 50, height: 32)
        next.frame = CGRect(x: left + 87, y: y, width: 31, height: 32)
        connect.frame = CGRect(x: left, y: y, width: min(170, ceil(connect.attributedTitle.size().width) + 24), height: 32)
        open.frame = CGRect(x: right - 29, y: y, width: 29, height: 32)
        let wordsRight = right - (open.isHidden ? 0 : 35)
        words.frame = CGRect(x: wordsRight - 75, y: y + 1, width: 75, height: 30)
        if let wordsView {
            let origin = band + 132
            wordsView.frame = CGRect(x: left, y: origin, width: right - left, height: max(0, bounds.height - origin - 15))
        }
    }

    private var idleTitle: String {
        switch player.status {
        case .ready: return player.sourceName
        case .denied: return "Нет доступа к плееру"
        case .needsPermission: return "Подключите плеер"
        case .notRunning: return "Включите музыку на Mac"
        case .unavailable: return "Плеер недоступен"
        }
    }

    private func updateWords() {
        guard island.showsLyrics else {
            search?.cancel()
            search = nil
            request = nil
            wordsView?.removeFromSuperview()
            wordsView = nil
            return
        }
        let pane: LyricsPane
        if let wordsView { pane = wordsView } else {
            pane = LyricsPane()
            wordsView = pane
            addSubview(pane)
            pane.copyButton.target = self
            pane.copyButton.action = #selector(copyWords)
            pane.retry.target = self
            pane.retry.action = #selector(retryLyrics)
        }
        let track = player.track
        let embedded = track?.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = embedded?.isEmpty != false ? track.flatMap(LyricsLookup.Request.init) : nil
        if query != request {
            search?.cancel()
            request = query
            if let query { load(query) }
        }
        if let embedded, !embedded.isEmpty {
            pane.show(text: embedded, source: "Из плеера", accent: artwork.accent)
        } else if let query {
            switch lyrics.state(for: query) {
            case .found(let text): pane.show(text: text, source: "LRCLIB", accent: artwork.accent)
            case .loading: pane.message("Ищем текст песни…")
            case .instrumental: pane.message("Инструментальный трек")
            case .missing: pane.message("В LRCLIB пока нет текста этой песни")
            case .failed: pane.message("Не удалось загрузить текст", retryable: true)
            }
        } else {
            pane.message(track == nil ? "Текст появится, когда начнётся песня" : "Для поиска слов нужны название и исполнитель")
        }
    }

    private func load(_ query: LyricsLookup.Request) {
        search = Task { [weak self, lyrics] in
            await lyrics.load(query)
            guard !Task.isCancelled, let self, self.request == query else { return }
            self.updateWords()
        }
    }

    @objc private func retryLyrics() {
        guard let request else { return }
        search?.cancel()
        wordsView?.message("Ищем текст песни…")
        load(request)
    }

    @objc private func copyWords() {
        guard let pane = wordsView, let text = pane.currentText, copy(text) else { return }
        pane.showCopied()
        copyFeedback?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.updateWords() }
        copyFeedback = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: reset)
    }

    @objc private func togglePin() { island.isPinned.toggle() }
    @objc private func toggleWords() { island.showsLyrics.toggle() }
    @objc private func playPause() { player.playPause() }
    @objc private func goPrevious() { player.previous() }
    @objc private func goNext() { player.next() }
    @objc private func connectPlayer() { player.connect() }
    @objc private func openPlayer() { player.openPlayer() }
    @objc private func copyTrack() {
        guard let track = player.track else { return }
        _ = copy([track.artist, track.title].filter { !$0.isEmpty }.joined(separator: " — "))
    }

    private func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}

extension ExpandedIslandView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if player.track != nil {
            menu.addItem(withTitle: "Скопировать название и исполнителя", action: #selector(copyTrack), keyEquivalent: "").target = self
        }
        if player.canOpenPlayer {
            menu.addItem(withTitle: "Открыть плеер", action: #selector(openPlayer), keyEquivalent: "").target = self
        }
    }
}

@MainActor private func label(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: "")
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = .white
    field.maximumNumberOfLines = 1
    field.lineBreakMode = .byTruncatingTail
    return field
}

@MainActor private final class IslandButton: NSButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        imageHugsTitle = true
        font = .systemFont(ofSize: 12, weight: .semibold)
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func style(_ symbol: String?, title: String = "", help: String, ink: NSColor = .white,
               fill: NSColor = .clear, size: CGFloat = 15) {
        toolTip = help
        setAccessibilityLabel(help)
        layer?.backgroundColor = fill.cgColor
        contentTintColor = ink
        imagePosition = symbol == nil ? .noImage : (title.isEmpty ? .imageOnly : .imageLeading)
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
        attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: ink, .font: font!])
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

@MainActor private final class LyricsPane: NSView {
    let copyButton = IslandButton()
    let retry = IslandButton()
    private let origin = label(10, .medium)
    private let info = label(13)
    private let rule = NSBox()
    private var scroller: NSScrollView?
    var currentText: String? { scroller?.isHidden == false ? (scroller?.documentView as? NSTextView)?.string : nil }
    override var isFlipped: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        rule.boxType = .separator
        origin.textColor = .lightGray
        info.alignment = .center
        for subview in [rule, origin, info, copyButton, retry] { addSubview(subview) }
        retry.style(nil, title: "Повторить", help: "Повторить поиск текста")
    }
    required init?(coder: NSCoder) { nil }

    func message(_ text: String, retryable: Bool = false) {
        info.stringValue = text
        info.isHidden = false
        scroller?.isHidden = true
        origin.isHidden = true
        copyButton.isHidden = true
        retry.isHidden = !retryable
        needsLayout = true
    }

    func show(text: String, source: String, accent: NSColor) {
        if scroller == nil {
            let scroll = NSTextView.scrollableTextView()
            scroll.drawsBackground = false
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            let view = scroll.documentView as! NSTextView
            view.drawsBackground = false
            view.isRichText = false
            view.isEditable = false
            view.isSelectable = true
            view.font = .systemFont(ofSize: 15, weight: .medium)
            view.textColor = .white
            view.textContainerInset = CGSize(width: 0, height: 2)
            scroller = scroll
            addSubview(scroll)
        }
        let view = scroller?.documentView as? NSTextView
        if view?.string != text {
            view?.string = text
            view?.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        origin.stringValue = source
        origin.isHidden = false
        scroller?.isHidden = false
        info.isHidden = true
        retry.isHidden = true
        copyButton.isHidden = false
        copyButton.style("doc.on.doc", title: "Скопировать", help: "Скопировать текст песни", ink: accent, size: 10)
        needsLayout = true
    }

    func showCopied() { copyButton.style("checkmark", title: "Скопировано", help: "Текст скопирован", size: 10) }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        rule.frame = CGRect(x: 0, y: 0, width: w, height: 1)
        origin.frame = CGRect(x: 0, y: 6, width: max(0, w - 105), height: 18)
        copyButton.frame = CGRect(x: max(0, w - 102), y: 3, width: 102, height: 22)
        scroller?.frame = CGRect(x: 0, y: 28, width: w, height: max(0, h - 28))
        info.frame = CGRect(x: 0, y: max(2, h / 2 - (retry.isHidden ? 9 : 22)), width: w, height: 21)
        retry.frame = CGRect(x: max(0, (w - 100) / 2), y: h / 2 + 3, width: 100, height: 26)
    }
}
