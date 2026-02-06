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

        // Speed Gauge Settings
        var gaugeStyle: GaugeStyle = .semiCircular
        var maxSpeed: Double = 150.0  // km/h
        var speedUnits: SpeedUnit = .kmh
        var gaugePosition: OverlayPosition = .bottomRight
        var gaugeOpacity: Double = 0.9

        // Date/Time Settings
        var dateTimeFormat: DateTimeFormat = .both
        var dateTimePosition: OverlayPosition = .bottomLeft
        var dateTimeFontSize: Double = 24.0
        var dateTimeOpacity: Double = 0.9

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
    }

    // MARK: - Output Settings
    struct OutputSettings: Codable, Sendable, Equatable {
        var quality: ExportQuality = .high
        var format: VideoFormat = .mp4
        var outputMode: OutputMode = .individual
        var outputDirectory: URL?

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
                case .original: return "Keep original quality (fastest)"
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
    }
}
