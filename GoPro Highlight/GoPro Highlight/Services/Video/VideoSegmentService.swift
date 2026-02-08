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
    private var currentExportSession: AVAssetExportSession?

    enum SegmentEncodingMode: Sendable {
        case passthrough
        case reencoded
    }

    struct SegmentExportResult: Sendable {
        let mode: SegmentEncodingMode
        let fallbackReason: String?
    }

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
        preferPassthrough: Bool = false,
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async throws -> SegmentExportResult {
        let asset = AVAsset(url: videoURL)

        // Verify asset is readable
        guard try await asset.load(.isReadable) else {
            throw VideoError.assetNotReadable
        }

        let timeRange = CMTimeRange(
            start: CMTime(seconds: segment.startTime, preferredTimescale: 600),
            duration: CMTime(seconds: segment.duration, preferredTimescale: 600)
        )

        if preferPassthrough {
            do {
                try await exportAsset(
                    asset,
                    to: outputURL,
                    presetName: AVAssetExportPresetPassthrough,
                    timeRange: timeRange,
                    onProgress: onProgress
                )
                return SegmentExportResult(mode: .passthrough, fallbackReason: nil)
            } catch {
                if error is CancellationError {
                    throw error
                }

                let fallbackReason = "Passthrough unavailable (\(error.localizedDescription)); re-encoding with selected quality."
                try await exportSegmentViaComposition(
                    asset: asset,
                    timeRange: timeRange,
                    outputURL: outputURL,
                    quality: quality,
                    onProgress: onProgress
                )
                return SegmentExportResult(mode: .reencoded, fallbackReason: fallbackReason)
            }
        }

        try await exportSegmentViaComposition(
            asset: asset,
            timeRange: timeRange,
            outputURL: outputURL,
            quality: quality,
            onProgress: onProgress
        )
        return SegmentExportResult(mode: .reencoded, fallbackReason: nil)
    }

    private func exportSegmentViaComposition(
        asset: AVAsset,
        timeRange: CMTimeRange,
        outputURL: URL,
        quality: ExportSettings.OutputSettings.ExportQuality,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let composition = AVMutableComposition()

        if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
            guard let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw VideoError.trackCreationFailed
            }

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

            try compositionAudioTrack.insertTimeRange(
                timeRange,
                of: audioTrack,
                at: .zero
            )
        }

        let presetName = quality == .original ? AVAssetExportPresetHighestQuality : quality.avPreset
        try await exportAsset(
            composition,
            to: outputURL,
            presetName: presetName,
            timeRange: nil,
            onProgress: onProgress
        )
    }

    /// Exports an asset to file
    private func exportAsset(
        _ asset: AVAsset,
        to outputURL: URL,
        presetName: String,
        timeRange: CMTimeRange?,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        // Remove existing file if it exists
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // Create export session
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: presetName
        ) else {
            throw VideoError.exportSessionCreationFailed
        }
        currentExportSession = exportSession

        if let timeRange {
            exportSession.timeRange = timeRange
        }

        exportSession.outputURL = outputURL
        let preferredFileType = preferredOutputFileType(for: outputURL)
        if exportSession.supportedFileTypes.contains(preferredFileType) {
            exportSession.outputFileType = preferredFileType
        } else if let fallbackFileType = exportSession.supportedFileTypes.first {
            exportSession.outputFileType = fallbackFileType
        } else {
            throw VideoError.exportFailed("No supported output file type")
        }
        exportSession.shouldOptimizeForNetworkUse = true

        // Monitor progress with Task
        let progressTask = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                let progress = currentExportProgress()
                onProgress(progress)
            }
        }

        // Export
        await withTaskCancellationHandler(
            operation: {
                await runCurrentExport()
            },
            onCancel: {
                Task { [self] in
                    await cancelCurrentExport()
                }
            }
        )

        progressTask.cancel()
        currentExportSession = nil

        // Check for errors
        if let error = exportSession.error {
            throw VideoError.exportFailed(error.localizedDescription)
        }

        guard exportSession.status == .completed else {
            throw VideoError.exportFailed("Export did not complete successfully")
        }
    }

    private func runCurrentExport() async {
        await currentExportSession?.export()
    }

    private func cancelCurrentExport() async {
        currentExportSession?.cancelExport()
    }

    private func currentExportProgress() -> Double {
        Double(currentExportSession?.progress ?? 0)
    }

    private func preferredOutputFileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mov":
            return .mov
        default:
            return .mp4
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
