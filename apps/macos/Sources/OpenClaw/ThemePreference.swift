import AppKit
import Observation
import SwiftUI

enum ThemePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { self.rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    fileprivate var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

let themePreferenceKey = "openclaw.themePreference"

@MainActor
@Observable
final class ThemePreferenceStore {
    static let shared = ThemePreferenceStore()

    var preference: ThemePreference {
        didSet {
            guard oldValue != self.preference else { return }
            UserDefaults.standard.set(self.preference.rawValue, forKey: themePreferenceKey)
            self.applyToApp()
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: themePreferenceKey),
           let pref = ThemePreference(rawValue: raw)
        {
            self.preference = pref
        } else {
            self.preference = .system
        }
        self.applyToApp()
    }

    static func bootstrap() {
        _ = Self.shared
    }

    func cycle() {
        switch self.preference {
        case .system: self.preference = .light
        case .light: self.preference = .dark
        case .dark: self.preference = .system
        }
    }

    private func applyToApp() {
        NSApp?.appearance = self.preference.nsAppearance
    }
}
