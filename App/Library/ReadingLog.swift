import UIKit

/// Läsloggen (K10): vilka sidor man läst och hur länge, per dag och bok, lokalt i markeringar.sqlite
/// (tabellen `reading_log`, steg 7 i trappan, följer med i säkerhetskopian). Ingen svit och inga notiser.
///
/// Läsarna anropar `pageShown` när sidan byts. Det sparas bara i minnet: tiden räknas på sidan som syns,
/// en sida räknas som läst efter `minimumSeconds`, och en sida som ligger framme längre än `idleCap` räknas
/// som `idleCap` (man har lagt ifrån sig iPaden). Databasen skrivs högst en gång i minuten och när läsaren
/// stängs eller appen går i bakgrunden, aldrig vid varje sidvändning. Används bara från huvudtråden.
final class ReadingLog {

    static let shared = ReadingLog()
    static let didChange = Notification.Name("ReadingLogDidChange")

    static let minimumSeconds: TimeInterval = 4
    static let idleCap: TimeInterval = 300
    private static let flushInterval: TimeInterval = 60

    struct Page: Hashable {
        /// PDF: sidans plats i filen. EPUB: kapitlet och sidan i kapitlet.
        let key: String
        /// 0 till 1 i boken, samma skala som tidslinjen.
        let position: Double
    }

    private struct Visit {
        let book: String
        let pages: [Page]
        var since: Date
    }

    private struct PendingKey: Hashable {
        let day: String
        let book: String
        let page: String
    }

    private var current: Visit?
    private var pending: [PendingKey: (position: Double, seconds: Double)] = [:]
    private var lastFlush = Date()
    private var timer: Timer?

    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            self?.appWillResign()
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            self?.appDidBecomeActive()
        })
    }

    /// Sidorna som syns nu (en, eller två i ett uppslag). Samma sidor igen gör ingenting.
    func pageShown(book: String, pages: [Page], at date: Date = Date()) {
        guard !pages.isEmpty else { return }
        if let current = current, current.book == book, current.pages == pages {
            return
        }
        close(at: date)
        current = Visit(book: book, pages: pages, since: date)
        startTimer()
    }

    /// Läsaren stängs: tiden på sidan som syns räknas, och allt sparas.
    func pause(at date: Date = Date()) {
        close(at: date)
        current = nil
        timer?.invalidate()
        timer = nil
        flush()
    }

    private func appWillResign() {
        guard current != nil else { return }
        close(at: Date())
        flush()
    }

    private func appDidBecomeActive() {
        // Tiden i bakgrunden räknas inte: sidan som syns börjar om nu.
        current?.since = Date()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let visit = current else { return }
        let now = Date()
        // Tiden hittills på sidan räknas utan att sidan byts, så att en lång sida inte tappas vid en krasch.
        let elapsed = now.timeIntervalSince(visit.since)
        if elapsed >= Self.minimumSeconds, elapsed < Self.idleCap {
            add(visit, seconds: elapsed, at: now)
            current?.since = now
        }
        if now.timeIntervalSince(lastFlush) >= Self.flushInterval {
            flush()
        }
    }

    private func close(at date: Date) {
        guard let visit = current else { return }
        let elapsed = date.timeIntervalSince(visit.since)
        guard elapsed >= Self.minimumSeconds || hasPending(visit, at: date) else { return }
        add(visit, seconds: min(max(elapsed, 0), Self.idleCap), at: date)
    }

    private func hasPending(_ visit: Visit, at date: Date) -> Bool {
        let day = ReadingWeek.dayKey(date)
        return visit.pages.contains { pending[PendingKey(day: day, book: visit.book, page: $0.key)] != nil }
    }

    private func add(_ visit: Visit, seconds: TimeInterval, at date: Date) {
        let day = ReadingWeek.dayKey(date)
        let share = seconds / Double(visit.pages.count)
        for page in visit.pages {
            let key = PendingKey(day: day, book: visit.book, page: page.key)
            let old = pending[key]?.seconds ?? 0
            pending[key] = (page.position, old + share)
        }
    }

    /// Skriver det som samlats i minnet, i en transaktion.
    func flush() {
        lastFlush = Date()
        guard !pending.isEmpty else { return }
        let rows = pending
        pending = [:]
        AnnotationStore.shared.writeBooks("läsloggen") { db in
            for (key, value) in rows {
                try db.execute("""
                    INSERT INTO reading_log (day, book, page, position, seconds) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(day, book, page) DO UPDATE SET seconds = seconds + excluded.seconds,
                        position = excluded.position
                    """, [key.day, key.book, key.page, value.position, value.seconds])
            }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: Läsa

    /// Lästid i sekunder och antal lästa sidor per dag (`yyyy-MM-dd`), från och med `from`.
    func days(from: String) -> [String: ReadingWeek.Day] {
        var result: [String: ReadingWeek.Day] = [:]
        AnnotationStore.shared.readBooks { db in
            try db.query("SELECT day, SUM(seconds), COUNT(*) FROM reading_log WHERE day >= ? GROUP BY day", [from]) { row in
                result[row.string(0)] = ReadingWeek.Day(seconds: row.double(1), pages: row.int(2))
            }
        }
        // Det som ännu bara finns i minnet räknas med.
        for (key, value) in pending where key.day >= from {
            var day = result[key.day] ?? ReadingWeek.Day(seconds: 0, pages: 0)
            day.seconds += value.seconds
            result[key.day] = day
        }
        return result
    }

    /// De lästa delarna av en bok på tidslinjens skala (0 till 1), ihopslagna när sidorna ligger tätt.
    func readRanges(book: String, step: Double) -> [ClosedRange<Double>] {
        var positions: [Double] = []
        AnnotationStore.shared.readBooks { db in
            try db.query("SELECT DISTINCT position FROM reading_log WHERE book = ?", [book]) { row in
                positions.append(row.double(0))
            }
        }
        positions += pending.filter { $0.key.book == book }.map { $0.value.position }
        return ReadingWeek.ranges(positions, step: step)
    }

    /// Nycklarna för bokens lästa sidor (PDF: sidans plats i filen), till Innehåll.
    func readPageKeys(book: String) -> Set<String> {
        var keys = Set(pending.keys.filter { $0.book == book }.map(\.page))
        AnnotationStore.shared.readBooks { db in
            try db.query("SELECT DISTINCT page FROM reading_log WHERE book = ?", [book]) { _ = keys.insert($0.string(0)) }
        }
        return keys
    }

    // MARK: Dagsmålet

    private static let goalKey = "reading.goal_minutes"

    /// Dagsmålet i minuter, 0 för inget. Ligger i tabellen `meta`, så att det följer med i säkerhetskopian.
    var goalMinutes: Int {
        get {
            var value = 0
            AnnotationStore.shared.readBooks { db in
                try db.query("SELECT value FROM meta WHERE key = ?", [Self.goalKey]) { value = Int($0.string(0)) ?? 0 }
            }
            return value
        }
        set {
            AnnotationStore.shared.writeBooks("dagsmålet") { db in
                try db.execute("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               [Self.goalKey, String(max(newValue, 0))])
            }
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }
}

/// Veckan i kortet överst i biblioteket (K10): måndag till söndag, lästid, sidor och dagar man läst.
/// Ren logik (G13).
struct ReadingWeek: Equatable {

    struct Day: Equatable {
        var seconds: Double
        var pages: Int
    }

    /// Veckans sju dagar från måndag, med dagens nyckel.
    let keys: [String]
    let days: [Day]
    let todayIndex: Int

    init(today: Date, log: [String: Day], calendar: Calendar = ReadingWeek.calendar) {
        let start = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        var keys: [String] = []
        for offset in 0..<7 {
            let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            keys.append(Self.dayKey(date, calendar: calendar))
        }
        self.keys = keys
        days = keys.map { log[$0] ?? Day(seconds: 0, pages: 0) }
        todayIndex = keys.firstIndex(of: Self.dayKey(today, calendar: calendar)) ?? 0
    }

    /// Svensk vecka: måndag först.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        calendar.timeZone = .current
        return calendar
    }

    /// Dagens nyckel i lokal tid, `yyyy-MM-dd` (aldrig UTC, så att kvällsläsning hamnar på rätt dag).
    static func dayKey(_ date: Date, calendar: Calendar = ReadingWeek.calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    var totalSeconds: Double {
        days.reduce(0) { $0 + $1.seconds }
    }

    var totalPages: Int {
        days.reduce(0) { $0 + $1.pages }
    }

    /// Dagar med minst en läst sida eller en minuts läsning.
    var daysRead: Int {
        days.filter { $0.pages > 0 || $0.seconds >= 60 }.count
    }

    /// "3 h 20 min", "45 min", "0 min".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded(.down))
        if minutes >= 60 {
            let rest = minutes % 60
            return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
        }
        return "\(minutes) min"
    }

    /// Raden i kortet: lästid, sidor och dagar.
    var summary: String {
        let pages = totalPages == 1 ? "1 sida" : "\(totalPages) sidor"
        return "\(Self.duration(totalSeconds)), \(pages), läst \(daysRead) av 7 dagar"
    }

    static let letters = ["M", "T", "O", "T", "F", "L", "S"]

    /// Lästa positioner som sträckor. `step` är en sidas längd på skalan: sidor närmare än en och en halv sida
    /// slås ihop.
    static func ranges(_ positions: [Double], step: Double) -> [ClosedRange<Double>] {
        let sorted = positions.map { min(max($0, 0), 1) }.sorted()
        guard var start = sorted.first else { return [] }
        var end = start
        var result: [ClosedRange<Double>] = []
        let gap = max(step, 0.0001) * 1.5
        for position in sorted.dropFirst() {
            if position - end <= gap {
                end = position
            } else {
                result.append(start...min(end + step, 1))
                start = position
                end = position
            }
        }
        result.append(start...min(end + step, 1))
        return result
    }
}

/// Kortet Läsvecka överst i biblioteket (K10): sju staplar, veckans lästid och sidor, och dagsmålet som en
/// tunn ring runt dagens stapel. Ett tryck väljer dagsmålet.
final class ReadingWeekCell: UICollectionViewCell {

    static let id = "lasvecka"
    static let height: CGFloat = 112
    /// Smal bredd (iPhone): texten får fler rader.
    static let compactHeight: CGFloat = 150

    var onGoal: (() -> Void)?

    private let title = UILabel()
    private let summary = UILabel()
    private let goal = UILabel()
    private let bars = ReadingBarsView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 14
        contentView.clipsToBounds = true
        title.text = "Läsvecka"
        title.font = Theme.serif(.headline, size: 17, weight: .semibold)
        summary.font = .preferredFont(forTextStyle: .subheadline)
        summary.numberOfLines = 2
        goal.font = .preferredFont(forTextStyle: .footnote)
        goal.numberOfLines = 2
        let text = UIStackView(arrangedSubviews: [title, summary, goal])
        text.axis = .vertical
        text.spacing = 3
        let row = UIStackView(arrangedSubviews: [text, bars])
        row.spacing = 16
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        bars.translatesAutoresizingMaskIntoConstraints = false
        let preferredWidth = bars.widthAnchor.constraint(equalToConstant: 196)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferredWidth,
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            bars.widthAnchor.constraint(lessThanOrEqualToConstant: 196),
            bars.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.4),
            bars.heightAnchor.constraint(equalToConstant: 84),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        contentView.addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    @objc private func tapped() {
        onGoal?()
    }

    func configure(week: ReadingWeek, goalMinutes: Int, palette: Palette) {
        contentView.backgroundColor = palette.surface
        title.textColor = palette.ink
        summary.textColor = palette.ink
        // Två rader med radbrytning i texten, så att raden inte kortas i en smal ruta (iPhone).
        summary.text = week.summary.replacingOccurrences(of: ", läst", with: ",\nläst")
        goal.textColor = palette.inkSoft
        let today = week.days[safe: week.todayIndex]?.seconds ?? 0
        if goalMinutes > 0 {
            goal.text = "I dag \(ReadingWeek.duration(today)) av \(goalMinutes) min."
        } else {
            goal.text = "I dag \(ReadingWeek.duration(today)). Tryck för dagsmål."
        }
        bars.week = week
        bars.goalSeconds = Double(goalMinutes * 60)
        bars.palette = palette
        bars.setNeedsDisplay()
        accessibilityLabel = "Läsvecka. \(week.summary). \(goal.text ?? "")"
    }
}

/// De sju staplarna, ritade själv (Apples Charts kräver iOS 16). En liten vy, ritas bara när kortet visas.
final class ReadingBarsView: UIView {

    var week: ReadingWeek?
    var goalSeconds: Double = 0
    var palette: Palette?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override func draw(_ rect: CGRect) {
        guard let week = week, let palette = palette, let context = UIGraphicsGetCurrentContext() else { return }
        let labelHeight: CGFloat = 16
        let top: CGFloat = 8
        let chartHeight = bounds.height - labelHeight - top
        let slot = bounds.width / 7
        let barWidth = min(slot * 0.5, 16)
        let largest = max(week.days.map(\.seconds).max() ?? 0, goalSeconds, 30 * 60)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: palette.inkSoft,
        ]
        for (index, day) in week.days.enumerated() {
            let centerX = slot * (CGFloat(index) + 0.5)
            let track = CGRect(x: centerX - barWidth / 2, y: top, width: barWidth, height: chartHeight)
            context.setFillColor(palette.surfaceSunk.cgColor)
            context.addPath(UIBezierPath(roundedRect: track, cornerRadius: barWidth / 2).cgPath)
            context.fillPath()
            if day.seconds > 0 {
                let height = max(CGFloat(day.seconds / largest) * chartHeight, barWidth)
                let bar = CGRect(x: track.minX, y: track.maxY - height, width: barWidth, height: height)
                context.setFillColor((index == week.todayIndex ? palette.accent : palette.accent.withAlphaComponent(0.55)).cgColor)
                context.addPath(UIBezierPath(roundedRect: bar, cornerRadius: barWidth / 2).cgPath)
                context.fillPath()
            }
            if index == week.todayIndex, goalSeconds > 0 {
                // Dagsmålet: en tunn ring runt dagens stapel som fylls medan man läser.
                let ring = track.insetBy(dx: -3, dy: -3)
                let path = UIBezierPath(roundedRect: ring, cornerRadius: ring.width / 2)
                context.setStrokeColor(palette.rule.cgColor)
                context.setLineWidth(1.5)
                context.addPath(path.cgPath)
                context.strokePath()
                let done = min(day.seconds / goalSeconds, 1)
                if done > 0 {
                    let goalLine = CGRect(x: ring.minX, y: ring.maxY - CGFloat(done) * ring.height,
                                          width: ring.width, height: CGFloat(done) * ring.height)
                    context.saveGState()
                    context.clip(to: goalLine)
                    context.setStrokeColor(palette.success.cgColor)
                    context.addPath(path.cgPath)
                    context.strokePath()
                    context.restoreGState()
                }
            }
            let letter = ReadingWeek.letters[index] as NSString
            let size = letter.size(withAttributes: attributes)
            letter.draw(at: CGPoint(x: centerX - size.width / 2, y: bounds.height - labelHeight + 2), withAttributes: attributes)
        }
    }
}
