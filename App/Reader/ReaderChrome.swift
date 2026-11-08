import UIKit

/// Menyraden i båda läsarna (G12 steg 1): knapparna och deras ordning, menyn Bakgrund, att menyraden och
/// nederkanten döljs och visas, färgerna efter bakgrunden och det korta meddelandet nere på sidan.
/// Läsarna ger den sina åtgärder och knappen som skiljer dem åt (zoom i PDF, typsnitt i EPUB och text).
/// Ändras menyraden ska den ändras här, inte i läsarna.
@MainActor
final class ReaderChrome {

    /// Läsarens åtgärder för knapparna. Metoderna finns i läsaren, som är knapparnas mål.
    struct Actions {
        let contents: Selector
        let search: Selector
        let mark: Selector
        let bookmark: Selector
    }

    let contentsItem: UIBarButtonItem
    let themeItem: UIBarButtonItem
    let searchItem: UIBarButtonItem
    let markItem: UIBarButtonItem
    let bookmarkItem: UIBarButtonItem
    /// Knappen som bara den ena läsaren har: zoom i PDF, typsnitt och storlek i EPUB och text.
    let readerItem: UIBarButtonItem

    /// Om menyraden och nederkanten är dolda.
    private(set) var isHidden = false

    private weak var controller: UIViewController?
    private let bottomBar: ReaderBottomBar
    private weak var toastLabel: UILabel?
    private var theme: ReaderTheme
    private let onTheme: (ReaderTheme) -> Void

    /// `onTheme` anropas när en bakgrund väljs i menyn. Läsaren byter bakgrund och anropar `updateThemeMenu`.
    init(controller: UIViewController, bottomBar: ReaderBottomBar, readerItem: UIBarButtonItem,
         theme: ReaderTheme, actions: Actions, onTheme: @escaping (ReaderTheme) -> Void) {
        self.controller = controller
        self.bottomBar = bottomBar
        self.readerItem = readerItem
        self.theme = theme
        self.onTheme = onTheme

        let contents = UIBarButtonItem(image: UIImage(systemName: "list.bullet"),
                                       style: .plain,
                                       target: controller,
                                       action: actions.contents)
        contents.accessibilityLabel = "Innehåll"
        contentsItem = contents

        let themeButton = UIBarButtonItem(title: nil,
                                          image: UIImage(systemName: "circle.lefthalf.fill"),
                                          primaryAction: nil,
                                          menu: nil)
        themeButton.accessibilityLabel = "Bakgrund"
        themeItem = themeButton

        let annotationItems = ReaderMenus.annotationItems(target: controller,
                                                          search: actions.search,
                                                          mark: actions.mark,
                                                          bookmark: actions.bookmark)
        searchItem = annotationItems[0]
        markItem = annotationItems[1]
        bookmarkItem = annotationItems[2]

        themeItem.menu = makeThemeMenu()
    }

    /// Lägger knapparna i läsarens menyrad. Anropas en gång, när läsarens vy laddats.
    func install() {
        guard let controller = controller else { return }
        // Menyraden ligger ovanpå sidan med en egen bakgrund, så att knapparna syns mot texten.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        controller.navigationItem.standardAppearance = appearance
        controller.navigationItem.scrollEdgeAppearance = appearance
        controller.navigationItem.compactAppearance = appearance
        controller.navigationItem.rightBarButtonItems = [themeItem, readerItem, searchItem, markItem, bookmarkItem,
                                                         contentsItem]
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
    }

    /// Menyraden och reglaget följer bakgrunden: mörka på mörkt papper, ljusa annars.
    func applyStyle(for theme: ReaderTheme) {
        guard let controller = controller else { return }
        let style: UIUserInterfaceStyle = theme.isDark ? .dark : .light
        controller.overrideUserInterfaceStyle = style
        controller.navigationController?.overrideUserInterfaceStyle = style
        controller.setNeedsStatusBarAppearanceUpdate()
    }

    private func makeThemeMenu() -> UIMenu {
        let actions = ReaderTheme.allCases.map { option in
            UIAction(title: option.title,
                     image: UIImage(systemName: option.symbolName),
                     state: option == theme ? .on : .off) { [weak self] _ in
                self?.onTheme(option)
            }
        }
        let sound = ReaderMenus.soundSection { [weak self] in
            guard let self = self else { return }
            self.themeItem.menu = self.makeThemeMenu()
        }
        return UIMenu(title: "Bakgrund", children: actions + [sound])
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
