import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private lazy var library = LibraryViewController()

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let navigation = NavigationController(rootViewController: library)
        navigation.navigationBar.prefersLargeTitles = true

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window

        openIncoming(connectionOptions.urlContexts)
    }

    /// Synkar när appen kommer fram, om synken är inställd (fas 6), och sparar dagens säkerhetskopia (G1).
    func sceneDidBecomeActive(_ scene: UIScene) {
        guard !SelfTest.isActive else { return }
        SyncEngine.shared.syncSoon()
        Backup.makeDailyIfNeeded()
    }

    /// Dagens säkerhetskopia om den inte redan finns, innan iOS pausar appen.
    func sceneDidEnterBackground(_ scene: UIScene) {
        guard !SelfTest.isActive else { return }
        let task = BackgroundTask(name: "Säkerhetskopia")
        Backup.makeDailyIfNeeded { _ in
            task.end()
        }
    }

    /// "Öppna i Läsa" från Filer eller en annan app medan appen redan är igång.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        openIncoming(URLContexts)
    }

    private func openIncoming(_ contexts: Set<UIOpenURLContext>) {
        guard let url = contexts.first?.url else { return }
        // Vänta ett varv så att biblioteket hunnit visas. Vid kallstart syns annars inga felmeddelanden.
        DispatchQueue.main.async { [weak self] in
            self?.importAndOpen(url)
        }
    }

    private func importAndOpen(_ url: URL) {
        // Stäng zoom eller innehållsförteckning och gå tillbaka till biblioteket först.
        library.navigationController?.dismiss(animated: false)
        library.navigationController?.popToRootViewController(animated: false)
        // En fil som en annan app lämnat i Inkorgen (Documents/Inbox) är redan en kopia och flyttas.
        // En fil som öppnas där den ligger (Filer, iCloud Drive) kopieras. Allt sker i bakgrunden (G10).
        let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        library.importAndOpen(url, move: path.hasPrefix(inbox + "/"))
    }
}
