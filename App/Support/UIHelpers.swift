import UIKit

/// Navigationskontroll som låter den översta vyn bestämma om statusfältet syns,
/// så att läsaren kan dölja det i helskärm.
final class NavigationController: UINavigationController {

    override var childForStatusBarHidden: UIViewController? {
        topViewController
    }

    override var childForStatusBarStyle: UIViewController? {
        topViewController
    }
}
