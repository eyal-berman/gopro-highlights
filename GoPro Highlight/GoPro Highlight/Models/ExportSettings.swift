//
//  ExportSettings.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import Foundation

/// User configuration for video export and processing
struct ExportSettings: Codable, Sendable, Equatable {
    var highlightSettings: HighlightSettings
    var maxSpeedSettings: MaxSpeedSettings
    var overlaySettings: OverlaySettings
    var outputSettings: OutputSettings

    init() {
        self.highlightSettings = HighlightSettings()
        self.maxSpeedSettings = MaxSpeedSettings()
        self.overlaySettings = OverlaySettings()
        self.outputSettings = OutputSettings()
    }

    // MARK: - Highlight Settings
    struct HighlightSettings: Codable, Sendable, Equatable {
        var beforeSeconds: Double = 5.0
        var afterSeconds: Double = 10.0
        var mergeOverlapping: Bool = true
        var includeOverlay: Bool = false
    }

    // MARK: - Max Speed Settings
    struct MaxSpeedSettings: Codable, Sendable, Equatable {
        var enabled: Bool = true
        var topN: Int = 3
        var beforeSeconds: Double = 5.0
        var afterSeconds: Double = 5.0
        var includeOverlay: Bool = true
    }

    // MARK: - Overlay Settings
    struct OverlaySettings: Codable, Sendable, Equatable {
        var speedGaugeEnabled: Bool = true
        var dateTimeEnabled: Bool = true
        var pisteDetailsEnabled: Bool = false

        // Speed Gauge Settings
        var gaugeStyle: GaugeStyle = .semiCircular
        var maxSpeed: Double = 150.0  // km/h
        var speedUnits: SpeedUnit = .kmh
        var gaugePosition: OverlayPosition = .bottomRight
        var gaugeOpacity: Double = 0.9
        var gaugeScale: Double = 1.0

        // Date/Time Settings
        var dateTimeFormat: DateTimeFormat = .both
        var dateTimePosition: OverlayPosition = .bottomLeft
        var dateTimeFontSize: Double = 24.0
        var dateTimeOpacity: Double = 0.9

        // Piste Details Settings
        var pisteDetailsPosition: OverlayPosition = .topLeft
        var pisteDetailsFontSize: Double = 22.0
        var pisteDetailsOpacity: Double = 0.9

        enum GaugeStyle: String, Codable, CaseIterable, Sendable {
            case semiCircular = "Semi-Circular"
            case fullCircular = "Full Circle"
            case linear = "Linear"
        }

        enum SpeedUnit: String, Codable, CaseIterable, Sendable {
            case kmh = "km/h"
            case mph = "mph"
        }

        enum DateTimeFormat: String, Codable, CaseIterable, Sendable {
            case dateOnly = "Date Only"
            case timeOnly = "Time Only"
            case both = "Date & Time"
            case timestamp = "Timestamp"

            nonisolated func format(date: Date) -> String {
                switch self {
                case .dateOnly:
                    return date.formatted(date: .abbreviated, time: .omitted)
                case .timeOnly:
                    return date.formatted(date: .omitted, time: .standard)
                case .both:
                    return date.formatted(date: .abbreviated, time: .shortened)
                case .timestamp:
                    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                    return String(format: "%04d-%02d-%02d %02d:%02d:%02d",
                                  c.year ?? 0, c.month ?? 0, c.day ?? 0,
                                  c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
                }
            }
        }

        enum OverlayPosition: String, Codable, CaseIterable, Sendable {
            case topLeft = "Top Left"
            case topRight = "Top Right"
            case bottomLeft = "Bottom Left"
            case bottomRight = "Bottom Right"
            case center = "Center"

            nonisolated var alignment: (horizontal: Double, vertical: Double) {
                switch self {
                case .topLeft: return (0.1, 0.1)
                case .topRight: return (0.9, 0.1)
                case .bottomLeft: return (0.1, 0.9)
                case .bottomRight: return (0.9, 0.9)
                case .center: return (0.5, 0.5)
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case speedGaugeEnabled
            case dateTimeEnabled
            case pisteDetailsEnabled
            case gaugeStyle
            case maxSpeed
            case speedUnits
            case gaugePosition
            case gaugeOpacity
            case gaugeScale
            case dateTimeFormat
            case dateTimePosition
            case dateTimeFontSize
            case dateTimeOpacity
            case pisteDetailsPosition
            case pisteDetailsFontSize
            case pisteDetailsOpacity
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            speedGaugeEnabled = try container.decodeIfPresent(Bool.self, forKey: .speedGaugeEnabled) ?? true
            dateTimeEnabled = try container.decodeIfPresent(Bool.self, forKey: .dateTimeEnabled) ?? true
            pisteDetailsEnabled = try container.decodeIfPresent(Bool.self, forKey: .pisteDetailsEnabled) ?? false

            gaugeStyle = try container.decodeIfPresent(GaugeStyle.self, forKey: .gaugeStyle) ?? .semiCircular
            maxSpeed = try container.decodeIfPresent(Double.self, forKey: .maxSpeed) ?? 150.0
            speedUnits = try container.decodeIfPresent(SpeedUnit.self, forKey: .speedUnits) ?? .kmh
            gaugePosition = try container.decodeIfPresent(OverlayPosition.self, forKey: .gaugePosition) ?? .bottomRight
            gaugeOpacity = try container.decodeIfPresent(Double.self, forKey: .gaugeOpacity) ?? 0.9
            gaugeScale = try container.decodeIfPresent(Double.self, forKey: .gaugeScale) ?? 1.0

            dateTimeFormat = try container.decodeIfPresent(DateTimeFormat.self, forKey: .dateTimeFormat) ?? .both
            dateTimePosition = try container.decodeIfPresent(OverlayPosition.self, forKey: .dateTimePosition) ?? .bottomLeft
            dateTimeFontSize = try container.decodeIfPresent(Double.self, forKey: .dateTimeFontSize) ?? 24.0
            dateTimeOpacity = try container.decodeIfPresent(Double.self, forKey: .dateTimeOpacity) ?? 0.9

            pisteDetailsPosition = try container.decodeIfPresent(OverlayPosition.self, forKey: .pisteDetailsPosition) ?? .topLeft
            pisteDetailsFontSize = try container.decodeIfPresent(Double.self, forKey: .pisteDetailsFontSize) ?? 22.0
            pisteDetailsOpacity = try container.decodeIfPresent(Double.self, forKey: .pisteDetailsOpacity) ?? 0.9
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(speedGaugeEnabled, forKey: .speedGaugeEnabled)
            try container.encode(dateTimeEnabled, forKey: .dateTimeEnabled)
            try container.encode(pisteDetailsEnabled, forKey: .pisteDetailsEnabled)

            try container.encode(gaugeStyle, forKey: .gaugeStyle)
            try container.encode(maxSpeed, forKey: .maxSpeed)
            try container.encode(speedUnits, forKey: .speedUnits)
            try container.encode(gaugePosition, forKey: .gaugePosition)
            try container.encode(gaugeOpacity, forKey: .gaugeOpacity)
            try container.encode(gaugeScale, forKey: .gaugeScale)

            try container.encode(dateTimeFormat, forKey: .dateTimeFormat)
            try container.encode(dateTimePosition, forKey: .dateTimePosition)
            try container.encode(dateTimeFontSize, forKey: .dateTimeFontSize)
            try container.encode(dateTimeOpacity, forKey: .dateTimeOpacity)

            try container.encode(pisteDetailsPosition, forKey: .pisteDetailsPosition)
            try container.encode(pisteDetailsFontSize, forKey: .pisteDetailsFontSize)
            try container.encode(pisteDetailsOpacity, forKey: .pisteDetailsOpacity)
        }
    }

    // MARK: - Output Settings
    struct OutputSettings: Codable, Sendable, Equatable {
        var quality: ExportQuality = .high
        var format: VideoFormat = .mp4
        var outputMode: OutputMode = .individual
        var outputDirectory: URL?
        var outputDirectoryBookmarkData: Data?
        var preferPassthroughWhenNoOverlays: Bool = true
        var includePisteInFilenames: Bool = false

        enum ExportQuality: String, Codable, CaseIterable, Sendable {
            case original = "Original Quality"
            case high = "High (1080p)"
            case medium = "Medium (720p)"
            case low = "Low (480p)"

            nonisolated var avPreset: String {
                switch self {
                case .original: return "AVAssetExportPresetPassthrough"
                case .high: return "AVAssetExportPreset1920x1080"
                case .medium: return "AVAssetExportPreset1280x720"
                case .low: return "AVAssetExportPreset960x540"
                }
            }

            var description: String {
                switch self {
                case .original: return "Re-encode at highest quality (keeps dimensions, not bit-exact source)"
                case .high: return "1920x1080, ~10 Mbps"
                case .medium: return "1280x720, ~5 Mbps"
                case .low: return "960x540, ~2.5 Mbps"
                }
            }
        }

        enum VideoFormat: String, Codable, CaseIterable, Sendable {
            case mp4 = "MP4"
            case mov = "MOV"

            nonisolated var fileExtension: String {
                switch self {
                case .mp4: return "mp4"
                case .mov: return "mov"
                }
            }
        }

        enum OutputMode: String, Codable, CaseIterable, Sendable {
            case individual = "Individual Clips"
            case stitched = "Single Stitched Video"
            case both = "Both Individual & Stitched"
        }

        enum CodingKeys: String, CodingKey {
            case quality
            case format
            case outputMode
            case outputDirectory
            case outputDirectoryBookmarkData
            case preferPassthroughWhenNoOverlays
            case includePisteInFilenames
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            quality = try container.decodeIfPresent(ExportQuality.self, forKey: .quality) ?? .high
            _ = try container.decodeIfPresent(VideoFormat.self, forKey: .format)
            format = .mp4
            outputMode = try container.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? .individual
            outputDirectory = try container.decodeIfPresent(URL.self, forKey: .outputDirectory)
            outputDirectoryBookmarkData = try container.decodeIfPresent(Data.self, forKey: .outputDirectoryBookmarkData)
            preferPassthroughWhenNoOverlays = try container.decodeIfPresent(Bool.self, forKey: .preferPassthroughWhenNoOverlays) ?? true
            includePisteInFilenames = try container.decodeIfPresent(Bool.self, forKey: .includePisteInFilenames) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(quality, forKey: .quality)
            try container.encode(format, forKey: .format)
            try container.encode(outputMode, forKey: .outputMode)
            try container.encodeIfPresent(outputDirectory, forKey: .outputDirectory)
            try container.encodeIfPresent(outputDirectoryBookmarkData, forKey: .outputDirectoryBookmarkData)
            try container.encode(preferPassthroughWhenNoOverlays, forKey: .preferPassthroughWhenNoOverlays)
            try container.encode(includePisteInFilenames, forKey: .includePisteInFilenames)
        }

        var shouldAttemptPassthrough: Bool {
            quality == .original && preferPassthroughWhenNoOverlays
        }

        @discardableResult
        mutating func setOutputDirectory(_ url: URL?) -> Bool {
            outputDirectory = url

            guard let url else {
                outputDirectoryBookmarkData = nil
                return true
            }

            do {
                outputDirectoryBookmarkData = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                return true
            } catch {
                outputDirectoryBookmarkData = nil
                return false
            }
        }

        mutating func ensureSecurityScopedBookmark() {
            guard outputDirectoryBookmarkData == nil, let outputDirectory else { return }
            _ = setOutputDirectory(outputDirectory)
        }

        mutating func resolveOutputDirectory() -> URL? {
            guard let bookmarkData = outputDirectoryBookmarkData else {
                return outputDirectory
            }

            var isStale = false
            do {
                let resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                outputDirectory = resolvedURL

                if isStale {
                    _ = setOutputDirectory(resolvedURL)
                }

                return resolvedURL
            } catch {
                return outputDirectory
            }
        }
    }
}
