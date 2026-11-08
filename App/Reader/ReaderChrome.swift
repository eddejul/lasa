import UIKit

/// Menyraden i båda läsarna (G12 steg 1): knapparna och deras ordning, menyn Bakgrund, att menyraden och
/// nederkanten döljs och visas, färgerna efter bakgrunden och det korta meddelandet nere på sidan.
/// Ändras menyraden ska den ändras här, inte i läsarna.
///
/// U3: tre zoner. Till vänster Bibliotek (tillbaka) och Innehåll, i mitten bokens titel med kapitlet under,
/// till höger Sök, Markera, Aa och Mer. Mer har bokmärket, Gå till sida och Zooma sidan (PDF). Bokmärket
/// är annars bandet i sidans övre hörn, som läsarna låter fingret trycka på direkt.
@MainActor
final class ReaderChrome {

    /// Läsarens åtgärder för knapparna. Metoderna finns i läsaren, som är knapparnas mål.
    struct Actions {
        let contents: Selector
        let search: Selector
        let mark: Selector
        let bookmark: Selector
        /// Gå till sida (PDF). EPUB har platsen i Innehåll.
        var goToPage: Selector? = nil
        /// Zooma sidan (PDF).
        var zoom: Selector? = nil
    }

    let contentsItem: UIBarButtonItem
    /// Bakgrunden. I PDF är det knappen Aa, i EPUB och text ligger bakgrunderna i Mer.
    let themeItem: UIBarButtonItem
    let searchItem: UIBarButtonItem
    let markItem: UIBarButtonItem
    /// Finns inte i menyraden (U3), men läsarna håller dess bild och tillgänglighetsvärde aktuella.
    let bookmarkItem: UIBarButtonItem
    /// Aa i EPUB och text (typsnitt och storlek). Nil i PDF, där Aa är bakgrunden.
    let readerItem: UIBarButtonItem?
    /// Mer: bokmärket, Gå till sida, Zooma sidan och (i EPUB) bakgrunden.
    let moreItem: UIBarButtonItem

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private lazy var titleStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 0
        return stack
    }()
    private let actions: Actions
    private var isBookmarked = false

    /// Om menyraden och nederkanten är dolda.
    private(set) var isHidden = false

    private weak var controller: UIViewController?
    private let bottomBar: ReaderBottomBar
    private weak var toastLabel: UILabel?
    private var theme: ReaderTheme
    private let onTheme: (ReaderTheme) -> Void

    /// `onTheme` anropas när en bakgrund väljs i menyn. Läsaren byter bakgrund och anropar `updateThemeMenu`.
    init(controller: UIViewController, bottomBar: ReaderBottomBar, readerItem: UIBarButtonItem?,
         theme: ReaderTheme, actions: Actions, onTheme: @escaping (ReaderTheme) -> Void) {
        self.controller = controller
        self.bottomBar = bottomBar
        self.readerItem = readerItem
        self.theme = theme
        self.onTheme = onTheme
        self.actions = actions
        readerItem?.image = UIImage(systemName: "textformat.size")

        let contents = UIBarButtonItem(image: UIImage(systemName: "list.bullet"),
                                       style: .plain,
                                       target: controller,
                                       action: actions.contents)
        contents.accessibilityLabel = "Innehåll"
        contentsItem = contents

        let themeButton = UIBarButtonItem(title: nil,
                                          image: UIImage(systemName: readerItem == nil ? "textformat.size"
                                                            : "circle.lefthalf.fill"),
                                          primaryAction: nil,
                                          menu: nil)
        themeButton.accessibilityLabel = readerItem == nil ? "Utseende" : "Bakgrund"
        themeItem = themeButton

        let more = UIBarButtonItem(title: nil, image: UIImage(systemName: "ellipsis.circle"), primaryAction: nil,
                                   menu: nil)
        more.accessibilityLabel = "Mer"
        moreItem = more

        let annotationItems = ReaderMenus.annotationItems(target: controller,
                                                          search: actions.search,
                                                          mark: actions.mark,
                                                          bookmark: actions.bookmark)
        searchItem = annotationItems[0]
        markItem = annotationItems[1]
        bookmarkItem = annotationItems[2]

        themeItem.menu = makeThemeMenu()
        moreItem.menu = makeMoreMenu()
    }

    /// Lägger knapparna i läsarens menyrad. Anropas en gång, när läsarens vy laddats.
    func install() {
        guard let controller = controller else { return }
        // Menyraden ligger ovanpå sidan med en egen bakgrund, så att knapparna syns mot texten.
        applyAppearance()
        let item = controller.navigationItem
        // Till vänster: Bibliotek (tillbakaknappen) och Innehåll.
        item.leftItemsSupplementBackButton = true
        item.leftBarButtonItems = [contentsItem]
        // Till höger, längst till höger först: Mer, Aa, Markera, Sök.
        item.rightBarButtonItems = [moreItem, readerItem ?? themeItem, markItem, searchItem]
        // I mitten: bokens titel och kapitlet under.
        titleLabel.text = controller.title
        titleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isHidden = true
        item.titleView = titleStack
        applyTitleStyle()
    }

    /// Kapitlet (eller avsnittet) under bokens titel. Nil eller tom döljer raden.
    func setSubtitle(_ text: String?) {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard subtitleLabel.text != value || subtitleLabel.isHidden != value.isEmpty else { return }
        subtitleLabel.text = value
        subtitleLabel.isHidden = value.isEmpty
        titleStack.setNeedsLayout()
    }

    /// Texten under titeln, till självtestet.
    var subtitle: String? {
        subtitleLabel.isHidden ? nil : subtitleLabel.text
    }

    /// Om sidan man läser har ett bokmärke. Bygger om Mer så att raden Bokmärke stämmer.
    func updateBookmark(_ marked: Bool) {
        guard marked != isBookmarked else { return }
        isBookmarked = marked
        moreItem.menu = makeMoreMenu()
    }

    private func applyTitleStyle() {
        let palette = Theme.palette(for: theme)
        titleLabel.font = Theme.serif(.subheadline, size: 15, weight: .semibold)
        titleLabel.textColor = palette.ink
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = palette.inkSoft
    }

    private func makeMoreMenu() -> UIMenu {
        var children: [UIMenuElement] = []
        let bookmark = UIAction(title: isBookmarked ? "Ta bort bokmärket" : "Bokmärk sidan",
                                image: UIImage(systemName: isBookmarked ? "bookmark.slash" : "bookmark")) {
            [weak self] _ in
            self?.send(self?.actions.bookmark)
        }
        children.append(bookmark)
        if let goToPage = actions.goToPage {
            children.append(UIAction(title: "Gå till sida", image: UIImage(systemName: "arrow.right.doc.on.clipboard")) {
                [weak self] _ in
                self?.send(goToPage)
            })
        }
        if let zoom = actions.zoom {
            children.append(UIAction(title: "Zooma sidan", image: UIImage(systemName: "plus.magnifyingglass")) {
                [weak self] _ in
                self?.send(zoom)
            })
        }
        if readerItem != nil {
            // EPUB och text: bakgrunderna här tills Aa samlar allt utseende (U2).
            children.append(UIMenu(title: "Bakgrund", image: UIImage(systemName: "circle.lefthalf.fill"),
                                   children: themeActions()))
        }
        return UIMenu(title: "", children: children)
    }

    /// Skickar en åtgärd till läsaren, som har metoden.
    private func send(_ selector: Selector?) {
        guard let selector = selector, let controller = controller else { return }
        UIApplication.shared.sendAction(selector, to: controller, from: nil, for: nil)
    }

    // MARK: Dölja och visa

    /// Döljer eller visar menyraden och nederkanten. Läsarens statusfält följer `isHidden`.
    func setHidden(_ hidden: Bool, animated: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        controller?.navigationController?.setNavigationBarHidden(hidden, animated: animated)
        bottomBar.isUserInteractionEnabled = !hidden
        UIView.animate(withDuration: animated ? 0.25 : 0) {
            self.bottomBar.alpha = hidden ? 0 : 1
            self.controller?.setNeedsStatusBarAppearanceUpdate()
        }
    }

    // MARK: Bakgrund

    /// Bygger om menyn Bakgrund så att bocken står vid bakgrunden som gäller.
    func updateThemeMenu(_ theme: ReaderTheme) {
        self.theme = theme
        themeItem.menu = makeThemeMenu()
        moreItem.menu = makeMoreMenu()
    }

    /// Menyraden och reglaget följer bakgrunden: papperets färg, mörka på mörkt papper (U1).
    func applyStyle(for theme: ReaderTheme) {
        guard let controller = controller else { return }
        self.theme = theme
        let style: UIUserInterfaceStyle = theme.isDark ? .dark : .light
        controller.overrideUserInterfaceStyle = style
        controller.navigationController?.overrideUserInterfaceStyle = style
        applyAppearance()
        controller.setNeedsStatusBarAppearanceUpdate()
    }

    /// Menyradens bakgrund är sidans papper med en hårlinje under, knapparna i temats accentfärg.
    private func applyAppearance() {
        guard let controller = controller else { return }
        let palette = Theme.palette(for: theme)
        let appearance = Theme.readerAppearance(palette)
        controller.navigationItem.standardAppearance = appearance
        controller.navigationItem.scrollEdgeAppearance = appearance
        controller.navigationItem.compactAppearance = appearance
        controller.navigationController?.navigationBar.tintColor = palette.accent
        bottomBar.apply(palette)
        applyTitleStyle()
    }

    /// Bakgrunderna. Bläddringsljudet ligger i Inställningar (U2).
    private func makeThemeMenu() -> UIMenu {
        UIMenu(title: "Bakgrund", children: themeActions())
    }

    private func themeActions() -> [UIMenuElement] {
        ReaderTheme.allCases.map { option in
            UIAction(title: option.title,
                     image: UIImage(systemName: option.symbolName),
                     state: option == theme ? .on : .off) { [weak self] _ in
                self?.onTheme(option)
            }
        }
    }

    // MARK: Meddelandet

    /// Ett kort meddelande nere på sidan som försvinner av sig självt.
    func showToast(_ text: String) {
        guard let view = controller?.view else { return }
        toastLabel?.removeFromSuperview()
        let label = PaddedLabel()
        label.text = text
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0.1, alpha: 0.85)
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alpha = 0
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -60),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
        ])
        toastLabel = label
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        UIView.animate(withDuration: 0.4, delay: 2.5, options: []) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }
}
