//
//  SpeedAnalysisService.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import Foundation

/// Analyzes speed data from video telemetry and detects anomalies
actor SpeedAnalysisService {

    /// Analyzes speed data and calculates statistics
    func analyzeSpeed(telemetry: Telemetry) async -> SpeedStatistics {
        let cleanedSamples = detectAnomalies(in: telemetry.speedSamples)

        guard !cleanedSamples.isEmpty else {
            return SpeedStatistics(
                maxSpeed: 0,
                maxSpeedTime: 0,
                avgSpeed: 0,
                filteredSamples: 0
            )
        }

        // Find max speed
        let maxSample = cleanedSamples.max(by: { $0.speed < $1.speed })!

        // Calculate average (excluding near-zero speeds to avoid stationary periods)
        let movingSamples = cleanedSamples.filter { $0.speedKmh > 5.0 }
        let avgSpeed = movingSamples.isEmpty ? 0 :
            movingSamples.map { $0.speedKmh }.reduce(0, +) / Double(movingSamples.count)

        return SpeedStatistics(
            maxSpeed: maxSample.speedKmh,
            maxSpeedTime: maxSample.timestamp,
            avgSpeed: avgSpeed,
            filteredSamples: telemetry.speedSamples.count - cleanedSamples.count
        )
    }

    /// Detects and filters out GPS anomalies
    private func detectAnomalies(in speedData: [Telemetry.SpeedSample]) -> [Telemetry.SpeedSample] {
        guard speedData.count > 2 else { return speedData }

        var cleaned: [Telemetry.SpeedSample] = []

        for i in 0..<speedData.count {
            var sample = speedData[i]

            // Filter 1: Impossible speed (>200 km/h for most action sports)
            if sample.speedKmh > 200 {
                var anomalySample = sample
                anomalySample.isAnomaly = true
                continue
            }

            // Filter 2: Negative speeds (GPS error)
            if sample.speed < 0 {
                var anomalySample = sample
                anomalySample.isAnomaly = true
                continue
            }

            // Filter 3: Sudden acceleration check
            if i > 0 {
                let prevSpeed = speedData[i - 1].speedKmh
                let timeDiff = sample.timestamp - speedData[i - 1].timestamp

                // Avoid division by zero
                if timeDiff > 0 {
                    let acceleration = abs(sample.speedKmh - prevSpeed) / timeDiff

                    // More than 50 km/h change per second is suspicious
                    if acceleration > 50 {
                        var anomalySample = sample
                        anomalySample.isAnomaly = true
                        continue
                    }
                }
            }

            cleaned.append(sample)
        }

        // Apply moving median filter for additional smoothing
        return applyMedianFilter(cleaned, windowSize: 5)
    }

    /// Applies a moving median filter to smooth out remaining noise
    private func applyMedianFilter(_ samples: [Telemetry.SpeedSample], windowSize: Int) -> [Telemetry.SpeedSample] {
        guard samples.count > windowSize else { return samples }

        var filtered: [Telemetry.SpeedSample] = []
        let halfWindow = windowSize / 2

        for i in 0..<samples.count {
            let start = max(0, i - halfWindow)
            let end = min(samples.count - 1, i + halfWindow)
            let window = Array(samples[start...end])

            let sortedSpeeds = window.map { $0.speed }.sorted()
            let medianSpeed = sortedSpeeds[sortedSpeeds.count / 2]

            var sample = samples[i]
            sample.speed = medianSpeed
            filtered.append(sample)
        }

        return filtered
    }

    /// Finds the top N videos with highest max speeds
    func selectTopSpeedVideos(from videos: [GoProVideo], count: Int) -> [GoProVideo] {
        return videos
            .filter { $0.speedStats != nil }
            .sorted { ($0.speedStats?.maxSpeed ?? 0) > ($1.speedStats?.maxSpeed ?? 0) }
            .prefix(count)
            .map { $0 }
    }
}
