import UIKit

/// Öppningen från omslaget (U10): omslaget växer till sidans storlek och tonar över i läsaren, och tillbaka krymper
/// läsaren in i omslaget. Sker före och efter läsaren, aldrig i pappersvikningen. Med Minska rörelse blir det
/// en toning. Bara förflyttning, skala och toning, så att det håller 60 bilder per sekund.
final class BookOpenTransition: NSObject, UIViewControllerAnimatedTransitioning {

    let opening: Bool
    /// Omslaget som bild och dess ruta i fönstret. Nil: bara en toning.
    private var cover: UIImage?
    private var coverFrame: CGRect?
    /// Tillbaka: omslaget letas upp när biblioteket lagts ut igen, eftersom boken då kan ha flyttat först.
    private let locate: (() -> (image: UIImage?, frame: CGRect?))?

    init(opening: Bool, cover: UIImage?, coverFrame: CGRect?, locate: (() -> (image: UIImage?, frame: CGRect?))? = nil) {
        self.opening = opening
        self.cover = cover
        self.coverFrame = coverFrame
        self.locate = locate
    }

    private var reduceMotion: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        reduceMotion || coverFrame == nil ? 0.25 : 0.38
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let fromView = context.view(forKey: .from), let toView = context.view(forKey: .to),
              let toController = context.viewController(forKey: .to) else {
            context.completeTransition(!context.transitionWasCancelled)
            return
        }
        toView.frame = context.finalFrame(for: toController)
        if !opening, let locate = locate {
            container.insertSubview(toView, belowSubview: fromView)
            toView.layoutIfNeeded()
            let found = locate()
            cover = found.image
            coverFrame = found.frame
        }
        let duration = transitionDuration(using: context)
        let finish = {
            context.completeTransition(!context.transitionWasCancelled)
        }

        if opening {
            container.addSubview(toView)
            toView.alpha = 0
            guard !reduceMotion, let frame = coverFrame, let image = cover else {
                UIView.animate(withDuration: duration, animations: { toView.alpha = 1 }, completion: { _ in finish() })
                return
            }
            let moving = Self.coverView(image)
            moving.frame = container.convert(frame, from: nil)
            container.addSubview(moving)
            let target = toView.frame
            UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0,
                           options: [.curveEaseInOut], animations: {
                moving.frame = target
            })
            UIView.animate(withDuration: duration * 0.55, delay: duration * 0.45, options: [.curveEaseOut], animations: {
                toView.alpha = 1
                moving.alpha = 0
            }, completion: { _ in
                moving.removeFromSuperview()
                finish()
            })
        } else {
            container.insertSubview(toView, belowSubview: fromView)
            guard !reduceMotion, let frame = coverFrame,
                  let snapshot = fromView.snapshotView(afterScreenUpdates: false) else {
                UIView.animate(withDuration: duration, animations: { fromView.alpha = 0 }, completion: { _ in
                    fromView.alpha = 1
                    finish()
                })
                return
            }
            snapshot.frame = fromView.frame
            snapshot.clipsToBounds = true
            snapshot.layer.cornerRadius = 0
            container.addSubview(snapshot)
            fromView.alpha = 0
            let target = container.convert(frame, from: nil)
            var coverImage: UIImageView?
            if let image = cover {
                let view = Self.coverView(image)
                view.frame = snapshot.frame
                view.alpha = 0
                container.addSubview(view)
                coverImage = view
            }
            UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0,
                           options: [.curveEaseInOut], animations: {
                snapshot.frame = target
                snapshot.layer.cornerRadius = 4
                coverImage?.frame = target
            })
            UIView.animate(withDuration: duration * 0.5, delay: duration * 0.4, options: [.curveEaseIn], animations: {
                snapshot.alpha = 0
                coverImage?.alpha = 1
            }, completion: { _ in
                snapshot.removeFromSuperview()
                coverImage?.removeFromSuperview()
                fromView.alpha = 1
                finish()
            })
        }
    }

    private static func coverView(_ image: UIImage) -> UIImageView {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = 4
        return view
    }
}

extension CoverView {

    /// Omslaget som bild, till öppningen (U10). En liten bild av en vy på några hundra punkter.
    func snapshotImage() -> UIImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { context in
            layer.render(in: context.cgContext)
        }
    }
}
