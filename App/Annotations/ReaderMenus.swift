import UIKit

/// Delar av läsarnas menyer som är lika i PDF- och EPUB-läsaren.
@MainActor
enum ReaderMenus {

    /// Bläddringsljudet, som en del av menyn Bakgrund. `onChange` bygger om menyn så att bocken stämmer.
    static func soundSection(onChange: @escaping () -> Void) -> UIMenu {
        let on = ReaderSettings.pageSound
        let action = UIAction(title: "Bläddringsljud",
                              image: UIImage(systemName: on ? "speaker.wave.2" : "speaker.slash"),
                              state: on ? .on : .off) { _ in
            ReaderSettings.pageSound = !on
            if !on {
                PageTurnSound.shared.play()
            }
            onChange()
        }
        return UIMenu(title: "", options: .displayInline, children: [action])
    }

    /// Knapparna för sökning, markering och bokmärke, i den ordning de ska stå i menyraden (från höger).
    static func annotationItems(target: Any, search: Selector, mark: Selector, bookmark: Selector) -> [UIBarButtonItem] {
        let searchItem = UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"), style: .plain,
                                         target: target, action: search)
        searchItem.accessibilityLabel = "Sök i boken"
        let markItem = UIBarButtonItem(image: UIImage(systemName: "highlighter"), style: .plain,
                                       target: target, action: mark)
        markItem.accessibilityLabel = "Markera text"
        let bookmarkItem = UIBarButtonItem(image: UIImage(systemName: "bookmark"), style: .plain,
                                           target: target, action: bookmark)
        bookmarkItem.accessibilityLabel = "Bokmärke"
        return [searchItem, markItem, bookmarkItem]
    }

    /// Raden som visas medan man markerar, nere på sidan.
    static func installModeBar(_ bar: HighlightModeBar, in view: UIView) {
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14),
            bar.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -24),
        ])
    }
}

/// Hur datum och platser skrivs i listorna.
enum AnnotationFormat {

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sv_SE")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func date(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    /// De första orden i en text, högst `limit` tecken.
    static func excerpt(_ text: String, limit: Int = 70) -> String {
        let cleaned = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard cleaned.count > limit else { return cleaned }
        let cut = cleaned.prefix(limit)
        if let space = cut.lastIndex(of: " ") {
            return String(cut[..<space]) + " …"
        }
        return String(cut) + " …"
    }
}
