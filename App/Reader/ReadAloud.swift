import AVFoundation
import NaturalLanguage
import UIKit

/// Uppläsning med iOS egna röster (fas 6). Läser en sida i taget, svenska eller engelska efter texten,
/// och säger till vilket ord som läses, så att läsaren kan markera det.
/// Används bara från huvudtråden. Rösterna finns i iPaden och kräver inget nät.
final class ReadAloud: NSObject, AVSpeechSynthesizerDelegate {

    static let shared = ReadAloud()

    private let synthesizer = AVSpeechSynthesizer()
    private var onWord: ((NSRange) -> Void)?
    private var onFinish: (() -> Void)?
    private var current: AVSpeechUtterance?
    private(set) var isActive = false

    private static let rateKey = "speech.rate"

    /// Hastigheter att välja bland, som andel av iOS normala.
    static let rates: [(title: String, factor: Float)] = [("Långsamt", 0.8), ("Normalt", 1.0), ("Snabbare", 1.2), ("Snabbt", 1.45)]

    static var rateFactor: Float {
        get {
            let stored = UserDefaults.standard.float(forKey: rateKey)
            return stored > 0 ? stored : 1.0
        }
        set {
            UserDefaults.standard.set(newValue, forKey: rateKey)
        }
    }

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isPaused: Bool {
        synthesizer.isPaused
    }

    /// Läser en text. `onWord` får ordets plats i texten (UTF-16), `onFinish` anropas när texten är slut,
    /// men inte när uppläsningen stoppas.
    func speak(_ text: String, onWord: @escaping (NSRange) -> Void, onFinish: @escaping () -> Void) {
        stopSpeaking()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: text)
        let base = AVSpeechUtteranceDefaultSpeechRate
        utterance.rate = min(max(base * Self.rateFactor, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        utterance.postUtteranceDelay = 0.15
        self.onWord = onWord
        self.onFinish = onFinish
        current = utterance
        isActive = true
        synthesizer.speak(utterance)
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    /// Stoppar och glömmer vad som skulle hända efteråt.
    func stop() {
        stopSpeaking()
        isActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        // Tillbaka till samma läge som bläddringsljudet använder.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
    }

    private func stopSpeaking() {
        onWord = nil
        onFinish = nil
        current = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    /// En svensk röst för svensk text, en engelsk för engelsk.
    static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.swedish, .english]
        recognizer.processString(String(text.prefix(1200)))
        let code = recognizer.dominantLanguage == .english ? "en" : "sv"
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(code) }
        // Bättre kvalitet först, om användaren har laddat ner en sådan röst.
        if let enhanced = voices.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: code == "en" ? "en-US" : "sv-SE") ?? voices.first
    }

    // MARK: AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, utterance === self.current else { return }
            self.onWord?(characterRange)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, utterance === self.current else { return }
            let finish = self.onFinish
            self.onWord = nil
            self.onFinish = nil
            self.current = nil
            finish?()
        }
    }
}

/// Raden som visas medan boken läses upp: paus och stopp.
final class ReadAloudBar: UIView {

    var onPause: (() -> Void)?
    var onStop: (() -> Void)?

    private let pauseButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 22
        layer.masksToBounds = true
        let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        let label = UILabel()
        label.text = "Läser upp"
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel

        pauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        pauseButton.accessibilityLabel = "Pausa"
        pauseButton.addAction(UIAction { [weak self] _ in self?.onPause?() }, for: .touchUpInside)

        let stop = UIButton(type: .system)
        stop.setImage(UIImage(systemName: "stop.fill"), for: .normal)
        stop.accessibilityLabel = "Sluta läsa upp"
        stop.addAction(UIAction { [weak self] _ in self?.onStop?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [label, pauseButton, stop])
        stack.axis = .horizontal
        stack.spacing = 18
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) används inte")
    }

    func setPaused(_ paused: Bool) {
        pauseButton.setImage(UIImage(systemName: paused ? "play.fill" : "pause.fill"), for: .normal)
        pauseButton.accessibilityLabel = paused ? "Fortsätt" : "Pausa"
    }

    /// Lägger raden nere på sidan.
    func install(in view: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14),
        ])
    }
}
