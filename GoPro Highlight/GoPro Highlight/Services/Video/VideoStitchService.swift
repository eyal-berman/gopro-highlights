//
//  VideoStitchService.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import Foundation
@preconcurrency import AVFoundation
import CoreMedia

/// Service for stitching multiple video segments into a single video
actor VideoStitchService {
    private var currentExportSession: AVAssetExportSession?

    struct SegmentFile {
        let url: URL
        let originalVideoName: String
        let durationSeconds: TimeInterval
        let sourceCaptureDate: Date?
        let segmentStartTime: TimeInterval
        let kind: SegmentKind
    }

    enum SegmentKind {
        case highlight
        case maxSpeed
    }

    /// Stitches multiple video files into a single output file
    func stitchSegments(
        _ segmentFiles: [SegmentFile],
        outputURL: URL,
        quality: ExportSettings.OutputSettings.ExportQuality,
        addTransitions: Bool = false,
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async throws {
        guard !segmentFiles.isEmpty else {
            throw StitchError.noSegments
        }

        // Create composition
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw StitchError.trackCreationFailed
        }
        var compositionAudioTrack: AVMutableCompositionTrack?
        var insertTime = CMTime.zero

        // Process each segment
        for (index, segmentFile) in segmentFiles.enumerated() {
            let asset = AVAsset(url: segmentFile.url)

            // Verify asset is readable
            guard try await asset.load(.isReadable) else {
                throw StitchError.segmentNotReadable(segmentFile.url.lastPathComponent)
            }

            // Get duration
            let duration = try await asset.load(.duration)

            // Add video track
            if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
                let timeRange = CMTimeRange(start: .zero, duration: duration)

                try compositionVideoTrack.insertTimeRange(
                    timeRange,
                    of: videoTrack,
                    at: insertTime
                )

                // Preserve video properties
                if insertTime == .zero, let transform = try? await videoTrack.load(.preferredTransform) {
                    compositionVideoTrack.preferredTransform = transform
                }
            } else {
                throw StitchError.segmentNotReadable(segmentFile.url.lastPathComponent)
            }

            // Add audio track
            if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                if compositionAudioTrack == nil {
                    compositionAudioTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }

                guard let compositionAudioTrack else {
                    throw StitchError.trackCreationFailed
                }

                let timeRange = CMTimeRange(start: .zero, duration: duration)

                try compositionAudioTrack.insertTimeRange(
                    timeRange,
                    of: audioTrack,
                    at: insertTime
                )
            }

            // Update insert time for next segment
            insertTime = CMTimeAdd(insertTime, duration)

            // Report progress for composition phase
            let compositionProgress = Double(index + 1) / Double(segmentFiles.count) * 0.3
            onProgress(compositionProgress)
        }

        // Add transitions if requested
        if addTransitions {
            try await addCrossfadeTransitions(to: composition, segmentCount: segmentFiles.count)
        }

        // Export the stitched composition
        try await exportComposition(
            composition,
            to: outputURL,
            quality: quality,
            progressOffset: 0.3,
            onProgress: onProgress
        )
    }

    /// Adds crossfade transitions between segments
    private func addCrossfadeTransitions(
        to composition: AVMutableComposition,
        segmentCount: Int,
        transitionDuration: CMTime = CMTime(seconds: 0.5, preferredTimescale: 600)
    ) async throws {
        // Create video composition for transitions
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30) // 30 fps

        // Get video track
        guard let videoTrack = composition.tracks(withMediaType: .video).first else {
            return
        }

        let trackSize = try await videoTrack.load(.naturalSize)
        videoComposition.renderSize = trackSize

        // Add crossfade instructions between segments
        // This is a simplified version - full implementation would require
        // more complex composition instructions

        // TODO: Implement crossfade transitions using AVVideoCompositionLayerInstruction
        // This requires calculating transition points and creating opacity ramps
    }

    /// Exports the stitched composition
    private func exportComposition(
        _ composition: AVMutableComposition,
        to outputURL: URL,
        quality: ExportSettings.OutputSettings.ExportQuality,
        progressOffset: Double = 0.0,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        // Remove existing file if present
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // Passthrough does not reliably handle composed timelines.
        let presetName = quality == .original ? AVAssetExportPresetHighestQuality : quality.avPreset

        // Create export session
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: presetName
        ) else {
            throw StitchError.exportSessionCreationFailed
        }
        currentExportSession = exportSession

        exportSession.outputURL = outputURL
        let preferredFileType = preferredOutputFileType(for: outputURL)
        if exportSession.supportedFileTypes.contains(preferredFileType) {
            exportSession.outputFileType = preferredFileType
        } else if let fallbackFileType = exportSession.supportedFileTypes.first {
            exportSession.outputFileType = fallbackFileType
        } else {
            throw StitchError.exportFailed("No supported output file type")
        }
        exportSession.shouldOptimizeForNetworkUse = true

        // Monitor progress with Task
        let progressTask = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                let exportProgress = await currentExportProgress() * 0.7 // 70% of total progress
                onProgress(progressOffset + exportProgress)
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
            throw StitchError.exportFailed(error.localizedDescription)
        }

        guard exportSession.status == .completed else {
            throw StitchError.exportFailed("Export did not complete successfully")
        }

        onProgress(1.0) // Complete
    }

    private func runCurrentExport() async {
        await currentExportSession?.export()
    }

    private func cancelCurrentExport() {
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

    /// Generates filename for stitched video
    func generateStitchedFilename(
        baseVideoName: String,
        segmentCount: Int,
        totalDurationSeconds: TimeInterval,
        format: ExportSettings.OutputSettings.VideoFormat
    ) -> String {
        let baseName = (baseVideoName as NSString).deletingPathExtension

        let totalDuration = max(0, Int(totalDurationSeconds.rounded()))
        let minutes = totalDuration / 60
        let seconds = totalDuration % 60
        let durationLabel = String(format: "%02dm%02ds", minutes, seconds)

        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        let timestamp = formatter.string(from: Date())
        return "\(baseName)_Stitched_\(durationLabel)_\(segmentCount)clips_\(timestamp).\(format.fileExtension)"
    }
}

// MARK: - Errors
enum StitchError: LocalizedError {
    case noSegments
    case segmentNotReadable(String)
    case trackCreationFailed
    case exportSessionCreationFailed
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSegments:
            return "No video segments provided for stitching"
        case .segmentNotReadable(let filename):
            return "Segment '\(filename)' could not be read"
        case .trackCreationFailed:
            return "Failed to create composition track"
        case .exportSessionCreationFailed:
            return "Failed to create export session"
        case .exportFailed(let message):
            return "Stitching failed: \(message)"
        }
    }
}
