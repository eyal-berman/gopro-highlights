//
//  SettingsViewModel.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import Foundation
import Observation

/// Manages user settings and preferences
@MainActor
@Observable
class SettingsViewModel {
    var settings: ExportSettings

    init() {
        // Load settings from UserDefaults or use defaults
        if let savedSettings = Self.loadSettings() {
            self.settings = savedSettings
        } else {
            self.settings = ExportSettings()
        }
    }

    // MARK: - Persistence
    private static let settingsKey = "com.goprohighlight.settings"

    func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: Self.settingsKey)
        }
    }

    private static func loadSettings() -> ExportSettings? {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(ExportSettings.self, from: data) else {
            return nil
        }
        return settings
    }

    // MARK: - Convenience Methods
    func resetToDefaults() {
        settings = ExportSettings()
        saveSettings()
    }

    // MARK: - Validation
    func validateSettings() -> [String] {
        var warnings: [String] = []

        if settings.highlightSettings.beforeSeconds < 0 {
            warnings.append("Highlight 'before' seconds cannot be negative")
        }

        if settings.highlightSettings.afterSeconds < 0 {
            warnings.append("Highlight 'after' seconds cannot be negative")
        }

        if settings.maxSpeedSettings.topN < 1 {
            warnings.append("Max speed 'top N' must be at least 1")
        }

        if settings.overlaySettings.speedGaugeEnabled && settings.overlaySettings.maxSpeed <= 0 {
            warnings.append("Speed gauge max speed must be positive")
        }

        if settings.overlaySettings.dateTimeEnabled && settings.overlaySettings.dateTimeFontSize < 8 {
            warnings.append("Date/Time font size must be at least 8")
        }

        return warnings
    }

    func estimateProcessingTime(for videoCount: Int, totalDuration: TimeInterval) -> TimeInterval {
        // Rough estimation based on settings
        var multiplier = 1.0

        // Parsing and analysis: ~0.1x duration
        multiplier += 0.1

        // Video extraction: depends on quality
        switch settings.outputSettings.quality {
        case .original:
            multiplier += 0.5  // Fast, just copying
        case .high:
            multiplier += 1.5  // Re-encoding at high quality
        case .medium:
            multiplier += 1.0
        case .low:
            multiplier += 0.7
        }

        // Overlays add significant time
        if settings.overlaySettings.speedGaugeEnabled {
            multiplier += 0.5
        }

        if settings.overlaySettings.dateTimeEnabled {
            multiplier += 0.3
        }

        // Stitching
        if settings.outputSettings.outputMode != .individual {
            multiplier += 0.5
        }

        return totalDuration * multiplier
    }
}
