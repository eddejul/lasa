import PDFKit
import UIKit

/// PDF-läsaren med pappersvikning, som i Apple Books.
///
/// Tryck i kanterna eller dra för att bläddra. Tryck i mitten för att visa eller dölja menyn.
final class PDFCurlReaderViewController: UIViewController {

    private let book: Book
    private let renderer: PDFPageRenderer
    private let pageController: UIPageViewController
    private let pageLabel = PaddedLabel()
    private var chromeTap: UITapGestureRecognizer?
    private var currentIndex: Int
    private var chromeHidden = false

    init?(book: Book) {
        guard let document = PDFDocument(url: book.url),
              !document.isLocked,
              document.pageCount > 0 else {
            return nil
        }
        self.book = book
        self.renderer = PDFPageRenderer(document: document)
        let saved = LibraryStore.shared.savedPageIndex(for: book)
        self.currentIndex = min(max(saved, 0), document.pageCount - 1)
        self.pageController = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [.spineLocation: NSNumber(value: UIPageViewController.SpineLocation.min.rawValue)]
        )
        super.init(nibName: nil, bundle: nil)
        title = book.title
        navigationItem.largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override var prefersStatusBarHidden: Bool {
        chromeHidden
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        pageController.dataSource = self
        pageController.delegate = self
        pageController.isDoubleSided = false
        addChild(pageController)
        pageController.view.frame = view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageController.view)
        pageController.didMove(toParent: self)
        pageController.setViewControllers([makePage(currentIndex)], direction: .forward, animated: false)

        // Pappersvikningens egna tryck ska bara gälla kanterna, mitten styr menyn.
        for recognizer in pageController.gestureRecognizers where recognizer is UITapGestureRecognizer {
            recognizer.delegate = self
        }

        setUpPageLabel()
        setUpChromeTap()
        updatePageLabel()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        prefetchNeighbours()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if chromeHidden {
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.prefetchNeighbours()
        }
    }

    // MARK: Sidor

    private func makePage(_ index: Int) -> PDFPageViewController {
        PDFPageViewController(pageIndex: index, renderer: renderer)
    }

    private func prefetchNeighbours() {
        let size = PDFPageViewController.renderSize(for: pageController.view.bounds.size)
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        renderer.prefetch(around: currentIndex, size: size, scale: scale)
    }

    // MARK: Meny och sidnummer

    private func setUpPageLabel() {
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        pageLabel.textColor = .darkGray
        pageLabel.backgroundColor = UIColor(white: 0.95, alpha: 0.92)
        pageLabel.layer.cornerRadius = 11
        pageLabel.layer.masksToBounds = true
        pageLabel.isUserInteractionEnabled = false
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageLabel)
        NSLayoutConstraint.activate([
            pageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pageLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])
    }

    private func updatePageLabel() {
        pageLabel.text = "\(currentIndex + 1) av \(renderer.pageCount)"
    }

    private func setUpChromeTap() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleChrome))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        chromeTap = tap
    }

    @objc private func toggleChrome() {
        setChromeHidden(!chromeHidden, animated: true)
    }

    private func setChromeHidden(_ hidden: Bool, animated: Bool) {
        guard hidden != chromeHidden else { return }
        chromeHidden = hidden
        navigationController?.setNavigationBarHidden(hidden, animated: animated)
        UIView.animate(withDuration: animated ? 0.25 : 0) {
            self.pageLabel.alpha = hidden ? 0 : 1
            self.setNeedsStatusBarAppearanceUpdate()
        }
    }
}

// MARK: Pappersvikningen

extension PDFCurlReaderViewController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? PDFPageViewController, page.pageIndex > 0 else {
            return nil
        }
        return makePage(page.pageIndex - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? PDFPageViewController,
              page.pageIndex < renderer.pageCount - 1 else {
            return nil
        }
        return makePage(page.pageIndex + 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            willTransitionTo pendingViewControllers: [UIViewController]) {
        Haptics.shared.prepareForPageTurn()
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController],
                            transitionCompleted completed: Bool) {
        guard completed,
              let page = pageViewController.viewControllers?.first as? PDFPageViewController else {
            return
        }
        currentIndex = page.pageIndex
        LibraryStore.shared.savePageIndex(currentIndex, for: book)
        updatePageLabel()
        Haptics.shared.pageTurned()
        setChromeHidden(true, animated: true)
        prefetchNeighbours()
    }
}

// MARK: Tryckzoner

extension PDFCurlReaderViewController: UIGestureRecognizerDelegate {

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let width = max(view.bounds.width, 1)
        let position = touch.location(in: view).x / width
        let inMiddle = position > 0.3 && position < 0.7

        if let chromeTap = chromeTap, gestureRecognizer === chromeTap {
            return inMiddle
        }
        // Pappersvikningens tryck: bara i kanterna.
        return !inMiddle
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
