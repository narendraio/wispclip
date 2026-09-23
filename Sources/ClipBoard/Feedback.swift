import AppKit

/// The sounds you can pick for "something was copied".
enum CopySound: String, CaseIterable {
    case softTap = "Soft Tap"
    case paper = "Paper"
    case glass = "Glass"
    case keyClick = "Key Click"
    case droplet = "Droplet"
    case tink = "Tink"
    case pop = "Pop"
    case purr = "Purr"
    case bottle = "Bottle"
    case none = "None"

    /// macOS built-in sounds are played by name; the rest are synthesized by `Sounds`.
    var isSystem: Bool { [.tink, .pop, .purr, .bottle].contains(self) }
}

/// The sound + trackpad tap played when something new is copied.
enum Feedback {
    private static let key = "copySound"

    static var sound: CopySound {
        get {
            if let raw = UserDefaults.standard.string(forKey: key), let s = CopySound(rawValue: raw) { return s }
            // Someone who had turned off the old "Sound on Copy" keeps silence.
            return UserDefaults.standard.object(forKey: "soundOnCopy") as? Bool == false ? .none : .softTap
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    static func copied() {
        guard sound != .none else { return }
        play(sound)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    static func play(_ sound: CopySound) {
        guard sound != .none else { return }
        if sound.isSystem {
            let s = NSSound(named: NSSound.Name(sound.rawValue))
            s?.volume = 0.22
            s?.play()
        } else {
            Sounds.playCopy(sound)
        }
    }
}
