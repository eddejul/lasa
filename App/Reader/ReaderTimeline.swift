import UIKit

/// V2: tidslinjen i läsarens nederkant, i stället för systemets reglage. En tunn linje med ett streck vid varje
/// kapitelgräns, prickar i markeringarnas färger, röda streck för bokmärken och en rund markör för platsen.
/// När man drar visas kapitlet och sidan i en bubbla ovanför fingret, och läsaren hoppar när man släpper.
///
/// Samma gränssnitt som `UISlider` där läsarna använder det (`value`, `minimumValue`, `maximumValue`,
/// `isTracking`, `.valueChanged` medan man drar och `.touchUpInside` när man släpper), så att läsarnas kod
/// för reglaget står kvar. Linjen, strecken och prickarna ritas med Core Graphics i en egen vy bara när de
/// ändras. När sidan vänds flyttas bara markören och den fyllda delen av linjen (två lager, ingen omritning).
final class ReaderTimeline: UIControl {

    /// En markering på linjen: andelen av boken (0 till 1) och färgen.
    struct Dot: Equatable {
        let position: Double
        let color: UIColor
    }

    var minimumValue: Float = 0 {
        didSet { layoutMarker() }
    }
    var maximumValue: Float = 1 {
        didSet { layoutMarker() }
    }
    /// Platsen, mellan `minimumValue` och `maximumValue`.
    var value: Float = 0 {
        didSet {
            value = min(max(value, minimumValue), maximumValue)
            if value != oldValue {
                layoutMarker()
            }
        }
    }

    /// Kapitelgränserna som andelar av boken (0 till 1).
    var chapters: [Double] = [] {
        didSet { if chapters != oldValue { track.setNeedsDisplay() } }
    }
    /// Markeringarna i sina färger.
    var dots: [Dot] = [] {
        didSet { if dots != oldValue { track.setNeedsDisplay() } }
    }
    /// Bokmärkena som andelar av boken.
    var bookmarks: [Double] = [] {
        didSet { if bookmarks != oldValue { track.setNeedsDisplay() } }
    }
    /// K10: de lästa delarna av boken ur läsloggen (`ReadingLog`), ritade mörkare på linjen.
    var readRanges: [ClosedRange<Double>] = [] {
        didSet { if readRanges != oldValue { track.setNeedsDisplay() } }
    }

    /// Texten i bubblan ovanför fingret medan man drar, satt av läsaren i `.valueChanged`.
    var bubbleText: String? {
        didSet { updateBubble() }
    }

    /// V3: ett långt tryck på linjen (miniatyrerna). Nil stänger av det långa trycket.
    var onLongPress: (() -> Void)? {
        didSet { longPress.isEnabled = onLongPress != nil }
    }

    /// Steget för VoiceOver (öka och minska).
    var accessibilityStep: Float = 0.02

    /// Hur många gånger linjen ritats, och hur lång tid den senaste ritningen tog (till självtestet, V2).
    private(set) static var trackDraws = 0
    private(set) static var lastTrackDrawMilliseconds: Double = 0

    private let track = TimelineTrackView()
    private let fill = CALayer()
    private let knob = UIView()
    private let bubble = PaddedLabel()
    private lazy var longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
    private var dragging = false
    private var valueBeforeDrag: Float = 0

    static let knobSize: CGFloat = 18

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        track.timeline = self
        track.isUserInteractionEnabled = false
        track.isOpaque = false
        track.contentMode = .redraw
        addSubview(track)

        fill.cornerRadius = 1.5
        layer.addSublayer(fill)

        knob.isUserInteractionEnabled = false
        knob.layer.cornerRadius = Self.knobSize / 2
        knob.layer.borderWidth = 2
        knob.layer.shadowColor = UIColor.black.cgColor
        knob.layer.shadowOpacity = 0.2
        knob.layer.shadowRadius = 2
        knob.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(knob)

        bubble.insets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        bubble.numberOfLines = 2
        bubble.textAlignment = .center
        bubble.font = .systemFont(ofSize: 13, weight: .semibold)
        bubble.layer.cornerRadius = 8
        bubble.layer.masksToBounds = true
        bubble.isUserInteractionEnabled = false
        bubble.alpha = 0
        addSubview(bubble)

        longPress.minimumPressDuration = 0.5
        longPress.isEnabled = false
        addGestureRecognizer(longPress)

        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = "Plats i boken"
        apply(Theme.current)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 30)
    }

    /// Sant medan fingret drar, som `UISlider.isTracking`.
    override var isTracking: Bool {
        dragging
    }

    override var isEnabled: Bool {
        didSet { knob.isHidden = !isEnabled }
    }

    func apply(_ palette: Palette) {
        track.lineColor = palette.surfaceSunk
        track.tickColor = palette.inkFaint
        track.ribbonColor = palette.ribbon
        track.setNeedsDisplay()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = palette.accent.cgColor
        CATransaction.commit()
        knob.backgroundColor = palette.page
        knob.layer.borderColor = palette.accent.cgColor
        bubble.backgroundColor = palette.ink
        bubble.textColor = palette.page
    }

    // MARK: Läget

    /// Hur långt in från kanterna linjen börjar, så att markören ryms vid början och slutet.
    var inset: CGFloat {
        Self.knobSize / 2
    }

    /// X-läget för en andel av boken (0 till 1).
    func xPosition(for position: Double) -> CGFloat {
        let width = max(bounds.width - 2 * inset, 1)
        return inset + CGFloat(min(max(position, 0), 1)) * width
    }

    private var fraction: Double {
        let span = maximumValue - minimumValue
        guard span > 0 else { return 0 }
        return Double((value - minimumValue) / span)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if track.frame != bounds {
            track.frame = bounds
        }
        layoutMarker()
        updateBubble()
    }

    /// Flyttar markören och den fyllda delen. Inget ritas om.
    private func layoutMarker() {
        let mid = bounds.midY
        let px = xPosition(for: fraction)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: inset, y: mid - 1.5, width: max(px - inset, 0), height: 3)
        CATransaction.commit()
        knob.frame = CGRect(x: px - Self.knobSize / 2, y: mid - Self.knobSize / 2,
                            width: Self.knobSize, height: Self.knobSize)
        if dragging {
            updateBubble()
        }
    }

    private func updateBubble() {
        guard dragging, let text = bubbleText, !text.isEmpty else {
            if bubble.alpha > 0 {
                UIView.animate(withDuration: 0.15) { self.bubble.alpha = 0 }
            }
            return
        }
        bubble.text = text
        let maxWidth = min(bounds.width, 320)
        var size = bubble.sizeThatFits(CGSize(width: maxWidth, height: 80))
        size.width = min(size.width, maxWidth)
        let center = xPosition(for: fraction)
        let left = min(max(center - size.width / 2, 0), max(bounds.width - size.width, 0))
        bubble.frame = CGRect(x: left, y: bounds.midY - Self.knobSize / 2 - 10 - size.height,
                              width: size.width, height: size.height)
        bubble.alpha = 1
    }

    // MARK: Självtestet

    /// Ritar linjen direkt och svarar hur lång tid det tog i millisekunder.
    func redrawTrackNow() -> Double {
        track.setNeedsDisplay()
        let started = CACurrentMediaTime()
        track.layer.displayIfNeeded()
        return (CACurrentMediaTime() - started) * 1000
    }

    /// Visar bubblan som om fingret drog (nil döljer den), så att den kommer med i självtestets bilder.
    func previewBubble(_ text: String?) {
        dragging = text != nil
        bubbleText = text
        if text == nil {
            bubble.alpha = 0
        }
    }

    // MARK: Fingret

    private func setValue(from touch: UITouch) {
        let width = max(bounds.width - 2 * inset, 1)
        let position = Double(min(max((touch.location(in: self).x - inset) / width, 0), 1))
        value = minimumValue + Float(position) * (maximumValue - minimumValue)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled else { return false }
        valueBeforeDrag = value
        dragging = true
        setValue(from: touch)
        sendActions(for: .valueChanged)
        updateBubble()
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        setValue(from: touch)
        sendActions(for: .valueChanged)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        // UIControl skickar .touchUpInside eller .touchUpOutside, och läsaren hoppar.
        dragging = false
        updateBubble()
    }

    override func cancelTracking(with event: UIEvent?) {
        // Ett avbrutet drag (till exempel det långa trycket) hoppar inte: markören går tillbaka.
        dragging = false
        value = valueBeforeDrag
        updateBubble()
    }

    /// Gör det lättare att träffa linjen med fingret.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -4, dy: -10).contains(point)
    }

    @objc private func handleLongPress(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began else { return }
        if dragging {
            dragging = false
            value = valueBeforeDrag
            updateBubble()
        }
        onLongPress?()
    }

    // MARK: VoiceOver

    override var accessibilityValue: String? {
        get { bubbleText?.replacingOccurrences(of: "\n", with: ", ") ?? "\(Int((fraction * 100).rounded())) procent" }
        set {}
    }

    override func accessibilityIncrement() {
        value += accessibilityStep
        sendActions(for: .valueChanged)
    }

    override func accessibilityDecrement() {
        value -= accessibilityStep
        sendActions(for: .valueChanged)
    }

    // MARK: Ritningen

    /// Linjen, kapitelstrecken, markeringarnas prickar och bokmärkena. Ritas bara när de ändras.
    fileprivate func drawTrack(in context: CGContext, view: TimelineTrackView) {
        let started = CACurrentMediaTime()
        let mid = bounds.midY
        let line = CGRect(x: inset, y: mid - 1.5, width: max(bounds.width - 2 * inset, 0), height: 3)
        context.setFillColor(view.lineColor.cgColor)
        context.addPath(UIBezierPath(roundedRect: line, cornerRadius: 1.5).cgPath)
        context.fillPath()

        // K10: det man läst, mörkare på linjen.
        context.setFillColor(view.tickColor.cgColor)
        for range in readRanges {
            let start = xPosition(for: range.lowerBound)
            let end = max(xPosition(for: range.upperBound), start + 2)
            context.addPath(UIBezierPath(roundedRect: CGRect(x: start, y: mid - 1.5, width: end - start, height: 3),
                                         cornerRadius: 1.5).cgPath)
            context.fillPath()
        }

        // Kapitelgränserna, högst ett streck per två punkter.
        context.setFillColor(view.tickColor.cgColor)
        var lastTick: CGFloat = -10
        for position in chapters.sorted() where position > 0.001 && position < 0.999 {
            let px = xPosition(for: position)
            guard px - lastTick >= 2 else { continue }
            lastTick = px
            context.fill(CGRect(x: px - 0.75, y: mid - 5.5, width: 1.5, height: 11))
        }

        // Markeringarna, högst en prick per fyra punkter (många markeringar på samma sida blir en prick).
        var usedSlots = Set<Int>()
        for dot in dots {
            let px = xPosition(for: dot.position)
            guard usedSlots.insert(Int(px / 4)).inserted else { continue }
            context.setFillColor(dot.color.cgColor)
            context.fillEllipse(in: CGRect(x: px - 3, y: mid - 10.5, width: 6, height: 6))
        }

        // Bokmärkena.
        context.setFillColor(view.ribbonColor.cgColor)
        for position in bookmarks {
            let px = xPosition(for: position)
            context.addPath(UIBezierPath(roundedRect: CGRect(x: px - 1.5, y: mid - 9.5, width: 3, height: 19),
                                         cornerRadius: 1).cgPath)
            context.fillPath()
        }
        Self.trackDraws += 1
        Self.lastTrackDrawMilliseconds = (CACurrentMediaTime() - started) * 1000
    }
}

/// Vyn som tidslinjen ritar sin linje i. En egen vy, så att markören kan flyttas utan att linjen ritas om.
final class TimelineTrackView: UIView {
    weak var timeline: ReaderTimeline?
    var lineColor: UIColor = .systemGray5
    var tickColor: UIColor = .systemGray3
    var ribbonColor: UIColor = .systemRed

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        timeline?.drawTrack(in: context, view: self)
    }
}
