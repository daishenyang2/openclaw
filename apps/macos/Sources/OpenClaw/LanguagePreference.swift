import AppKit
import Foundation
import Observation
import SwiftUI

enum LanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { self.rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .system: "Follow system"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    fileprivate var appleLanguages: [String]? {
        switch self {
        case .system: nil
        case .english: ["en"]
        case .simplifiedChinese: ["zh-Hans"]
        }
    }
}

@MainActor
@Observable
final class LanguagePreferenceStore {
    static let shared = LanguagePreferenceStore()

    private static let appleLanguagesKey = "AppleLanguages"

    var preference: LanguagePreference {
        didSet {
            guard oldValue != self.preference else { return }
            UserDefaults.standard.set(self.preference.rawValue, forKey: languagePreferenceKey)
            self.applyToDefaults()
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: languagePreferenceKey),
           let pref = LanguagePreference(rawValue: raw)
        {
            self.preference = pref
        } else {
            self.preference = .system
        }
        self.applyToDefaults()
    }

    /// Call from app launch (before SwiftUI renders) so the override is in effect
    /// for Bundle.main string lookups on the first frame.
    static func bootstrap() {
        _ = Self.shared
    }

    /// Quit the current app so the user can relaunch with the new AppleLanguages
    /// override picked up cleanly. Language changes cannot be applied live to an
    /// already-loaded bundle / SwiftUI view tree.
    func relaunchForLanguageChange() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func applyToDefaults() {
        if let langs = preference.appleLanguages {
            UserDefaults.standard.set(langs, forKey: Self.appleLanguagesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.appleLanguagesKey)
        }
    }
}
