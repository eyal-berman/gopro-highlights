//
//  GoProVideo.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import Foundation
import AVFoundation

/// Represents a GoPro video file with its metadata and processing status
struct GoProVideo: Identifiable, Codable {
    let id: UUID
    let url: URL
    let filename: String
    let duration: TimeInterval
    let fileSize: Int64

    var telemetry: Telemetry?
    var speedStats: SpeedStatistics?
    var highlights: [Highlight]

    var processingStatus: ProcessingStatus

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.filename = url.lastPathComponent
        self.duration = 0 // Will be populated when video is loaded
        self.fileSize = 0 // Will be populated from file attributes
        self.highlights = []
        self.processingStatus = .pending
    }
}

// MARK: - Processing Status
enum ProcessingStatus: Codable {
    case pending
    case parsing
    case analyzing
    case exporting
    case completed
    case failed(String)

    var description: String {
        switch self {
        case .pending: return "Pending"
        case .parsing: return "Parsing metadata..."
        case .analyzing: return "Analyzing speed data..."
        case .exporting: return "Exporting video..."
        case .completed: return "Completed"
        case .failed(let error): return "Failed: \(error)"
        }
    }
}

// MARK: - Telemetry Data (placeholder for Phase 2)
struct Telemetry: Codable {
    let gpsPoints: [GPSPoint]
    let speedSamples: [SpeedSample]
    let timestamps: [TimeInterval]

    struct GPSPoint: Codable {
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let timestamp: TimeInterval
        let accuracy: Double?
    }

    struct SpeedSample: Codable {
        let speed: Double  // m/s from GPMF
        let timestamp: TimeInterval
        var isAnomaly: Bool

        var speedKmh: Double { speed * 3.6 }
        var speedMph: Double { speed * 2.23694 }
    }
}

// MARK: - Highlight Markers (placeholder for Phase 2)
struct Highlight: Identifiable, Codable {
    let id: UUID
    let timestamp: TimeInterval  // Position in video
    let type: HighlightType
    let confidence: Double?

    enum HighlightType: String, Codable {
        case manual = "MANL"      // User-marked
        case automated = "AIMU"   // IMU-detected
        case fusion = "FUSE"      // Fusion algorithm
    }

    init(timestamp: TimeInterval, type: HighlightType, confidence: Double? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.type = type
        self.confidence = confidence
    }
}

// MARK: - Speed Statistics
struct SpeedStatistics: Codable {
    let maxSpeed: Double       // km/h
    let maxSpeedTime: TimeInterval
    let avgSpeed: Double       // km/h
    let filteredSamples: Int   // Number of anomalies removed
}
