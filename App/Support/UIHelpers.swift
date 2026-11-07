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

/// En etikett med luft runt texten, till korta meddelanden. Fungerar även med flera rader.
final class PaddedLabel: UILabel {

    var insets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let inner = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
        return inner.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left,
                                            bottom: -insets.bottom, right: -insets.right))
    }
}
