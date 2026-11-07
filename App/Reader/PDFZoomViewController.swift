import PDFKit
import UIKit

/// En sida i förstoring, för små tabeller och figurer. Nyp för att zooma och dra för att flytta.
/// Man kan rulla vidare till andra sidor härifrån.
final class PDFZoomViewController: UIViewController {

    private let document: PDFDocument
    private let startPage: PDFPage
    private let pdfView = PDFView()
    private var didGoToStart = false
    private var didCheckAfterAppear = false
    private var pageObserver: NSObjectProtocol?

    init(document: PDFDocument, page: PDFPage) {
        self.document = document
        self.startPage = page
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    deinit {
        if let pageObserver = pageObserver {
            NotificationCenter.default.removeObserver(pageObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGray5

        pdfView.frame = view.bounds
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.backgroundColor = .systemGray5
        pdfView.document = document
        view.addSubview(pdfView)

        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                            target: self,
                                                            action: #selector(doneTapped))
        updateTitle(for: startPage)

        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let page = self.pdfView.currentPage else { return }
            self.updateTitle(for: page)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !didGoToStart, pdfView.bounds.width > 0 else { return }
        didGoToStart = true
        pdfView.go(to: startPage)
        pdfView.maxScaleFactor = max(pdfView.scaleFactorForSizeToFit * 6, 4)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // PDFView hoppar ibland inte förrän den har ritats en gång. Försök en gång till.
        guard !didCheckAfterAppear else { return }
        didCheckAfterAppear = true
        if pdfView.currentPage != startPage {
            pdfView.go(to: startPage)
        }
    }

    private func updateTitle(for page: PDFPage) {
        let index = document.index(for: page)
        if let label = page.label, !label.isEmpty, label != String(index + 1) {
            title = "Sida \(label)"
        } else {
            title = "Sida \(index + 1) av \(document.pageCount)"
        }
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }
}
