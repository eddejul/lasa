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

/// Etikett med luft runt texten, används för sidnumret.
final class PaddedLabel: UILabel {

    var insets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right,
                      height: size.height + insets.top + insets.bottom)
    }
}
