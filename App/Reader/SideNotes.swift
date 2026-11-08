import UIKit

/// En anteckning till en sida (PDF) eller ett kapitel (EPUB och text), K12.
struct PageNote: Equatable {
    let book: String
    let section: Int
    var text: String
    var updated: Date
}

/// Anteckningarna bredvid texten, i tabellen `page_notes` i markeringar.sqlite (steg 8 i trappan, följer med i
/// säkerhetskopian). En per bok och sida. Inget raderas: en tömd anteckning får `deleted = 1`. Bara huvudtråden.
final class PageNoteStore {

    static let shared = PageNoteStore()

    private init() {}

    func note(book: String, section: Int) -> String {
        var result = ""
        AnnotationStore.shared.readBooks { db in
            try db.query("SELECT text FROM page_notes WHERE book = ? AND section = ? AND deleted = 0",
                         [book, section]) { result = $0.string(0) }
        }
        return result
    }

    func notes(book: String) -> [PageNote] {
        var result: [PageNote] = []
        AnnotationStore.shared.readBooks { db in
            try db.query("""
                SELECT book, section, text, updated FROM page_notes WHERE book = ? AND deleted = 0 ORDER BY section
                """, [book]) { row in
                result.append(PageNote(book: row.string(0), section: row.int(1), text: row.string(2),
                                       updated: Date(timeIntervalSince1970: row.double(3))))
            }
        }
        return result
    }

    /// Sparar texten, eller markerar anteckningen som borttagen när den är tom. Samma text gör ingenting.
    func save(book: String, section: Int, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != note(book: book, section: section).trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        let now = Date().timeIntervalSince1970
        AnnotationStore.shared.writeBooks("anteckningen bredvid texten") { db in
            try db.execute("""
                INSERT INTO page_notes (book, section, text, created, updated, deleted) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(book, section) DO UPDATE SET text = excluded.text, updated = excluded.updated,
                    deleted = excluded.deleted
                """, [book, section, trimmed, now, now, trimmed.isEmpty ? 1 : 0])
        }
        NotificationCenter.default.post(name: AnnotationStore.didChange, object: book)
    }
}

/// Panelen Anteckningar bredvid texten (K12). Första versionen ligger OVANPÅ sidan vid högerkanten i stället för
/// att göra sidan smalare, så att sidans storlek, renderingen och pappersvikningen är helt orörda (CLAUDE.md,
/// regler för läsaren). Läsarna stänger av sina egna tryck i panelen (`shouldReceive`).
final class SideNotesPanel: UIView, UITextViewDelegate {

    static let width: CGFloat = 320

    var onClose: (() -> Void)?

    private let titleLabel = UILabel()
    private let headerLabel = UILabel()
    private let textView = UITextView()
    private let placeholder = UILabel()
    private var book = ""
    private var section = -1
    /// D4-3: sparningen en sekund efter senaste ändringen, och observatörerna för bakgrunden.
    private var pendingSave: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    /// Antalet sparningar medan man skriver, till självtestet.
    private(set) var savesWhileTyping = 0

    /// Sidan som panelen visar, till självtestet.
    var shownSection: Int {
        section
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 16
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 4)
        let header = headerLabel
        header.text = "ANTECKNINGAR"
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.font = Theme.serif(.headline, size: 17, weight: .semibold)
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        close.accessibilityLabel = "Stäng anteckningarna"
        close.addAction(UIAction { [weak self] _ in
            self?.onClose?()
        }, for: .touchUpInside)
        let titles = UIStackView(arrangedSubviews: [header, titleLabel])
        titles.axis = .vertical
        titles.spacing = 2
        let top = UIStackView(arrangedSubviews: [titles, close])
        top.alignment = .top
        top.translatesAutoresizingMaskIntoConstraints = false
        addSubview(top)
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.layer.cornerRadius = 10
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        textView.delegate = self
        textView.accessibilityLabel = "Anteckning till sidan"
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        placeholder.text = "Frågor och egna formuleringar medan du läser."
        placeholder.numberOfLines = 0
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isUserInteractionEnabled = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textView.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 10),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 11),
            placeholder.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -11),
        ])
        applyTheme()
        // D4-3: det som skrivits sparas när appen lämnar förgrunden, så att inget försvinner om iOS avslutar
        // appen i bakgrunden.
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.saveNow()
            })
        }
    }

    deinit {
        pendingSave?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    func applyTheme() {
        let palette = Theme.current
        backgroundColor = palette.surface
        layer.shadowColor = UIColor.black.cgColor
        titleLabel.textColor = palette.ink
        textView.backgroundColor = palette.surfaceSunk
        textView.textColor = palette.ink
        placeholder.textColor = palette.inkFaint
        headerLabel.textColor = palette.inkSoft
    }

    /// Visar anteckningen för en sida. Den förra sparas först.
    func show(book: String, section: Int, title: String) {
        guard book != self.book || section != self.section else {
            titleLabel.text = title
            return
        }
        saveNow()
        self.book = book
        self.section = section
        titleLabel.text = title
        textView.text = PageNoteStore.shared.note(book: book, section: section)
        placeholder.isHidden = !textView.text.isEmpty
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard !book.isEmpty, section >= 0 else { return }
        PageNoteStore.shared.save(book: book, section: section, text: textView.text ?? "")
    }

    /// D4-3: sparar en sekund efter senaste ändringen medan man skriver.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingSave = nil
            self.savesWhileTyping += 1
            self.saveNow()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Självtestet: skriv en text som om den skrivits för hand. Sparas av fördröjningen, inte av ett anrop.
    func typeForSelfTest(_ text: String) {
        textView.text = text
        textViewDidChange(textView)
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        scheduleSave()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        saveNow()
    }

    /// Lägger panelen vid läsarens högerkant, under menyraden och ovanför tangentbordet.
    static func install(_ panel: SideNotesPanel, in view: UIView) {
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        let width = min(Self.width, view.bounds.width - 32)
        let preferredBottom = panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -64)
        preferredBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            panel.widthAnchor.constraint(equalToConstant: max(width, 240)),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            preferredBottom,
        ])
        panel.alpha = 0
        panel.transform = CGAffineTransform(translationX: 40, y: 0)
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
            panel.alpha = 1
            panel.transform = .identity
        }
    }

    func remove() {
        saveNow()
        textView.resignFirstResponder()
        UIView.animate(withDuration: 0.2, animations: {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: 40, y: 0)
        }, completion: { _ in
            self.removeFromSuperview()
            self.transform = .identity
        })
    }
}
