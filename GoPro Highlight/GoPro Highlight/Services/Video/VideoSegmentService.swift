//
//  VideoSegmentService.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import Foundation
import AVFoundation
import CoreMedia

/// Service for extracting video segments (highlights, max speed moments)
actor VideoSegmentService {

    // MARK: - Video Segment Model
    struct VideoSegment {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let highlightTime: TimeInterval?
        let type: SegmentType

        var duration: TimeInterval { endTime - startTime }

        enum SegmentType {
            case highlight(Highlight.HighlightType)
            case maxSpeed
        }
    }

    // MARK: - Segment Calculation

    /// Calculates segments from highlights with configurable timing
    func calculateHighlightSegments(
        highlights: [Highlight],
        beforeSeconds: Double,
        afterSeconds: Double,
        videoDuration: TimeInterval,
        mergeOverlapping: Bool
    ) -> [VideoSegment] {
        var segments: [VideoSegment] = []

        for highlight in highlights.sorted(by: { $0.timestamp < $1.timestamp }) {
            let start = max(0, highlight.timestamp - beforeSeconds)
            let end = min(videoDuration, highlight.timestamp + afterSeconds)

            segments.append(VideoSegment(
                startTime: start,
                endTime: end,
                highlightTime: highlight.timestamp,
                type: .highlight(highlight.type)
            ))
        }

        if mergeOverlapping {
            segments = mergeSegments(segments)
        }

        return segments
    }

    /// Calculates segment for max speed moment
    func calculateMaxSpeedSegment(
        maxSpeedTime: TimeInterval,
        beforeSeconds: Double,
        afterSeconds: Double,
        videoDuration: TimeInterval
    ) -> VideoSegment {
        let start = max(0, maxSpeedTime - beforeSeconds)
        let end = min(videoDuration, maxSpeedTime + afterSeconds)

        return VideoSegment(
            startTime: start,
            endTime: end,
            highlightTime: maxSpeedTime,
            type: .maxSpeed
        )
    }

    /// Merges overlapping segments
    private func mergeSegments(_ segments: [VideoSegment]) -> [VideoSegment] {
        guard segments.count > 1 else { return segments }

        var merged: [VideoSegment] = []
        var current = segments[0]

        for i in 1..<segments.count {
            let next = segments[i]

            if current.endTime >= next.startTime {
                // Overlapping - merge
                current = VideoSegment(
                    startTime: current.startTime,
                    endTime: max(current.endTime, next.endTime),
                    highlightTime: current.highlightTime,
                    type: current.type
                )
            } else {
                merged.append(current)
                current = next
            }
        }

        merged.append(current)
        return merged
    }

    // MARK: - Video Extraction

    /// Extracts a video segment and exports to file
    func extractSegment(
        from videoURL: URL,
        segment: VideoSegment,
        outputURL: URL,
        quality: ExportSettings.OutputSettings.ExportQuality,
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async throws {
        let asset = AVAsset(url: videoURL)

        // Verify asset is readable
        guard try await asset.load(.isReadable) else {
            throw VideoError.assetNotReadable
        }

        // Create composition
        let composition = AVMutableComposition()

        // Add video track
        if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
            guard let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw VideoError.trackCreationFailed
            }

            let timeRange = CMTimeRange(
                start: CMTime(seconds: segment.startTime, preferredTimescale: 600),
                duration: CMTime(seconds: segment.duration, preferredTimescale: 600)
            )

            try compositionVideoTrack.insertTimeRange(
                timeRange,
                of: videoTrack,
                at: .zero
            )

            // Copy video track properties
            if let transform = try? await videoTrack.load(.preferredTransform) {
                compositionVideoTrack.preferredTransform = transform
            }
        }

        // Add audio track
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw VideoError.trackCreationFailed
            }

            let timeRange = CMTimeRange(
                start: CMTime(seconds: segment.startTime, preferredTimescale: 600),
                duration: CMTime(seconds: segment.duration, preferredTimescale: 600)
            )

            try compositionAudioTrack.insertTimeRange(
                timeRange,
                of: audioTrack,
                at: .zero
            )
        }

        // Export
        try await exportComposition(
            composition,
            to: outputURL,
            quality: quality,
            onProgress: onProgress
        )
    }

    /// Exports a composition to file
    private func exportComposition(
        _ composition: AVMutableComposition,
        to outputURL: URL,
        quality: ExportSettings.OutputSettings.ExportQuality,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        // Remove existing file if it exists
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // Create export session
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: quality.avPreset
        ) else {
            throw VideoError.exportSessionCreationFailed
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        // Monitor progress
        let progressTimer = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                onProgress(Double(exportSession.progress))
            }

        // Export
        await exportSession.export()

        progressTimer.cancel()

        // Check for errors
        if let error = exportSession.error {
            throw VideoError.exportFailed(error.localizedDescription)
        }

        guard exportSession.status == .completed else {
            throw VideoError.exportFailed("Export did not complete successfully")
        }
    }

    /// Generates output filename for a segment
    func generateOutputFilename(
        originalFilename: String,
        segmentIndex: Int,
        segmentType: VideoSegment.SegmentType,
        maxSpeed: Double? = nil,
        format: ExportSettings.OutputSettings.VideoFormat
    ) -> String {
        let baseName = (originalFilename as NSString).deletingPathExtension

        let suffix: String
        switch segmentType {
        case .highlight(let type):
            suffix = "Highlight_\(segmentIndex + 1)_\(type.rawValue)"
        case .maxSpeed:
            if let speed = maxSpeed {
                suffix = "MaxSpeed_\(String(format: "%.1f", speed))kmh"
            } else {
                suffix = "MaxSpeed"
            }
        }

        return "\(baseName)_\(suffix).\(format.fileExtension)"
    }
}

// MARK: - Errors
enum VideoError: LocalizedError {
    case assetNotReadable
    case noVideoTrack
    case noAudioTrack
    case trackCreationFailed
    case exportSessionCreationFailed
    case exportFailed(String)
    case invalidTimeRange

    var errorDescription: String? {
        switch self {
        case .assetNotReadable:
            return "Video file could not be read"
        case .noVideoTrack:
            return "No video track found"
        case .noAudioTrack:
            return "No audio track found"
        case .trackCreationFailed:
            return "Failed to create composition track"
        case .exportSessionCreationFailed:
            return "Failed to create export session"
        case .exportFailed(let message):
            return "Export failed: \(message)"
        case .invalidTimeRange:
            return "Invalid time range specified"
        }
    }
}
