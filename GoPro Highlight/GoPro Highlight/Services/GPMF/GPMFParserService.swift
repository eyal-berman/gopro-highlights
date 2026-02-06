//
//  GPMFParserService.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import Foundation
import AVFoundation

/// Service for parsing GoPro Metadata Format (GPMF) from MP4 files
actor GPMFParserService {

    /// Extracts telemetry data from a GoPro video
    func extractTelemetry(from videoURL: URL) async throws -> Telemetry {
        // TODO: Integrate with GoPro's C GPMF parser library
        // For now, return mock data for testing

        return try await extractTelemetryMock(from: videoURL)
    }

    /// Finds highlight markers in video metadata
    func findHighlights(in videoURL: URL) async throws -> [Highlight] {
        // TODO: Parse HLMT markers from video metadata
        // For now, return mock data

        return []
    }

    // MARK: - Mock Implementation (for testing without GPMF library)

    private func extractTelemetryMock(from videoURL: URL) async throws -> Telemetry {
        // This is a MOCK implementation for testing the UI
        // Replace with actual GPMF parsing once the library is integrated

        let asset = AVAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        // Generate mock GPS points (simulating a ski run)
        var gpsPoints: [Telemetry.GPSPoint] = []
        var speedSamples: [Telemetry.SpeedSample] = []
        var timestamps: [TimeInterval] = []

        let sampleRate = 18.0 // GoPro typically samples at ~18Hz
        let totalSamples = Int(durationSeconds * sampleRate)

        // Mock coordinates (approximate ski resort location)
        let baseLat = 46.5 // Alps region
        let baseLon = 7.5

        for i in 0..<totalSamples {
            let timestamp = Double(i) / sampleRate

            // Simulate GPS trajectory with small variations
            let lat = baseLat + Double.random(in: -0.001...0.001)
            let lon = baseLon + Double.random(in: -0.001...0.001)
            let alt = 2000 + Double(i) * -0.5 // Descending

            let gpsPoint = Telemetry.GPSPoint(
                latitude: lat,
                longitude: lon,
                altitude: alt,
                timestamp: timestamp,
                accuracy: 5.0
            )
            gpsPoints.append(gpsPoint)

            // Simulate speed (skiing speed pattern)
            let speedKmh: Double
            let progress = Double(i) / Double(totalSamples)

            if progress < 0.1 || progress > 0.9 {
                // Start and end: slow
                speedKmh = Double.random(in: 5...15)
            } else {
                // Middle: faster with variations
                speedKmh = 20 + sin(progress * .pi * 4) * 20 + Double.random(in: -5...5)
            }

            let speedMs = speedKmh / 3.6

            let speedSample = Telemetry.SpeedSample(
                speed: speedMs,
                timestamp: timestamp,
                isAnomaly: false
            )
            speedSamples.append(speedSample)

            timestamps.append(timestamp)
        }

        return Telemetry(
            gpsPoints: gpsPoints,
            speedSamples: speedSamples,
            timestamps: timestamps
        )
    }
}

/*
 INTEGRATION INSTRUCTIONS FOR GPMF PARSER:
 ==========================================

 To integrate the actual GoPro GPMF parser library:

 1. Add the GPMF parser as a dependency:
    - Option A: Git submodule
      git submodule add https://github.com/gopro/gpmf-parser.git External/gpmf-parser

    - Option B: Swift Package Manager (if available)
      Add to Package.swift dependencies

 2. Create a bridging header (GPMFBridge.h):
    #import "GPMF_parser.h"
    #import "GPMF_mp4reader.h"

 3. Configure Xcode:
    - Add bridging header to Build Settings
    - Add GPMF source files to project
    - Configure header search paths

 4. Implement the actual parser:

    func extractTelemetryActual(from videoURL: URL) async throws -> Telemetry {
        return try await withCheckedThrowingContinuation { continuation in
            videoURL.withUnsafeFileSystemRepresentation { cPath in
                guard let path = cPath else {
                    continuation.resume(throwing: GPMFError.invalidPath)
                    return
                }

                // Open MP4 file
                var mp4 = OpenMP4Source(path, Int32(GPMF_VERBOSE))
                guard mp4 != 0 else {
                    continuation.resume(throwing: GPMFError.openFailed)
                    return
                }

                defer { CloseSource(mp4) }

                // Get GPMF payload count
                let payloadCount = GetNumberPayloads(mp4)

                var gpsPoints: [Telemetry.GPSPoint] = []
                var speedSamples: [Telemetry.SpeedSample] = []

                // Iterate through payloads
                for index in 0..<payloadCount {
                    var payloadSize: UInt32 = 0
                    let payload = GetPayload(mp4, index, &payloadSize)

                    guard payload != nil else { continue }

                    // Parse GPMF structure
                    var ms = GPMF_stream()
                    let ret = GPMF_Init(&ms, payload, payloadSize)

                    guard ret == GPMF_OK else { continue }

                    // Extract GPS5 stream (GPS data + speed)
                    if GPMF_FindNext(&ms, GPMF_KEY_GPS5, GPMF_RECURSE_LEVELS) == GPMF_OK {
                        let samples = GPMF_PayloadSampleCount(&ms)

                        for i in 0..<samples {
                            var gpsData = [Double](repeating: 0, count: 5)
                            GPMF_ScaledData(&ms, &gpsData, 5, i, samples, GPMF_TYPE_DOUBLE)

                            let point = Telemetry.GPSPoint(
                                latitude: gpsData[0],
                                longitude: gpsData[1],
                                altitude: gpsData[2],
                                timestamp: Double(index),
                                accuracy: nil
                            )

                            let speed = Telemetry.SpeedSample(
                                speed: gpsData[3],  // Speed in m/s
                                timestamp: Double(index),
                                isAnomaly: false
                            )

                            gpsPoints.append(point)
                            speedSamples.append(speed)
                        }
                    }
                }

                let telemetry = Telemetry(
                    gpsPoints: gpsPoints,
                    speedSamples: speedSamples,
                    timestamps: gpsPoints.map { $0.timestamp }
                )

                continuation.resume(returning: telemetry)
            }
        }
    }

 5. Extract HLMT (highlight) markers:
    - HLMT data is in the 'udta' user data atom
    - Use GPMF_FindNext with GPMF_KEY_HLMT
    - Parse highlight type (MANL, AIMU, FUSE) and timestamp

 References:
 - https://github.com/gopro/gpmf-parser
 - https://gopro.github.io/gpmf-parser/
 */

// MARK: - Errors
enum GPMFError: LocalizedError {
    case invalidPath
    case openFailed
    case parseFailed
    case noMetadata

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "Invalid video file path"
        case .openFailed:
            return "Failed to open video file"
        case .parseFailed:
            return "Failed to parse GPMF metadata"
        case .noMetadata:
            return "No GPMF metadata found in video"
        }
    }
}
