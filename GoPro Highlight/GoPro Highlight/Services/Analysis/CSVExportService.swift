//
//  CSVExportService.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import Foundation

/// Generates CSV reports from processed video data
actor CSVExportService {

    /// Generates a comprehensive CSV report for all videos
    func generateReport(videos: [GoProVideo], includeP isteInfo: Bool = true) async throws -> URL {
        var csvContent = buildCSVHeader(includePisteInfo: includePisteInfo)

        for video in videos {
            let row = buildCSVRow(for: video, includePisteInfo: includePisteInfo)
            csvContent += row + "\n"
        }

        // Create temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "GoPro_Analysis_\(dateFormatter.string(from: Date())).csv"
        let fileURL = tempDir.appendingPathComponent(filename)

        try csvContent.write(to: fileURL, atomically: true, encoding: .utf8)

        return fileURL
    }

    /// Generates CSV header row
    private func buildCSVHeader(includePisteInfo: Bool) -> String {
        var headers = [
            "Filename",
            "Max Speed (km/h)",
            "Max Speed Time",
            "Avg Speed (km/h)",
            "Highlights Count",
            "Duration (s)",
            "File Size (MB)"
        ]

        if includePisteInfo {
            headers.append("Ski Piste")
            headers.append("Resort")
        }

        return headers.joined(separator: ",") + "\n"
    }

    /// Generates CSV row for a single video
    private func buildCSVRow(for video: GoProVideo, includePisteInfo: Bool) -> String {
        var values: [String] = []

        // Filename
        values.append(escapeCSVField(video.filename))

        // Speed statistics
        if let stats = video.speedStats {
            values.append(String(format: "%.1f", stats.maxSpeed))
            values.append(formatTimestamp(stats.maxSpeedTime))
            values.append(String(format: "%.1f", stats.avgSpeed))
        } else {
            values.append("N/A")
            values.append("N/A")
            values.append("N/A")
        }

        // Highlights count
        values.append("\(video.highlights.count)")

        // Duration
        values.append(String(format: "%.1f", video.duration))

        // File size (convert to MB)
        let fileSizeMB = Double(video.fileSize) / (1024 * 1024)
        values.append(String(format: "%.1f", fileSizeMB))

        // Piste info (placeholder for Phase 7)
        if includePisteInfo {
            // TODO: Phase 7 - Add actual piste identification
            values.append("Unknown")
            values.append("Unknown")
        }

        return values.joined(separator: ",")
    }

    /// Escapes CSV field (handles commas, quotes, newlines)
    private func escapeCSVField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }

    /// Formats timestamp as HH:MM:SS
    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    /// Date formatter for filenames
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }
}
