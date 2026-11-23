import AppKit
import EventKit

private enum CalendarAccess {
    case readable, requestable, denied, restricted

    static var current: Self {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            if status == .fullAccess { return .readable }
            if status == .writeOnly { return .requestable }
        } else if status == .authorized { return .readable }
        switch status {
        case .notDetermined: return .requestable
        case .restricted: return .restricted
        default: return .denied
        }
    }
}

private struct AgendaEvent {
    let title: String
    let calendarName: String
    let color: CGColor?
    let start: Date
    let end: Date
    let allDay: Bool

    func timeLabel(in day: DateInterval, calendar: Calendar) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "ru_RU"),
                                    calendar: calendar, timeZone: calendar.timeZone)
        if allDay || (start < day.start && end >= day.end) { return "Весь день" }
        if start < day.start { return "до " + end.formatted(time) }
        if end > day.end { return "с " + start.formatted(time) }
        return start.formatted(time)
    }
}

/// EventKit handles stay on this actor. The view receives only the selected day's display data.
private actor DayEventReader {
    private lazy var store = EKEventStore()

    func request() async throws -> Bool {
        if #available(macOS 14.0, *) { return try await store.requestFullAccessToEvents() }
        return try await store.requestAccess(to: .event)
    }

    func events(in interval: DateInterval) -> [AgendaEvent] {
        guard !Task.isCancelled, CalendarAccess.current == .readable else { return [] }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return store.events(matching: predicate).compactMap { event in
            guard event.status != .canceled, let start = event.startDate, let end = event.endDate,
                  start < interval.end, end > interval.start || start == interval.start else { return nil }
            return AgendaEvent(title: event.title?.isEmpty == false ? event.title : "Без названия",
                               calendarName: event.calendar?.title ?? "", color: event.calendar?.cgColor,
                               start: start, end: end, allDay: event.isAllDay)
        }.sorted { a, b in
            if a.allDay != b.allDay { return a.allDay }
            if a.start != b.start { return a.start < b.start }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    func nextStart(from date: Date, calendar: Calendar) -> Date? {
        guard !Task.isCancelled, CalendarAccess.current == .readable,
              let end = calendar.date(byAdding: .day, value: 30, to: date) else { return nil }
        let predicate = store.predicateForEvents(withStart: date, end: end, calendars: nil)
        return store.events(matching: predicate).lazy
            .filter { $0.status != .canceled && $0.startDate >= date && $0.startDate < end }
            .map(\.startDate).min()
    }
}

/// A month is laid out in full local weeks; an adjacent-month date remains selectable.
struct CalendarMonth {
    let dates: [Date]
    let interval: DateInterval

    init?(containing date: Date, calendar: Calendar) {
        guard let month = calendar.dateInterval(of: .month, for: date),
              let days = calendar.range(of: .day, in: .month, for: date) else { return nil }
        interval = month
        let leading = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
        let cellCount = (leading + days.count + 6) / 7 * 7
        dates = (0..<cellCount).compactMap {
            calendar.date(byAdding: .day, value: $0 - leading, to: month.start)
        }
    }

    func contains(_ date: Date) -> Bool { date >= interval.start && date < interval.end }
}

@MainActor
final class CalendarPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let reader = DayEventReader()
    private let weekdayLabels = (0..<7).map { _ in NSTextField(labelWithString: "") }
    private var dateButtons: [MonthDateButton] = []
    private var month: CalendarMonth?
    private var selectedButton: MonthDateButton?
    private let dateFormatter = DateFormatter()
    private let agendaDate = NSTextField(labelWithString: "")
    private let divider = NSBox()
    private let heading = NSTextField(labelWithString: "")
    private let today = CalendarButton(title: "Сегодня", target: nil, action: nil)
    private let previous = CalendarButton()
    private let next = CalendarButton()
    private let open = CalendarButton()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let action = CalendarButton()
    private var scroll: NSScrollView?
    private var table: NSTableView? { scroll?.documentView as? NSTableView }
    private var rows: [AgendaEvent] = []
    // Store a civil day so changing time zones keeps an explicitly selected date.
    private var selectedDay: DateComponents? // nil follows today, including midnight.
    private var query: Task<Void, Never>?
    private var observing = false
    private var requesting = false
    private var lastAccess: CalendarAccess?
    private var emptyAction: EmptyAction?
    private enum EmptyAction { case request, settings, findNext }
    private var calendar: Calendar { .autoupdatingCurrent }
    private var day: DateInterval {
        let chosen = selectedDay.flatMap { calendar.date(from: $0) } ?? Date()
        return calendar.dateInterval(of: .day, for: chosen) ?? .init(start: chosen, duration: 0)
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.textColor = .white
        heading.lineBreakMode = .byTruncatingTail
        today.target = self
        today.action = #selector(goToday)
        today.toolTip = "Вернуться к сегодняшнему дню"
        setup(previous, image: "chevron.left", help: "Предыдущий месяц", perform: #selector(goBack))
        setup(next, image: "chevron.right", help: "Следующий месяц", perform: #selector(goForward))
        setup(open, image: "arrow.up.forward.app", help: "Открыть приложение Календарь", perform: #selector(openCalendar))
        agendaDate.font = .systemFont(ofSize: 11, weight: .semibold)
        agendaDate.textColor = .white
        divider.boxType = .separator
        for label in weekdayLabels {
            label.font = .systemFont(ofSize: 10, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        message.alignment = .left
        message.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize: 13)
        action.target = self
        action.action = #selector(performEmptyAction)
        for button in [today, action] {
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor
            button.setButtonType(.momentaryChange)
        }
        today.setCaption("Сегодня")
        for view in [heading, today, previous, next, open, agendaDate, divider, message, action] { addSubview(view) }
    }

    required init?(coder: NSCoder) { nil }

    private func showEvents(_ events: [AgendaEvent]) {
        rows = events
        if let scroll, let table {
            table.reloadData()
            scroll.contentView.scroll(to: .zero)
            scroll.isHidden = false
        } else {
            installEventList()
        }
        message.isHidden = true
        action.isHidden = true
    }

    private func installEventList() {
        let table = NSTableView()
        let column = NSTableColumn(identifier: .init("event"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.style = .plain
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.rowHeight = 34
        table.intercellSpacing = .zero
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel("События за выбранный день")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        self.scroll = scroll
        addSubview(scroll)
        table.reloadData()
        needsLayout = true
    }

    private func setup(_ button: NSButton, image: String, help: String, perform: Selector) {
        button.isBordered = false
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: image, accessibilityDescription: help)
        button.contentTintColor = .lightGray
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.target = self
        button.action = perform
    }

    override func layout() {
        super.layout()
        let left: CGFloat = 16
        let right = bounds.width - left
        open.frame = CGRect(x: right - 25, y: 3, width: 25, height: 26)
        next.frame = CGRect(x: open.frame.minX - 31, y: 3, width: 25, height: 26)
        previous.frame = CGRect(x: next.frame.minX - 26, y: 3, width: 25, height: 26)
        today.frame = CGRect(x: previous.frame.minX - 65, y: 3, width: 62, height: 26)
        heading.frame = CGRect(x: left, y: 6, width: max(0, today.frame.minX - left - 5), height: 24)
        let width = max(0, right - left)
        let cellWidth = width / 7
        let rowHeight: CGFloat = 21
        for (index, label) in weekdayLabels.enumerated() {
            label.frame = CGRect(x: left + CGFloat(index) * cellWidth, y: 33, width: cellWidth, height: 14)
        }
        for (index, button) in dateButtons.enumerated() {
            button.frame = CGRect(x: left + CGFloat(index % 7) * cellWidth, y: 47 + CGFloat(index / 7) * rowHeight,
                                  width: cellWidth, height: rowHeight)
        }
        let dividerY = 50 + CGFloat(dateButtons.count / 7) * rowHeight
        divider.frame = CGRect(x: left, y: dividerY, width: width, height: 1)
        agendaDate.frame = CGRect(x: left, y: dividerY + 4, width: width, height: 16)
        let agendaY = dividerY + 21
        if let scroll, let table {
            scroll.frame = CGRect(x: left, y: agendaY, width: width, height: max(0, bounds.height - agendaY - 4))
            let listWidth = scroll.contentSize.width
            table.setFrameSize(CGSize(width: listWidth, height: table.frame.height))
            table.tableColumns.first?.width = listWidth
        }
        let buttonWidth = action.isHidden ? 0 : min(148, ceil(action.attributedTitle.size().width) + 18)
        message.frame = CGRect(x: left, y: agendaY + 3, width: max(0, width - buttonWidth - 5), height: 30)
        action.frame = CGRect(x: right - buttonWidth, y: agendaY, width: buttonWidth, height: 22)
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateObservation() }
    override func viewDidHide() { super.viewDidHide(); updateObservation() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateObservation() }

    private func updateObservation() {
        let visible = window != nil && !isHiddenOrHasHiddenAncestor
        guard observing != visible else { return }
        observing = visible
        if visible {
            month = nil  // Calendar settings or today's date may have changed while hidden.
            let center = NotificationCenter.default
            for name in [Notification.Name.EKEventStoreChanged, .NSCalendarDayChanged, .NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
                center.addObserver(self, selector: #selector(calendarChanged(_:)), name: name, object: nil)
            }
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(checkAccess),
                                                               name: NSWorkspace.didActivateApplicationNotification, object: nil)
            reloadDay()
        } else {
            NotificationCenter.default.removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            query?.cancel()
            query = nil
            rows.removeAll()
            table?.reloadData()
        }
    }

    // EventKit can post from a background thread.
    @objc nonisolated private func calendarChanged(_ notification: Notification) {
        let settingsChanged = notification.name != .EKEventStoreChanged
        Task { @MainActor [weak self] in
            if settingsChanged { self?.month = nil }
            self?.reloadDay()
        }
    }
    @objc nonisolated private func checkAccess() {
        Task { @MainActor [weak self] in
            guard let self, self.lastAccess != CalendarAccess.current else { return }
            self.reloadDay()
        }
    }

    private func displayHeader(for date: Date) {
        let cal = calendar
        if month?.contains(date) != true {
            populateMonth(containing: date, calendar: cal)
        }
        guard let dates = month?.dates,
              let index = dates.firstIndex(of: date) ?? dates.firstIndex(where: { cal.isDate($0, inSameDayAs: date) })
        else { return }
        let button = dateButtons[index]
        guard selectedButton !== button else { return }
        selectedButton?.setSelected(false)
        selectedButton = button
        button.setSelected(true)
        agendaDate.stringValue = "События · " + dateFormatter.string(from: date)
        today.isEnabled = !cal.isDateInToday(date)
    }

    private func populateMonth(containing date: Date, calendar cal: Calendar) {
        guard let grid = CalendarMonth(containing: date, calendar: cal) else { return }
        selectedButton?.setSelected(false)
        selectedButton = nil
        month = grid
        dateFormatter.locale = Locale(identifier: "ru_RU")
        dateFormatter.calendar = cal
        dateFormatter.timeZone = cal.timeZone
        dateFormatter.dateFormat = "LLLL yyyy"
        heading.stringValue = dateFormatter.string(from: date).capitalized(with: dateFormatter.locale)
        let names = dateFormatter.shortStandaloneWeekdaySymbols ?? []
        for (index, label) in weekdayLabels.enumerated() where names.count == 7 {
            label.stringValue = names[(cal.firstWeekday - 1 + index) % 7].capitalized(with: dateFormatter.locale)
        }
        dateFormatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM yyyy")
        while dateButtons.count < grid.dates.count {
            let button = MonthDateButton(frame: .zero)
            button.target = self
            button.action = #selector(selectDate(_:))
            button.tag = dateButtons.count
            dateButtons.append(button)
            addSubview(button)
        }
        while dateButtons.count > grid.dates.count { dateButtons.removeLast().removeFromSuperview() }
        let now = Date()
        for (index, cellDate) in grid.dates.enumerated() {
            let button = dateButtons[index]
            button.configure(number: cal.component(.day, from: cellDate), inMonth: grid.contains(cellDate),
                             today: cal.isDate(cellDate, inSameDayAs: now), dateLabel: dateFormatter.string(from: cellDate))
        }
        dateFormatter.dateFormat = "d MMMM"  // Reused for the agenda as the selection moves.
        needsLayout = true
    }

    private func reloadDay() {
        guard observing else { return }
        query?.cancel()
        let interval = day
        displayHeader(for: interval.start)
        lastAccess = CalendarAccess.current
        switch lastAccess {
        case .readable: break
        case .requestable:
            displayMessage(requesting ? "Ожидание разрешения…" : "События не подключены",
                           action: requesting ? nil : .request)
            return
        case .denied:
            displayMessage("Доступ к событиям выключен", action: .settings)
            return
        default:
            displayMessage("Доступ к событиям ограничен")
            return
        }
        displayMessage("Загрузка событий…")
        query = Task { [weak self, reader] in
            let events = await reader.events(in: interval)
            guard !Task.isCancelled, let self, self.observing else { return }
            if events.isEmpty { self.displayMessage("На этот день событий нет", action: .findNext) }
            else { self.showEvents(events) }
        }
    }

    private func displayMessage(_ text: String, action kind: EmptyAction? = nil) {
        if !rows.isEmpty {
            rows.removeAll()
            table?.reloadData()
        }
        scroll?.isHidden = true
        guard message.isHidden || message.stringValue != text || emptyAction != kind else { return }
        message.stringValue = text
        message.isHidden = false
        emptyAction = kind
        action.isHidden = kind == nil
        switch kind {
        case .request: action.setCaption("Разрешить доступ")
        case .settings: action.setCaption("Открыть настройки")
        case .findNext: action.setCaption("Найти ближайшее")
        case nil: break
        }
        needsLayout = true
    }

    @objc private func goToday() { choose(Date()) }
    @objc private func goBack() { moveMonth(-1) }
    @objc private func goForward() { moveMonth(1) }
    private func moveMonth(_ delta: Int) {
        guard let moved = calendar.date(byAdding: .month, value: delta, to: day.start) else { return }
        choose(moved)
    }
    @objc private func selectDate(_ sender: MonthDateButton) {
        guard let month, month.dates.indices.contains(sender.tag) else { return }
        choose(month.dates[sender.tag])
    }
    private func choose(_ date: Date) {
        selectedDay = calendar.isDateInToday(date) ? nil : calendar.dateComponents([.era, .year, .month, .day], from: date)
        reloadDay()
    }

    @objc private func openCalendar() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    @objc private func performEmptyAction() {
        switch emptyAction {
        case .request:
            guard !requesting else { return }
            requesting = true
            reloadDay()
            Task { [weak self, reader] in
                do {
                    _ = try await reader.request()
                    self?.requesting = false
                    self?.reloadDay()
                } catch {
                    guard let self else { return }
                    self.requesting = false
                    if CalendarAccess.current == .requestable {
                        self.displayMessage("Не удалось запросить доступ к календарям.", action: .request)
                    } else { self.reloadDay() }
                }
            }
        case .settings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        case .findNext:
            let start = max(Date(), day.end)
            let localCalendar = calendar
            query?.cancel()
            displayMessage("Ищем ближайшее событие…")
            query = Task { [weak self, reader] in
                let found = await reader.nextStart(from: start, calendar: localCalendar)
                guard !Task.isCancelled, let self, self.observing else { return }
                if let found {
                    self.choose(found)
                } else { self.displayMessage("В следующие 30 дней событий нет") }
            }
        case nil: break
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("dayEvent")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CalendarEventRow ?? CalendarEventRow()
        cell.identifier = id
        let event = rows[row]
        cell.show(title: event.title, calendarName: event.calendarName, color: event.color,
                  time: event.timeLabel(in: day, calendar: calendar))
        return cell
    }
}

private final class CalendarButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setCaption(_ title: String) {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ])
    }
}

/// One ordinary AppKit control per visible date; no layer or timer is needed for the grid.
private final class MonthDateButton: NSButton {
    private static let accent = NSColor(srgbRed: 1, green: 0.57, blue: 0.55, alpha: 1)
    private var inMonth = true
    private var selectedDay = false
    private var currentDay = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .default
        setAccessibilityValue("")
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(number: Int, inMonth: Bool, today: Bool, dateLabel: String) {
        title = String(number)
        self.inMonth = inMonth
        currentDay = today
        setAccessibilityLabel(dateLabel + (today ? ", сегодня" : ""))
        needsDisplay = true
    }

    func setSelected(_ selected: Bool) {
        selectedDay = selected
        setAccessibilityValue(selected ? "Выбрано" : "")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.height - 1, 21)
        let circle = NSBezierPath(ovalIn: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                                                 width: side, height: side))
        if selectedDay || isHighlighted {
            (currentDay ? Self.accent : NSColor(white: isHighlighted ? 0.75 : 0.93, alpha: 1)).setFill()
            circle.fill()
        } else if currentDay {
            Self.accent.setStroke()
            circle.lineWidth = 1
            circle.stroke()
        }
        let color: NSColor = selectedDay || isHighlighted ? .black : (currentDay ? Self.accent :
            NSColor(white: inMonth ? 0.94 : 0.46, alpha: 1))
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: selectedDay || currentDay ? .bold : .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let text = title as NSString, size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: round(bounds.midX - size.width / 2), y: round(bounds.midY - size.height / 2)),
                  withAttributes: attrs)
    }
}

private final class CalendarEventRow: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let source = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let marker = NSView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        source.font = .systemFont(ofSize: 11)
        source.textColor = .secondaryLabelColor
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        time.textColor = .secondaryLabelColor
        time.alignment = .right
        marker.wantsLayer = true
        marker.layer?.cornerRadius = 1.5
        for view in [marker, title, source, time] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }

    func show(title: String, calendarName: String, color: CGColor?, time: String) {
        self.title.stringValue = title
        source.stringValue = calendarName
        self.time.stringValue = time
        marker.layer?.backgroundColor = color ?? NSColor.systemBlue.cgColor
        toolTip = [title, time, calendarName].filter { !$0.isEmpty }.joined(separator: " · ")
        setAccessibilityLabel(toolTip)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let w = bounds.width
        let tw = min(80, ceil(time.intrinsicContentSize.width) + 4)
        let content = max(0, w - tw - 18)
        marker.frame = CGRect(x: 1, y: 5, width: 3, height: 24)
        title.frame = CGRect(x: 10, y: 16, width: content, height: 18)
        source.frame = CGRect(x: 10, y: 2, width: content, height: 15)
        time.frame = CGRect(x: w - tw, y: 10, width: tw, height: 16)
    }
}
