import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // G4: loggen i Filer och Apples rapporter om krascher och frysningar.
        AppLog.shared.writeLaunch()
        DiagnosticReports.shared.start()
        return true
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        AppLog.shared.write("Minnesvarning, appen använder " + String(format: "%.0f MB", MemoryUsage.megabytes))
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
