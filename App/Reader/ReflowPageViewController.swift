import UIKit

/// Ett blad i pappersvikningen för EPUB och textfiler: en färdig bild av en sida, eller ett tomt blad
/// (sist i ett kapitel med udda sidantal i ett uppslag). Bilden kommer från renderaren. Tills den är klar
/// visas papperet, så att huvudtråden aldrig ritar under en vikning.
final class ReflowPageViewController: UIViewController {

    enum Side {
        case single, left, right
    }

    let chapter: Int
    /// Bladets plats i kapitlet. Samma som sidan, utom för tomma blad efter kapitlets sista sida.
    let slot: Int
    /// Sidan i kapitlet, eller nil för ett tomt blad.
    let page: Int?
    let side: Side

    /// Sidans storlek i renderaren. Tryck och markeringar räknas om från bladets storlek till den.
    private let pageSize: CGSize
    private weak var renderer: ReflowRenderer?
    private let imageView = UIImageView()
    private let spineShade = CAGradientLayer()
    private var highlightViews: [UIView] = []
    private var paperColor: UIColor
    private(set) var links: [ReflowLink] = []
    private(set) var hasImage = false

    // Fas 4: markeringar, bokmärke och sökträffar.
    private(set) var marks: [ReflowMarkRect] = []
    /// K6: citatens rutor på sidan (id `fraga:` plus frågans id) och textens kolumn, ur sidbildens markeringar.
    private var questionMarks: [ReflowMarkRect] = []
    private var textColumn: CGRect?
    private var questionFrames: [String: CGRect] = [:]
    private let questionLayer = UIView()
    /// K6: prickens nummer och svaret för en fråga, eller nil när prickarna inte ska synas. Sätts av läsaren.
    var questionInfo: ((String) -> (number: Int, status: QuestionStatus?)?)?
    private var previewViews: [UIView] = []
    private let ribbon = UIImageView(image: UIImage(systemName: "bookmark.fill"))
    var isBookmarked = false {
        didSet {
            updateRibbon()
        }
    }
    /// Bandets kontur syns medan menyn är framme, så att man ser var ett tryck bokmärker sidan (U3).
    var showsRibbonHint = false {
        didSet {
            updateRibbon()
        }
    }

    /// Där ett tryck bokmärker sidan: bandets hörn med marginal, i sidvyns koordinater.
    var ribbonZone: CGRect {
        CGRect(x: view.bounds.width - 70, y: 0, width: 70, height: 60)
    }

    private func updateRibbon() {
        ribbon.isHidden = !(isBookmarked || showsRibbonHint)
        ribbon.image = UIImage(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
        ribbon.tintColor = isBookmarked ? Theme.current.ribbon : Theme.current.inkFaint
    }

    init(chapter: Int,
         slot: Int,
         page: Int?,
         side: Side,
         pageSize: CGSize,
         renderer: ReflowRenderer,
         paperColor: UIColor) {
        self.chapter = chapter
        self.slot = slot
        self.page = page
        self.side = side
        self.pageSize = pageSize
        self.renderer = renderer
        self.paperColor = paperColor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    var isBlank: Bool {
        page == nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = paperColor
        imageView.contentMode = .scaleToFill
        view.addSubview(imageView)
        questionLayer.isUserInteractionEnabled = false
        view.addSubview(questionLayer)
        ribbon.contentMode = .scaleAspectFit
        updateRibbon()
        ribbon.isAccessibilityElement = true
        ribbon.accessibilityLabel = "Bokmärke"
        view.addSubview(ribbon)

        if side != .single {
            // Svag skugga mot ryggen, som i en riktig bok.
            spineShade.colors = [UIColor(white: 0, alpha: 0.10).cgColor, UIColor(white: 0, alpha: 0).cgColor]
            spineShade.startPoint = CGPoint(x: side == .left ? 1 : 0, y: 0.5)
            spineShade.endPoint = CGPoint(x: side == .left ? 0 : 1, y: 0.5)
            view.layer.addSublayer(spineShade)
        }
        loadImage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        imageView.frame = bounds
        if questionLayer.frame != bounds {
            questionLayer.frame = bounds
            layoutQuestionDots()
        }
        ribbon.frame = CGRect(x: bounds.width - 46, y: -2, width: 20, height: 32)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let shadeWidth: CGFloat = 28
        spineShade.frame = CGRect(x: side == .left ? bounds.width - shadeWidth : 0,
                                  y: 0,
                                  width: shadeWidth,
                                  height: bounds.height)
        CATransaction.commit()
    }

    // MARK: Koordinater

    /// Från en punkt i bladet till sidans koordinater i renderaren.
    func pagePoint(_ point: CGPoint) -> CGPoint {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, pageSize.width > 0, pageSize.height > 0 else { return point }
        return CGPoint(x: point.x * pageSize.width / bounds.width, y: point.y * pageSize.height / bounds.height)
    }

    /// Från en ruta i sidans koordinater till bladet.
    func viewRect(_ rect: CGRect) -> CGRect {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, pageSize.width > 0, pageSize.height > 0 else { return rect }
        let sx = bounds.width / pageSize.width
        let sy = bounds.height / pageSize.height
        return CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
    }

    /// Länken under en punkt i bladet, med lite marginal runt små länkar som fotnotsnummer.
    func link(at point: CGPoint) -> ReflowLink? {
        guard hasImage else { return nil }
        let location = pagePoint(point)
        return links.first { $0.rect.insetBy(dx: -8, dy: -6).contains(location) }
    }

    // MARK: Markering

    /// Markerar ett ord som slås upp. Rutorna är i sidans koordinater.
    func showHighlight(_ rects: [CGRect]) {
        clearHighlight()
        for rect in rects {
            let highlight = UIView(frame: viewRect(rect).insetBy(dx: -2, dy: -1))
            highlight.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.35)
            highlight.layer.cornerRadius = 3
            highlight.isUserInteractionEnabled = false
            view.addSubview(highlight)
            highlightViews.append(highlight)
        }
    }

    func clearHighlight() {
        highlightViews.forEach { $0.removeFromSuperview() }
        highlightViews.removeAll()
    }

    // MARK: Bilden

    /// Sant från ett byte av tema tills den nya bilden är klar (den gamla visas under tiden).
    private(set) var isStale = false

    /// Bilden som visas, till självtestet.
    var currentImage: UIImage? {
        imageView.image
    }

    /// Nytt tema. Den gamla bilden visas tills den nya är klar.
    func apply(paperColor: UIColor) {
        self.paperColor = paperColor
        guard isViewLoaded else { return }
        view.backgroundColor = paperColor
        isStale = hasImage
        loadImage()
    }

    private func loadImage() {
        guard let page = page, let renderer = renderer else {
            imageView.image = nil
            return
        }
        let address = ReflowPage(chapter: chapter, page: page)
        if let snapshot = renderer.cachedSnapshot(for: address) {
            show(snapshot)
            return
        }
        renderer.requestImage(for: address, completion: { [weak self] snapshot in
            self?.show(snapshot)
        }, failure: { [weak self] in
            // Kapitlet gick inte att visas. Står en äldre bild kvar (efter byte av tema) får den stå kvar.
            guard let self = self, !self.hasImage else { return }
            self.setFailureShown(true)
        })
    }

    private func show(_ snapshot: ReflowSnapshot) {
        imageView.image = snapshot.image
        links = snapshot.links
        // K6: citatens rutor och textens kolumn är inga markeringar man kan trycka på.
        let prefix = ReaderQuestions.markPrefix
        marks = snapshot.marks.filter { !$0.id.hasPrefix(prefix) && $0.id != ReaderQuestions.textColumnID }
        questionMarks = snapshot.marks.filter { $0.id.hasPrefix(prefix) }
        textColumn = snapshot.marks.first { $0.id == ReaderQuestions.textColumnID }?.rect
        hasImage = true
        isStale = false
        setFailureShown(false)
        // En ny bild har markeringen inritad, så förhandsvisningen behövs inte längre.
        clearPreview()
        layoutQuestionDots()
    }

    // MARK: Frågor i marginalen (K6)

    /// Ritar om prickarna, till exempel när ett svar har sparats eller frågorna slagits av.
    func refreshQuestionDots() {
        guard isViewLoaded else { return }
        layoutQuestionDots()
    }

    /// Frågan vars prick ligger under en punkt i bladet, med lite marginal runt den lilla pricken.
    func questionID(at point: CGPoint) -> String? {
        questionFrames.first { $0.value.insetBy(dx: -10, dy: -10).contains(point) }?.key
    }

    func questionDotRect(id: String) -> CGRect? {
        questionFrames[id]
    }

    /// Antalet prickar som ritats, till självtestet.
    var questionDotCount: Int {
        questionFrames.count
    }

    private func layoutQuestionDots() {
        questionLayer.subviews.forEach { $0.removeFromSuperview() }
        questionFrames = [:]
        guard hasImage, let info = questionInfo, !questionMarks.isEmpty, view.bounds.width > 0 else { return }
        // Pricken står vid citatets första rad på sidan.
        var firstLines: [String: CGRect] = [:]
        for mark in questionMarks {
            let id = String(mark.id.dropFirst(ReaderQuestions.markPrefix.count))
            let rect = viewRect(mark.rect)
            if let current = firstLines[id], current.minY <= rect.minY {
                continue
            }
            firstLines[id] = rect
        }
        let placements = firstLines.compactMap { id, rect -> QuestionDotPlacement? in
            guard let shown = info(id) else { return nil }
            return QuestionDotPlacement(id: id, number: shown.number, status: shown.status, anchorY: rect.midY)
        }.sorted { $0.number < $1.number }
        let bounds = view.bounds
        let column = textColumn.map { viewRect($0) } ?? bounds.insetBy(dx: 16, dy: 0)
        questionFrames = QuestionDotView.layout(placements, in: questionLayer, contentMinX: column.minX,
                                                contentMaxX: column.maxX, top: 6, bottom: bounds.height - 6,
                                                outerIsLeft: side == .left)
    }

    // MARK: Kapitlet kunde inte visas (G2)

    /// Anropas när man trycker på Försök igen. Läsaren ber renderaren försöka igen och ritar om bladet.
    var onRetry: ((ReflowPageViewController) -> Void)?
    private var failureView: UIStackView?

    var showsFailure: Bool {
        failureView != nil
    }

    private func setFailureShown(_ shown: Bool) {
        guard shown != showsFailure, isViewLoaded else { return }
        guard shown else {
            failureView?.removeFromSuperview()
            failureView = nil
            return
        }
        let label = UILabel()
        label.text = "Kapitlet kunde inte visas."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .callout)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel

        var configuration = UIButton.Configuration.bordered()
        configuration.title = "Försök igen"
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
        ])
        failureView = stack
    }

    @objc private func retryTapped() {
        setFailureShown(false)
        onRetry?(self)
    }

    /// Självtestet: samma sak som ett tryck på Försök igen.
    func simulateRetryTap() {
        guard showsFailure else { return }
        retryTapped()
    }

    // MARK: Markeringar (fas 4)

    /// Ber om en ny bild, till exempel när en markering har lagts till. Den gamla visas tills den nya är klar.
    func reloadImage() {
        guard isViewLoaded else { return }
        loadImage()
    }

    /// Markeringen under en punkt i bladet.
    /// Rutorna för en markering på sidan, i sidvyns koordinater (U5: markeringsraden pekar på dem).
    func markRects(id: String) -> [CGRect] {
        marks.filter { $0.id == id }.map { viewRect($0.rect) }
    }

    func markID(at point: CGPoint) -> String? {
        guard hasImage else { return nil }
        let location = pagePoint(point)
        return marks.last { $0.rect.insetBy(dx: -4, dy: -4).contains(location) }?.id
    }

    /// Visar vad som markeras medan fingret drar. Rutorna är i sidans koordinater.
    func showPreview(_ rects: [CGRect], color: HighlightColor, dark: Bool) {
        clearPreview()
        for rect in rects {
            let preview = UIView(frame: viewRect(rect).insetBy(dx: -1, dy: -1))
            preview.backgroundColor = color.overlay(dark: dark)
            preview.layer.cornerRadius = 2
            preview.isUserInteractionEnabled = false
            view.addSubview(preview)
            previewViews.append(preview)
        }
    }

    func clearPreview() {
        previewViews.forEach { $0.removeFromSuperview() }
        previewViews.removeAll()
    }

    /// Visar en sökträff eller en markering man hoppat till en kort stund. Rutorna är i sidans koordinater.
    func flash(_ rects: [CGRect]) {
        guard isViewLoaded else { return }
        let boxes = rects.map { rect -> UIView in
            let box = UIView(frame: viewRect(rect).insetBy(dx: -3, dy: -2))
            box.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.25)
            box.layer.borderColor = UIColor.systemOrange.cgColor
            box.layer.borderWidth = 2
            box.layer.cornerRadius = 4
            box.isUserInteractionEnabled = false
            view.addSubview(box)
            return box
        }
        UIView.animate(withDuration: 0.6, delay: 2.2, options: [.allowUserInteraction]) {
            boxes.forEach { $0.alpha = 0 }
        } completion: { _ in
            boxes.forEach { $0.removeFromSuperview() }
        }
    }
}
