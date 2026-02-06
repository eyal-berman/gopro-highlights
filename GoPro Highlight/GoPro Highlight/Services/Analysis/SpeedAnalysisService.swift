//
//  SpeedAnalysisService.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import Foundation

/// Analyzes speed data from video telemetry using per-second averaging and peak validation
actor SpeedAnalysisService {

    struct PerSecondSpeed {
        let second: Int
        let speedKmh: Double
    }

    /// Analyzes speed data: averages per second, finds max, validates peak
    func analyzeSpeed(telemetry: Telemetry, videoDuration: TimeInterval) async -> SpeedStatistics {
        let speedSamples = telemetry.speedSamples
        guard !speedSamples.isEmpty, videoDuration > 0 else {
            return SpeedStatistics(maxSpeed: 0, maxSpeedTime: 0, avgSpeed: 0, filteredSamples: 0)
        }

        // Step 1: Distribute speeds per-second and average (matches Python approach)
        let perSecondSpeeds = calculatePerSecondSpeeds(
            samples: speedSamples,
            duration: videoDuration
        )

        guard !perSecondSpeeds.isEmpty else {
            return SpeedStatistics(maxSpeed: 0, maxSpeedTime: 0, avgSpeed: 0, filteredSamples: 0)
        }

        // Step 2: Find max speed
        let maxEntry = perSecondSpeeds.max(by: { $0.speedKmh < $1.speedKmh })!
        var maxSpeed = maxEntry.speedKmh
        var maxSpeedTime = Double(maxEntry.second)

        // Step 3: Validate the peak (matches Python validate_speed_peak)
        let (isValid, _) = validateSpeedPeak(
            peakSpeed: maxSpeed,
            peakTimestamp: maxSpeedTime,
            perSecondSpeeds: perSecondSpeeds
        )

        if !isValid {
            // Find next highest valid speed
            let sorted = perSecondSpeeds.sorted(by: { $0.speedKmh > $1.speedKmh })
            for entry in sorted where entry.speedKmh < maxSpeed {
                let (valid, _) = validateSpeedPeak(
                    peakSpeed: entry.speedKmh,
                    peakTimestamp: Double(entry.second),
                    perSecondSpeeds: perSecondSpeeds
                )
                if valid {
                    maxSpeed = entry.speedKmh
                    maxSpeedTime = Double(entry.second)
                    break
                }
            }
        }

        // Step 4: Calculate average (excluding near-zero to ignore stationary periods)
        let movingSpeeds = perSecondSpeeds.filter { $0.speedKmh > 5.0 }
        let avgSpeed = movingSpeeds.isEmpty ? 0 :
            movingSpeeds.map(\.speedKmh).reduce(0, +) / Double(movingSpeeds.count)

        return SpeedStatistics(
            maxSpeed: maxSpeed,
            maxSpeedTime: maxSpeedTime,
            avgSpeed: avgSpeed,
            filteredSamples: 0
        )
    }

    /// Groups speed samples by second and averages within each second
    private func calculatePerSecondSpeeds(
        samples: [Telemetry.SpeedSample],
        duration: TimeInterval
    ) -> [PerSecondSpeed] {
        var perSecond: [[Double]] = Array(repeating: [], count: Int(duration) + 1)

        let totalSamples = samples.count
        for (idx, sample) in samples.enumerated() {
            let t = totalSamples > 1
                ? (Double(idx) / Double(totalSamples - 1)) * duration
                : 0
            let sec = Int(t)
            if sec < perSecond.count {
                perSecond[sec].append(sample.speedKmh)
            }
        }

        var result: [PerSecondSpeed] = []
        for (sec, values) in perSecond.enumerated() {
            if !values.isEmpty {
                let avg = values.reduce(0, +) / Double(values.count)
                result.append(PerSecondSpeed(second: sec, speedKmh: avg))
            }
        }

        return result
    }

    // MARK: - Speed Peak Validation (port of Python validate_speed_peak)

    private func validateSpeedPeak(
        peakSpeed: Double,
        peakTimestamp: Double,
        perSecondSpeeds: [PerSecondSpeed],
        maxAcceleration: Double = 50.0,
        minSupportingSamples: Int = 3,
        supportThreshold: Double = 0.8,
        windowSeconds: Int = 5
    ) -> (isValid: Bool, confidence: Double) {
        guard !perSecondSpeeds.isEmpty else { return (false, 0.0) }

        let windowStart = max(0, Int(peakTimestamp) - windowSeconds)
        let windowEnd = Int(peakTimestamp) + windowSeconds

        let windowSamples = perSecondSpeeds.filter {
            $0.second >= windowStart && $0.second <= windowEnd
        }

        guard windowSamples.count >= 2 else { return (false, 0.0) }

        // Find peak index in window
        let peakIdx = windowSamples.enumerated().min(by: {
            abs($0.element.second - Int(peakTimestamp)) < abs($1.element.second - Int(peakTimestamp))
        })?.offset ?? 0

        // Check acceleration before peak
        if peakIdx > 0 {
            let prevSpeed = windowSamples[peakIdx - 1].speedKmh
            let timeDiff = Double(windowSamples[peakIdx].second - windowSamples[peakIdx - 1].second)
            if timeDiff > 0 {
                let acceleration = (peakSpeed - prevSpeed) / timeDiff
                if acceleration > maxAcceleration {
                    return (false, 0.2)
                }
            }
        }

        // Check supporting samples
        let supportSpeedThreshold = peakSpeed * supportThreshold
        let supportingSamples = windowSamples.filter { $0.speedKmh >= supportSpeedThreshold }

        if supportingSamples.count < minSupportingSamples {
            return (false, 0.3)
        }

        // Calculate confidence
        var confidence = 0.5

        let supportRatio = Double(supportingSamples.count) / Double(max(1, windowSamples.count))
        confidence += supportRatio * 0.3

        let beforePeak = windowSamples.filter { $0.second < Int(peakTimestamp) }
        let afterPeak = windowSamples.filter { $0.second > Int(peakTimestamp) }

        if !beforePeak.isEmpty && !afterPeak.isEmpty {
            if beforePeak.count >= 2 {
                let beforeTrend = (beforePeak.last!.speedKmh - beforePeak.first!.speedKmh) / Double(max(1, beforePeak.count - 1))
                if beforeTrend > 0 { confidence += 0.1 }
            }
            if afterPeak.count >= 2 {
                let afterTrend = (afterPeak.last!.speedKmh - afterPeak.first!.speedKmh) / Double(max(1, afterPeak.count - 1))
                if afterTrend < 0 { confidence += 0.1 }
            }
        }

        confidence = min(1.0, confidence)
        return (confidence >= 0.6, confidence)
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
