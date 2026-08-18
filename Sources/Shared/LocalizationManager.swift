import Foundation
import SwiftUI

/// Application-level localization manager: support for switching languages at runtime (independent of system preferences)
///
/// Working principle:
/// 1. Maintain the current language identifier (`currentLanguage`) and persist it in `Preferences.language`
/// 2. Load the corresponding `.lproj` Bundle according to the current language for `String(localized:bundle:)` search
/// 3. Use SwiftUI `.environment(\.locale, ...)` to automatically match the String Catalog of `Text`
@Observable
@MainActor
final class LocalizationManager {
    static let shared = LocalizationManager()

    /// Current language identifier, synchronized with Preferences.language
    var currentLanguage: String = "en" {
        didSet {
            if oldValue != currentLanguage {
                updateBundle()
            }
        }
    }

    /// The Locale corresponding to the current language is injected into the SwiftUI environment
    var locale: Locale {
        Locale(identifier: currentLanguage)
    }

    /// Localization Bundle corresponding to the current language
    private(set) var bundle: Bundle = .main

    /// Supported language list
    static let supportedLanguages: [(id: String, name: String, localName: String)] = [
        ("en", "English", "English"),
        ("zh-Hans", "Chinese (Simplified)", "简体中文"),
    ]

    private init() {
        updateBundle()
    }

    /// Synchronizing language settings from Preferences
    func sync(from language: String) {
        if currentLanguage != language {
            currentLanguage = language
        }
    }

    private func updateBundle() {
        if let path = Bundle.main.path(forResource: currentLanguage, ofType: "lproj"),
           let locBundle = Bundle(path: path) {
            bundle = locBundle
        } else {
            // fallback: try base
            bundle = .main
        }
    }
}

// MARK: - String convenient localization extension

extension String {
    /// Localization using LocalizationManager's bundle
    /// Usage: `"button.cancel".localized`
    @MainActor
    var localized: String {
        String(localized: String.LocalizationValue(self), bundle: LocalizationManager.shared.bundle)
    }
}
