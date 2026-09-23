import AVFoundation
import QuartzCore

/// Tiny clicks played while moving through the list or scrolling it — like the detents of a dial.
/// The click is synthesized once at launch, so there are no audio files to ship.
enum Sounds {
    private static let key = "navigationSounds"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    // A few players so quick ticks can overlap instead of cutting each other off.
    private static let players: [AVAudioPlayer] = {
        let data = click(frequency: 1050, duration: 0.06)
        return (0..<4).compactMap { _ in
            let player = try? AVAudioPlayer(data: data)
            player?.enableRate = true
            player?.prepareToPlay()
            return player
        }
    }()
    private static var next = 0
    private static var lastTick: CFTimeInterval = 0

    /// `pitch` slightly above or below 1 tells different lists apart (e.g. the ⌘K menu ticks higher).
    static func tick(pitch: Float = 1, volume: Float = 0.16) {
        guard enabled, !players.isEmpty else { return }
        let now = CACurrentMediaTime()
        guard now - lastTick > 0.045 else { return } // held arrow keys shouldn't turn into a buzz
        lastTick = now
        let player = players[next % players.count]
        next += 1
        player.currentTime = 0
        player.rate = pitch * Float.random(in: 0.98...1.02)
        player.volume = volume
        player.play()
    }

    private static let dustPlayer: AVAudioPlayer? = {
        let player = try? AVAudioPlayer(data: sand())
        player?.prepareToPlay()
        return player
    }()

    /// The delete sound: a soft rush of sand with a few faint glints in it.
    static func dissolve() {
        guard enabled, let player = dustPlayer else { return }
        player.currentTime = 0
        player.volume = 0.3
        player.play()
    }

    private static var copyPlayers: [CopySound: AVAudioPlayer] = [:]

    /// Plays one of the synthesized copy sounds (made once, then reused).
    static func playCopy(_ sound: CopySound) {
        let player: AVAudioPlayer
        if let cached = copyPlayers[sound] {
            player = cached
        } else {
            let data: Data
            switch sound {
            case .softTap: data = softTap()
            case .paper: data = paper()
            case .glass: data = glass()
            case .keyClick: data = keyClick()
            case .droplet: data = droplet()
            default: return
            }
            guard let made = try? AVAudioPlayer(data: data) else { return }
            made.prepareToPlay()
            copyPlayers[sound] = made
            player = made
        }
        player.currentTime = 0
        player.volume = 0.4
        player.play()
    }

    /// Scales samples so the loudest point sits at `level`, then encodes them.
    private static func normalized(_ s: [Double], level: Double = 0.5) -> Data {
        let peak = s.map(abs).max() ?? 1
        return wav(s.map { $0 / max(peak, 0.0001) * level })
    }

    /// A warm, muted "tuk" — like a pencil tapping a desk.
    private static func softTap() -> Data {
        let count = Int(rate * 0.12)
        var out = [Double](repeating: 0, count: count)
        var phase = 0.0, low = 0.0
        for i in 0..<count {
            let t = Double(i) / rate
            phase += 2 * .pi * (330 - 90 * min(1, t / 0.05)) / rate
            let body = sin(phase) * min(1, t / 0.003) * exp(-t * 48)
            low += (1 - exp(-2 * .pi * 1800 / rate)) * (Double.random(in: -1...1) - low)
            out[i] = body + low * exp(-t * 110) * 0.9
        }
        return normalized(out, level: 0.45)
    }

    /// A short soft swish — a sheet of paper sliding.
    private static func paper() -> Data {
        let count = Int(rate * 0.16)
        var out = [Double](repeating: 0, count: count)
        var hi = 0.0, lo = 0.0
        for i in 0..<count {
            let t = Double(i) / rate
            let n = Double.random(in: -1...1)
            hi += (1 - exp(-2 * .pi * 5000 / rate)) * (n - hi)
            lo += (1 - exp(-2 * .pi * 900 / rate)) * (hi - lo)
            let envelope = pow(min(1, t / 0.02), 1.5) * exp(-max(0, t - 0.02) * 32)
            out[i] = (hi - lo) * envelope
        }
        return normalized(out, level: 0.35)
    }

    /// A tiny, delicate glass "ting".
    private static func glass() -> Data {
        let count = Int(rate * 0.4)
        var out = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / rate
            let attack = min(1, t / 0.002)
            out[i] = attack * (sin(2 * .pi * 2093 * t) * exp(-t * 16)
                             + 0.35 * sin(2 * .pi * 3136 * t) * exp(-t * 24)
                             + 0.15 * sin(2 * .pi * 4699 * t) * exp(-t * 34))
        }
        return normalized(out, level: 0.3)
    }

    /// A soft mechanical keyboard "thock".
    private static func keyClick() -> Data {
        let count = Int(rate * 0.1)
        var out = [Double](repeating: 0, count: count)
        var phase = 0.0, low = 0.0
        for i in 0..<count {
            let t = Double(i) / rate
            phase += 2 * .pi * (180 * pow(80.0 / 180.0, min(1, t / 0.07))) / rate
            low += (1 - exp(-2 * .pi * 1400 / rate)) * (Double.random(in: -1...1) - low)
            out[i] = sin(phase) * min(1, t / 0.002) * exp(-t * 40) + low * exp(-t * 70) * 1.2
        }
        return normalized(out, level: 0.5)
    }

    private static let rate = 44_100.0

    /// Two soft droplets — a quick upward glide into a warm tone, the second smaller — with a faint echo.
    private static func droplet() -> Data {
        let duration = 0.34
        let count = Int(rate * duration)
        var dry = [Double](repeating: 0, count: count)
        func drop(at start: Double, from f0: Double, to f1: Double, gain: Double) {
            var phase = 0.0
            let first = Int(start * rate)
            for i in first..<count {
                let t = Double(i - first) / rate
                let f = f0 * pow(f1 / f0, min(1, t / 0.045)) // glide up over 45 ms, then hold
                phase += 2 * .pi * f / rate
                let envelope = min(1, t / 0.004) * exp(-t * 26)
                dry[i] += (sin(phase) + 0.16 * sin(2 * phase) * exp(-t * 30)) * envelope * gain
            }
        }
        drop(at: 0, from: 430, to: 1250, gain: 1)
        drop(at: 0.075, from: 640, to: 1720, gain: 0.32)
        // A faint, darker echo gives it a little room.
        let delay = Int(0.1 * rate)
        var wet = dry
        var smooth = 0.0
        for i in delay..<count {
            smooth += 0.3 * (dry[i - delay] - smooth)
            wet[i] += smooth * 0.22
        }
        let peak = wet.map(abs).max() ?? 1
        return wav(wet.map { $0 / peak * 0.5 })
    }

    /// A soft, rounded tap: a gently falling sine with a smooth attack, as 16-bit mono WAV data.
    private static func click(frequency: Double, duration: Double) -> Data {
        let count = Int(rate * duration)
        var samples = [Double]()
        samples.reserveCapacity(count)
        for i in 0..<count {
            let t = Double(i) / rate
            let envelope = exp(-t * 70) * min(1, t / 0.006) // 6 ms attack, soft decay
            let pitch = frequency * (1 - 0.15 * t / duration) // settles slightly downward
            samples.append(sin(2 * .pi * pitch * t) * envelope * 0.5)
        }
        return wav(samples)
    }

    /// Filtered noise that swells in and falls away while its brightness drops, plus sparse glints.
    private static func sand() -> Data {
        let duration = 0.62
        let count = Int(rate * duration)
        var samples = [Double](repeating: 0, count: count)
        var low = 0.0, rumble = 0.0
        for i in 0..<count {
            let t = Double(i) / rate
            // Brightness sweeps from ~3.2 kHz down to ~600 Hz.
            let cutoff = 600 + 2600 * exp(-t * 5)
            low += (1 - exp(-2 * .pi * cutoff / rate)) * (Double.random(in: -1...1) - low)
            rumble += (1 - exp(-2 * .pi * 280 / rate)) * (low - rumble)
            let envelope = pow(min(1, t / 0.06), 2) * exp(-max(0, t - 0.06) * 6.5)
            samples[i] = (low - rumble) * envelope * 1.1
        }
        // Glints: tiny, windowed high sines, denser at the start like grains lifting off.
        for _ in 0..<16 {
            let at = pow(Double.random(in: 0...1), 1.6) * 0.38
            let freq = Double.random(in: 2200...3600)
            let length = Int(rate * 0.014)
            let start = Int(at * rate)
            for j in 0..<length where start + j < count {
                let window = sin(.pi * Double(j) / Double(length))
                samples[start + j] += sin(2 * .pi * freq * Double(j) / rate) * window * window * 0.07
            }
        }
        return wav(samples.map { $0 * 0.55 })
    }

    /// 16-bit mono WAV data for samples in -1...1.
    private static func wav(_ input: [Double]) -> Data {
        let samples = input.map { Int16(max(-1, min(1, $0)) * Double(Int16.max)) }

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate) * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        samples.forEach { append($0) }
        return data
    }
}
