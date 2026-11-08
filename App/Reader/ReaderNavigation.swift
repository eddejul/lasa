import UIKit

/// V4: platserna man hoppat ifrån, den senaste sist. Ren logik, samma i båda läsarna (testad i XCTest).
/// `Place` är en sida i PDF-läsaren och en plats i ett kapitel i EPUB-läsaren.
struct ReaderHistory<Place> {

    struct Entry {
        let place: Place
        /// Som platsen visas i Tillbaka och i listan, till exempel "s. 87".
        let label: String
    }

    /// Så många platser som sparas under ett besök i boken.
    static var limit: Int { 20 }
    /// Så många som visas när man håller på Tillbaka.
    static var shown: Int { 5 }

    private(set) var entries: [Entry] = []

    var isEmpty: Bool {
        entries.isEmpty
    }

    var last: Entry? {
        entries.last
    }

    /// De senaste platserna, den senaste först.
    var recent: [Entry] {
        Array(entries.suffix(Self.shown).reversed())
    }

    /// Sparar platsen man lämnar. Samma plats två gånger i rad sparas en gång.
    mutating func push(_ place: Place, label: String) {
        if entries.last?.label == label {
            entries.removeLast()
        }
        entries.append(Entry(place: place, label: label))
        if entries.count > Self.limit {
            entries.removeFirst(entries.count - Self.limit)
        }
    }

    /// Tar fram platsen `offset` steg bak (0 är den senaste) och glömmer den och alla nyare,
    /// som när man går tillbaka flera steg i en webbläsare.
    mutating func pop(_ offset: Int = 0) -> Entry? {
        guard offset >= 0, offset < entries.count else { return nil }
        let index = entries.count - 1 - offset
        let entry = entries[index]
        entries.removeSubrange(index...)
        return entry
    }
}

/// V4: Tillbaka i sidans nedre hörn. Ett tryck går tillbaka, ett långt tryck visar de fem senaste platserna,
/// och krysset (Stanna här) döljer knappen utan att glömma platserna. Färgerna följer temat (U1).
@MainActor
final class ReaderBackControl: UIView {

    let backButton = UIButton(type: .system)
    let stayButton = UIButton(type: .system)
    private let divider = UIView()

    /// Platsen `offset` steg bak (0 är den senaste).
    var onBack: ((Int) -> Void)?
    var onStay: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 19
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.borderWidth = 1 / UIScreen.main.scale

        backButton.setImage(UIImage(systemName: "arrow.uturn.backward"), for: .normal)
        backButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        backButton.titleLabel?.lineBreakMode = .byTruncatingTail
        backButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 12)
        backButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: -6)
        backButton.accessibilityHint = "Går tillbaka dit du var. Håll för att se de senaste platserna."
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)

        stayButton.setImage(UIImage(systemName: "xmark", withConfiguration:
                                        UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)), for: .normal)
        stayButton.accessibilityLabel = "Stanna här"
        stayButton.addTarget(self, action: #selector(stayTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [backButton, divider, stayButton])
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 38),
            divider.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            stayButton.widthAnchor.constraint(equalToConstant: 38),
            backButton.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
        apply(Theme.current)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    /// Knappens text ("Tillbaka till s. 87") och listan bakom ett långt tryck, den senaste först.
    func update(recent labels: [String]) {
        guard let first = labels.first else { return }
        backButton.setTitle("Tillbaka till \(first)", for: .normal)
        backButton.accessibilityLabel = "Tillbaka till \(first)"
        let actions = labels.enumerated().map { offset, label in
            UIAction(title: label, image: UIImage(systemName: offset == 0 ? "arrow.uturn.backward" : "clock.arrow.circlepath")) {
                [weak self] _ in
                self?.onBack?(offset)
            }
        }
        backButton.menu = UIMenu(title: "Senaste platser", children: actions)
        // Ett vanligt tryck går tillbaka, ett långt tryck visar listan.
        backButton.showsMenuAsPrimaryAction = false
    }

    /// Temats färger: papperet som bakgrund, texten i accentfärgen.
    func apply(_ palette: Palette) {
        backgroundColor = palette.surface
        layer.borderColor = palette.rule.cgColor
        divider.backgroundColor = palette.rule
        backButton.tintColor = palette.accent
        backButton.setTitleColor(palette.accent, for: .normal)
        stayButton.tintColor = palette.inkSoft
    }

    /// Texten på knappen, till självtestet.
    var title: String? {
        backButton.title(for: .normal)
    }

    @objc private func backTapped() {
        onBack?(0)
    }

    @objc private func stayTapped() {
        onStay?()
    }
}

/// V4: historiken och Tillbaka-knappen för en läsare (G12, gemensam för båda läsarna).
/// Läsaren sparar platsen den lämnar med `record` vid varje hopp och säger till när en sida vikts fram.
/// Knappen döljs efter tre vikningar, eller ligger kvar tills man går tillbaka eller stannar (V3, `sticky`).
@MainActor
final class ReaderBackStack<Place> {

    private(set) var history = ReaderHistory<Place>()
    let control = ReaderBackControl()
    /// Anropas när man går tillbaka. Läsaren hoppar dit utan att spara något nytt.
    var onGo: ((Place) -> Void)?
    /// Anropas när historiken ändras, så att läsaren kan bygga om listan i Mer.
    var onChange: (() -> Void)?

    private var turns = 0
    private var sticky = false

    /// Lägger knappen i läsarens vy, i nedre vänstra hörnet ovanför nederkanten. Dold tills första hoppet.
    func install(in view: UIView, above bottomBar: UIView) {
        control.translatesAutoresizingMaskIntoConstraints = false
        control.isHidden = true
        view.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            control.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -12),
            control.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
        control.onBack = { [weak self] offset in
            self?.goBack(offset)
        }
        control.onStay = { [weak self] in
            self?.hide()
        }
    }

    /// Sparar platsen man lämnar och visar Tillbaka. `sticky` (V3): knappen ligger kvar även när man bläddrar.
    func record(_ place: Place, label: String, sticky: Bool = false) {
        history.push(place, label: label)
        turns = 0
        self.sticky = sticky
        showControl()
        onChange?()
    }

    /// En sida har vikts fram. Efter tre vikningar har man stannat, och knappen döljs (platserna finns kvar i Mer).
    func pageTurned() {
        guard !control.isHidden, !sticky else { return }
        turns += 1
        if turns >= 3 {
            hide()
        }
    }

    /// Går till platsen `offset` steg bak och glömmer den och alla nyare.
    func goBack(_ offset: Int = 0) {
        guard let entry = history.pop(offset) else { return }
        hide()
        onChange?()
        onGo?(entry.place)
    }

    func hide() {
        sticky = false
        control.isHidden = true
    }

    var isShowing: Bool {
        !control.isHidden
    }

    /// De senaste platserna, den senaste först, till listan i Mer.
    var recentLabels: [String] {
        history.recent.map(\.label)
    }

    func apply(_ palette: Palette) {
        control.apply(palette)
    }

    private func showControl() {
        control.update(recent: recentLabels)
        control.isHidden = false
        control.superview?.bringSubviewToFront(control)
    }
}

/// V1: sidor kvar i kapitlet eller i boken, till höger i nederkanten. Ett tryck växlar, och valet gäller alla böcker.
/// Ingen tid kvar (Edvins beslut 8 november 2026), bara sidor.
enum PageInfo {

    enum Scope: String {
        case chapter, book
    }

    private static let key = "reader.pageInfoScope"

    /// Det som visas. En bok utan kapitel (en PDF utan innehållsförteckning) visar alltid boken.
    static var scope: Scope {
        get { Scope(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .chapter }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Byter till det andra läget och sparar det. Utan kapitel finns bara boken.
    static func toggle(hasChapters: Bool) {
        guard hasChapters else { return }
        scope = scope == .chapter ? .book : .chapter
    }

    /// Läget som gäller för en bok med eller utan kapitel.
    static func effectiveScope(hasChapters: Bool) -> Scope {
        hasChapters ? scope : .book
    }

    /// Sidorna kvar efter den sista sidan som syns, när avsnittet slutar före `end` (sidan efter avsnittets sista).
    static func pagesLeft(lastShown: Int, end: Int) -> Int {
        max(end - lastShown - 1, 0)
    }

    /// "9 sidor kvar i kapitlet", "1 sida kvar i boken", "Sista sidan i kapitlet".
    /// `estimated`: sidantalet är uppskattat (EPUB innan alla kapitel är mätta).
    static func text(left: Int, scope: Scope, estimated: Bool = false) -> String {
        let place = scope == .chapter ? "kapitlet" : "boken"
        if left <= 0 {
            return "Sista sidan i \(place)"
        }
        let count = left == 1 ? "1 sida" : "\(left) sidor"
        return (estimated ? "Cirka \(count)" : count) + " kvar i \(place)"
    }
}
