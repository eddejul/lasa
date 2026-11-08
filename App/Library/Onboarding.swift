import UIKit

/// Första start (B5): en välkomstsida för nya installationer, en exempelbok som lär ut de tre gesterna som inte
/// syns av sig själva, och kortet Gör mer med Sensus. En befintlig installation (böcker, markeringar, sparade
/// ord eller läspositioner) får aldrig välkomstsidan, oavsett flaggor.
enum Onboarding {

    /// Exempelbokens filnamn i Böcker.
    static let sampleName = "Så läser du i Sensus.md"

    private static let doneKey = "onboarding.done"
    private static let newInstallKey = "onboarding.newInstall"
    private static let moreDismissedKey = "onboarding.moreDismissed"

    /// Exempelboken. Varje rubrik på nivå 1 blir en egen sida.
    static let sampleText = """
        # Så läser du i Sensus

        Det här är en kort exempelbok. Den visar tre saker som är lätta att missa, och varje steg bockas av \
        längst ner när du gjort det.

        **Steg 1: bläddra.** Tryck i högra kanten av sidan för att gå framåt. Sidan viks som papper. I vänstra \
        kanten går du tillbaka, och ett tryck i mitten tar fram menyn.

        # Slå upp ett ord

        **Steg 2: håll fingret på ett ord.** Håll fingret stilla på ordet förtröstan en kort stund. Ordet markeras \
        och en bubbla visar vilket ord det är. Släpp, så öppnas ordkortet med betydelsen och synonymer.

        Du kan dra fingret till ett annat ord innan du släpper. Spara ordet i ordkortet, så kommer det tillbaka \
        under Repetera i biblioteket.

        # Markera en mening

        **Steg 3: markera.** Tryck i mitten för menyn och välj pennan uppe till höger. Dra sedan fingret över \
        den här meningen, från första till sista ordet.

        Tryck på en markering för att byta färg, skriva en anteckning eller ta bort den. Tryck på pennan igen \
        när du är klar.

        # Klart

        Nu kan du det viktigaste. Gå tillbaka till biblioteket med knappen uppe till vänster.

        Lägg in dina egna böcker med plus i biblioteket, eller välj Dela och Sensus på en fil i Filer. Böcker \
        i en mapp i Böcker blir en kurs av sig själva. Exempelboken kan du ta bort genom att hålla fingret på \
        omslaget.
        """

    /// Sant om appen redan har använts: böcker, markeringar, sparade ord eller läspositioner. Då blir det
    /// aldrig någon välkomstsida (Edvins iPad).
    static func hasExistingData() -> Bool {
        if !LibraryStore.shared.listFiles().files.isEmpty || !BookRegistry.shared.records().isEmpty {
            return true
        }
        let counts = AnnotationStore.shared.totalCounts()
        if counts.highlights + counts.bookmarks > 0 || !UserWords.shared.savedWords().isEmpty {
            return true
        }
        let prefixes = ["position.", "location.", "bookPosition.", "bookLocation."]
        return UserDefaults.standard.dictionaryRepresentation().keys.contains { key in
            prefixes.contains { key.hasPrefix($0) }
        }
    }

    /// Välkomstsidan visas en gång, bara för en ny installation utan data.
    static var shouldShowWelcome: Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return false }
        if hasExistingData() {
            // En befintlig installation: aldrig välkomstsidan, inte heller senare.
            defaults.set(true, forKey: doneKey)
            return false
        }
        return true
    }

    static func markWelcomeShown() {
        UserDefaults.standard.set(true, forKey: doneKey)
        UserDefaults.standard.set(true, forKey: newInstallKey)
    }

    /// Kortet Gör mer med Sensus: bara efter välkomstsidan, tills det stängts eller AI-nyckeln finns.
    static var showsMoreCard: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: newInstallKey) && !defaults.bool(forKey: moreDismissedKey)
            && (Keychain.string(.geminiAPIKey) ?? "").isEmpty
    }

    static func dismissMoreCard() {
        UserDefaults.standard.set(true, forKey: moreDismissedKey)
    }

    /// Självtestet: visar kortet Gör mer med Sensus en stund (simulatorn har böcker och får aldrig välkomstsidan).
    static func setNewInstallForSelfTest(_ on: Bool) {
        if on {
            UserDefaults.standard.set(true, forKey: newInstallKey)
            UserDefaults.standard.removeObject(forKey: moreDismissedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: newInstallKey)
        }
    }

    /// Lägger exempelboken i Böcker (om den inte redan finns) och svarar med filen.
    static func writeSampleBook() -> URL? {
        let url = LibraryStore.shared.booksDirectory.appendingPathComponent(sampleName)
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try Data(sampleText.utf8).write(to: url, options: .atomic)
            } catch {
                AppLog.shared.write("Exempelboken kunde inte sparas: \(error.localizedDescription)")
                return nil
            }
        }
        return url
    }

    static func isSample(_ book: Book) -> Bool {
        book.path == sampleName
    }
}

/// Stegen i exempelboken (B5): bläddra, håll fingret på ett ord och markera. Läsaren rapporterar vad som
/// gjorts, och en rad längst ner visar nästa steg och bockar av. Raden tar inga tryck.
@MainActor
final class OnboardingTips {

    static let shared = OnboardingTips()

    enum Step: Int, CaseIterable {
        case turn, word, highlight

        var text: String {
            switch self {
            case .turn: return "Tryck i högra kanten för att bläddra"
            case .word: return "Håll fingret stilla på ett ord och släpp"
            case .highlight: return "Tryck i mitten, välj pennan och dra över en mening"
            }
        }
    }

    private(set) var done = Set<Step>()
    private weak var bar: PaddedLabel?

    /// Läsaren öppnade en bok. Är det exempelboken visas raden.
    func attach(to view: UIView, book: Book) {
        bar?.removeFromSuperview()
        guard Onboarding.isSample(book) else { return }
        let label = PaddedLabel()
        label.insets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.layer.cornerRadius = 14
        label.layer.masksToBounds = true
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -64),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        bar = label
        refresh()
    }

    /// Läsaren gjorde ett av stegen.
    func record(_ step: Step, book: Book) {
        guard Onboarding.isSample(book), !done.contains(step) else { return }
        done.insert(step)
        Haptics.shared.wordTapped()
        refresh()
    }

    /// Texten på raden, till självtestet.
    var text: String {
        let marks = Step.allCases.map { done.contains($0) ? "✓" : "○" }.joined(separator: " ")
        guard let next = Step.allCases.first(where: { !done.contains($0) }) else {
            return "\(marks)  Klart! Tillbaka till biblioteket uppe till vänster."
        }
        return "\(marks)  Steg \(next.rawValue + 1) av 3: \(next.text)"
    }

    private func refresh() {
        guard let bar = bar else { return }
        let palette = Theme.current
        bar.backgroundColor = palette.surface
        bar.textColor = palette.ink
        bar.font = .systemFont(ofSize: 15, weight: .medium)
        bar.layer.borderWidth = 1
        bar.layer.borderColor = palette.rule.cgColor
        bar.text = text
        bar.accessibilityLabel = text
        if done.count == Step.allCases.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak bar] in
                UIView.animate(withDuration: 0.3, animations: { bar?.alpha = 0 }, completion: { _ in
                    bar?.removeFromSuperview()
                })
            }
        }
    }
}

/// Välkomstsidan (B5): namnet, en mening och Börja. Börja lägger exempelboken i biblioteket och öppnar den.
final class WelcomeViewController: UIViewController {

    var onStart: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        let palette = Theme.current
        view.backgroundColor = palette.canvas

        let icon = UIImageView(image: UIImage(named: "AppIcon") ?? UIImage(systemName: "book"))
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 22
        icon.layer.masksToBounds = true
        icon.tintColor = palette.accent

        let title = UILabel()
        title.text = "Sensus"
        title.font = Theme.serif(.largeTitle, size: 48, weight: .semibold)
        title.textColor = palette.ink
        title.textAlignment = .center
        title.accessibilityTraits = .header

        let text = UILabel()
        text.text = "Läs dina kursböcker som på papper, slå upp ord med ett finger och spara det du vill minnas."
        text.font = Theme.serif(.title3, size: 20)
        text.textColor = palette.inkSoft
        text.textAlignment = .center
        text.numberOfLines = 0

        let button = UIButton(type: .system)
        button.setTitle("Börja", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.backgroundColor = palette.accent
        button.setTitleColor(palette.surface, for: .normal)
        button.layer.cornerRadius = 25
        button.addTarget(self, action: #selector(start), for: .touchUpInside)
        button.accessibilityHint = "Öppnar en kort exempelbok som visar hur du bläddrar, slår upp ord och markerar."

        let hint = UILabel()
        hint.text = "En kort exempelbok visar hur du bläddrar, slår upp ord och markerar."
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = palette.inkSoft
        hint.textAlignment = .center
        hint.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, title, text, button, hint])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 20
        stack.setCustomSpacing(32, after: text)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            button.widthAnchor.constraint(equalToConstant: 220),
            button.heightAnchor.constraint(equalToConstant: 50),
            text.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            hint.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    @objc private func start() {
        Onboarding.markWelcomeShown()
        dismiss(animated: true) { [onStart] in
            onStart?()
        }
    }
}
