import AVFoundation
import UIKit

/// Ett svagt prassel när en sida vänds, som papper. Kan stängas av i menyn Bakgrund.
///
/// Ljudet räknas fram en gång i appen (filtrerat brus med ett kort smack på slutet), så att ingen ljudfil
/// med okänd licens behövs. Tre varianter växlas, så att det inte låter likadant varje gång.
/// Ljudsessionen är `.ambient`: ljudet blandas med musik och följer ljudlöst läge.
@MainActor
final class PageTurnSound {

    static let shared = PageTurnSound()

    private var players: [AVAudioPlayer] = []
    private var next = 0
    private var prepared = false

    private init() {}

    /// Gör ljuden klara i förväg, så att det första vändet inte dröjer.
    func prepare() {
        guard !prepared else { return }
        prepared = true
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        for variant in 0..<3 {
            let data = Self.wav(samples: Self.synthesize(seed: UInt32(variant * 7919 + 17)), rate: Self.rate)
            if let player = try? AVAudioPlayer(data: data) {
                player.volume = 0.55
                player.prepareToPlay()
                players.append(player)
            }
        }
    }

    func play() {
        guard ReaderSettings.pageSound else { return }
        prepare()
        guard !players.isEmpty else { return }
        let player = players[next % players.count]
        next += 1
        player.currentTime = 0
        player.play()
    }

    // MARK: Ljudet

    private static let rate = 44_100

    /// Prassel: brus som filtreras och får en mjuk kurva, några knaster och ett smack när sidan lägger sig.
    private static func synthesize(seed: UInt32) -> [Float] {
        let duration = 0.34
        let count = Int(Double(rate) * duration)
        var state = seed
        func random() -> Float {
            // Enkel slumpgenerator, så att ljudet blir likadant varje gång appen startar.
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / Float(1 << 24) * 2 - 1
        }

        var samples = [Float](repeating: 0, count: count)
        var low: Float = 0
        var high: Float = 0
        var previous: Float = 0
        var crackle: Float = 0
        let swishPeak = 0.11 + Double(seed % 5) * 0.008
        for index in 0..<count {
            let t = Double(index) / Double(rate)
            let noise = random()

            // Brus mellan ungefär 400 Hz och 5 kHz.
            low += 0.42 * (noise - low)
            high = 0.94 * (high + low - previous)
            previous = low

            // Svischet stiger och sjunker som en klocka.
            let x = (t - swishPeak) / 0.075
            var envelope = Float(exp(-x * x)) * 0.55

            // Små knaster medan sidan rör sig.
            if t < 0.26, random() > 0.9965 {
                crackle = 0.9 * abs(random())
            }
            crackle *= 0.985
            envelope += crackle * 0.35

            // Smacket när sidan lägger sig: ett kort ljusare utbrott.
            let flap = t - 0.235
            if flap > 0 {
                envelope += Float(exp(-flap / 0.012)) * 0.75
            }
            samples[index] = high * envelope
        }

        // Mjuk in- och uttoning, och normalisera.
        let fade = Int(Double(rate) * 0.004)
        for index in 0..<fade {
            let gain = Float(index) / Float(fade)
            samples[index] *= gain
            samples[count - 1 - index] *= gain
        }
        let peak = samples.map { abs($0) }.max() ?? 1
        if peak > 0 {
            for index in samples.indices {
                samples[index] = samples[index] / peak * 0.5
            }
        }
        return samples
    }

    /// En WAV-fil i minnet: 16 bitar, en kanal.
    private static func wav(samples: [Float], rate: Int) -> Data {
        var data = Data()
        func append32(_ value: UInt32) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 4))
        }
        func append16(_ value: UInt16) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 2))
        }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(UInt32(rate))
        append32(UInt32(rate * 2))
        append16(2)
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(byteCount)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append16(UInt16(bitPattern: Int16(clamped * 32_000)))
        }
        return data
    }
}
