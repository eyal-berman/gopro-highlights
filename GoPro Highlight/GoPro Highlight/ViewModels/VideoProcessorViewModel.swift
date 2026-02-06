//
//  VideoProcessorViewModel.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import Foundation
import Observation
import SwiftUI
import AVFoundation

/// Main ViewModel that orchestrates video processing workflow
@MainActor
@Observable
class VideoProcessorViewModel {
    // MARK: - Published State
    var videos: [GoProVideo] = []
    var selectedFolderURL: URL?
    var progress = ProcessingProgress()
    var settings = ExportSettings()
    var isProcessing: Bool = false
    var showError: Bool = false
    var errorMessage: String = ""

    // MARK: - Services
    private let gpmfParser = GPMFParserService()
    private let speedAnalyzer = SpeedAnalysisService()
    private let csvExporter = CSVExportService()
    private let videoSegmenter = VideoSegmentService()
    private let videoStitcher = VideoStitchService()
    private let overlayRenderer = OverlayRenderService()
    private let pisteIdentifier = PisteIdentificationService()

    // MARK: - Computed Properties
    var hasVideos: Bool {
        !videos.isEmpty
    }

    var canProcess: Bool {
        hasVideos && !isProcessing
    }

    // MARK: - Folder Selection
    func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing GoPro videos"
        panel.prompt = "Select"

        panel.begin { [weak self] response in
            guard let self = self else { return }

            if response == .OK, let url = panel.url {
                Task { @MainActor in
                    self.selectedFolderURL = url
                    await self.loadVideos(from: url)
                }
            }
        }
    }

    // MARK: - Load Videos
    func loadVideos(from folderURL: URL) async {
        progress.addLog("Loading videos from: \(folderURL.lastPathComponent)")

        do {
            let fileManager = FileManager.default
            let contents = try fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            // Filter for video files
            let videoExtensions = ["mp4", "MP4", "mov", "MOV"]
            let videoFiles = contents.filter { url in
                videoExtensions.contains(url.pathExtension)
            }

            progress.addLog("Found \(videoFiles.count) video file(s)")

            // Create GoProVideo objects with duration
            var loadedVideos: [GoProVideo] = []
            for videoURL in videoFiles {
                let video = GoProVideo(url: videoURL)
                // Note: File size and duration will be calculated when needed
                // to keep the initializer simple
                loadedVideos.append(video)
            }

            self.videos = loadedVideos
            progress.addLog("Loaded \(loadedVideos.count) videos successfully", level: .success)

        } catch {
            self.errorMessage = "Failed to load videos: \(error.localizedDescription)"
            self.showError = true
            progress.addLog(errorMessage, level: .error)
        }
    }

    // MARK: - Start Processing
    func startProcessing() async {
        guard canProcess else { return }

        isProcessing = true
        progress.reset()
        progress.isProcessing = true
        progress.totalFiles = videos.count
        progress.addLog("Starting video processing...", level: .info)

        do {
            // Phase 1: Parse GPMF metadata
            progress.updateProgress(phase: .parsing, progress: 0.0)
            progress.addLog("Phase 1: Parsing GPMF metadata from videos...")

            for index in videos.indices {
                var video = videos[index]
                progress.currentFile = video.filename
                video.processingStatus = .parsing

                // Load video duration and file size
                do {
                    let asset = AVAsset(url: video.url)
                    let dur = try await asset.load(.duration)
                    video.duration = CMTimeGetSeconds(dur)
                    let attrs = try FileManager.default.attributesOfItem(atPath: video.url.path)
                    video.fileSize = (attrs[.size] as? Int64) ?? 0
                } catch {
                    progress.addLog("  → \(video.filename): Could not load duration", level: .warning)
                }

                // Extract telemetry (GPS/speed) — independent from highlights
                do {
                    let telemetry = try await gpmfParser.extractTelemetry(from: video.url)
                    video.telemetry = telemetry
                    progress.addLog("  ✓ \(video.filename): GPS telemetry (\(telemetry.speedSamples.count) samples)", level: .success)
                } catch {
                    progress.addLog("  → \(video.filename): No GPS telemetry (\(error.localizedDescription))", level: .warning)
                }

                // Extract highlights — independent from telemetry
                do {
                    let highlights = try await gpmfParser.findHighlights(in: video.url)
                    video.highlights = highlights
                    if !highlights.isEmpty {
                        progress.addLog("  ✓ \(video.filename): Found \(highlights.count) highlight(s)", level: .success)
                    } else {
                        progress.addLog("  → \(video.filename): No highlights marked", level: .info)
                    }
                } catch {
                    progress.addLog("  → \(video.filename): Could not read highlights", level: .warning)
                }

                videos[index] = video

                let phaseProgress = Double(index + 1) / Double(videos.count) * 0.15
                progress.updateProgress(phase: .parsing, progress: phaseProgress)
            }

            // Phase 2: Analyze speed data
            progress.updateProgress(phase: .analyzing, progress: 0.15)
            progress.addLog("Phase 2: Analyzing speed data...")

            for index in videos.indices {
                var video = videos[index]
                if let telemetry = video.telemetry, video.duration > 0 {
                    video.processingStatus = .analyzing

                    let stats = await speedAnalyzer.analyzeSpeed(
                        telemetry: telemetry,
                        videoDuration: video.duration
                    )
                    video.speedStats = stats

                    progress.addLog("  ✓ \(video.filename): Max speed \(String(format: "%.1f", stats.maxSpeed)) km/h, avg \(String(format: "%.1f", stats.avgSpeed)) km/h", level: .success)

                    videos[index] = video
                }

                let phaseProgress = 0.15 + Double(index + 1) / Double(videos.count) * 0.10
                progress.updateProgress(phase: .analyzing, progress: phaseProgress)
            }

            // Phase 3: Identify ski pistes
            if true { // Can be made configurable
                progress.updateProgress(phase: .identifyingPistes, progress: 0.25)
                progress.addLog("Phase 3: Identifying ski pistes...")

                for index in videos.indices {
                    var video = videos[index]
                    if let telemetry = video.telemetry {
                        do {
                            if let pisteInfo = try await pisteIdentifier.identifyPiste(from: telemetry) {
                                video.pisteInfo = PisteInfoData(
                                    name: pisteInfo.name,
                                    difficulty: pisteInfo.difficulty,
                                    resort: pisteInfo.resort,
                                    confidence: pisteInfo.confidence
                                )
                                videos[index] = video
                                progress.addLog("  ✓ \(video.filename): \(pisteInfo.name) (confidence: \(Int(pisteInfo.confidence * 100))%)", level: .success)
                            } else {
                                progress.addLog("  → \(video.filename): No piste identified", level: .info)
                            }
                        } catch {
                            progress.addLog("  ✗ \(video.filename): Piste identification failed (\(error.localizedDescription))", level: .warning)
                        }
                    }

                    let phaseProgress = 0.25 + Double(index + 1) / Double(videos.count) * 0.10
                    progress.updateProgress(phase: .identifyingPistes, progress: phaseProgress)
                }
            }

            // Phase 4: Extract video segments
            progress.updateProgress(phase: .extracting, progress: 0.35)
            progress.addLog("Phase 4: Extracting video segments...")

            let outputDir = settings.outputSettings.outputDirectory ?? selectedFolderURL?.appendingPathComponent("GoPro_Output")
            guard let outputDirectory = outputDir else {
                throw ProcessingError.noOutputDirectory
            }

            // Create output directory
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

            var allSegmentFiles: [VideoStitchService.SegmentFile] = []

            for (videoIndex, video) in videos.enumerated() {
                progress.currentFile = video.filename

                // Extract highlight segments
                if !video.highlights.isEmpty && settings.highlightSettings.beforeSeconds >= 0 {
                    let durationSeconds = video.duration

                    let segments = await videoSegmenter.calculateHighlightSegments(
                        highlights: video.highlights,
                        beforeSeconds: settings.highlightSettings.beforeSeconds,
                        afterSeconds: settings.highlightSettings.afterSeconds,
                        videoDuration: durationSeconds,
                        mergeOverlapping: settings.highlightSettings.mergeOverlapping
                    )

                    progress.addLog("  → \(video.filename): Extracting \(segments.count) highlight segment(s)...")

                    for (segIndex, segment) in segments.enumerated() {
                        let outputFilename = await videoSegmenter.generateOutputFilename(
                            originalFilename: video.filename,
                            segmentIndex: segIndex,
                            segmentType: segment.type,
                            format: settings.outputSettings.format
                        )

                        let segmentOutputURL = outputDirectory.appendingPathComponent(outputFilename)

                        do {
                            try await videoSegmenter.extractSegment(
                                from: video.url,
                                segment: segment,
                                outputURL: segmentOutputURL,
                                quality: settings.outputSettings.quality,
                                onProgress: { prog in
                                    // Update progress
                                }
                            )

                            progress.addLog("    ✓ Created: \(outputFilename)", level: .success)

                            allSegmentFiles.append(VideoStitchService.SegmentFile(
                                url: segmentOutputURL,
                                originalVideoName: video.filename
                            ))

                        } catch {
                            progress.addLog("    ✗ Failed: \(error.localizedDescription)", level: .error)
                        }
                    }
                }

                // Extract max speed segments
                if settings.maxSpeedSettings.enabled,
                   let stats = video.speedStats,
                   stats.maxSpeed > 0 {

                    let durationSeconds = video.duration

                    let segment = await videoSegmenter.calculateMaxSpeedSegment(
                        maxSpeedTime: stats.maxSpeedTime,
                        beforeSeconds: settings.maxSpeedSettings.beforeSeconds,
                        afterSeconds: settings.maxSpeedSettings.afterSeconds,
                        videoDuration: durationSeconds
                    )

                    let outputFilename = await videoSegmenter.generateOutputFilename(
                        originalFilename: video.filename,
                        segmentIndex: 0,
                        segmentType: .maxSpeed,
                        maxSpeed: stats.maxSpeed,
                        format: settings.outputSettings.format
                    )

                    let segmentOutputURL = outputDirectory.appendingPathComponent(outputFilename)

                    do {
                        try await videoSegmenter.extractSegment(
                            from: video.url,
                            segment: segment,
                            outputURL: segmentOutputURL,
                            quality: settings.outputSettings.quality
                        )

                        progress.addLog("  ✓ Max speed segment: \(outputFilename)", level: .success)

                        // Apply overlays if needed
                        if settings.maxSpeedSettings.includeOverlay &&
                           (settings.overlaySettings.speedGaugeEnabled || settings.overlaySettings.dateTimeEnabled) {
                            try await applyOverlays(
                                inputURL: segmentOutputURL,
                                video: video,
                                outputDir: outputDirectory
                            )
                        }

                    } catch {
                        progress.addLog("  ✗ Max speed extraction failed: \(error.localizedDescription)", level: .error)
                    }
                }

                let phaseProgress = 0.35 + Double(videoIndex + 1) / Double(videos.count) * 0.40
                progress.updateProgress(phase: .extracting, progress: phaseProgress)
            }

            // Phase 5: Stitch videos if requested
            if settings.outputSettings.outputMode != .individual && !allSegmentFiles.isEmpty {
                progress.updateProgress(phase: .stitching, progress: 0.75)
                progress.addLog("Phase 5: Stitching segments together...")

                let stitchedFilename = await videoStitcher.generateStitchedFilename(
                    baseVideoName: "GoPro_Highlights",
                    segmentCount: allSegmentFiles.count,
                    format: settings.outputSettings.format
                )

                let stitchedURL = outputDirectory.appendingPathComponent(stitchedFilename)

                do {
                    try await videoStitcher.stitchSegments(
                        allSegmentFiles,
                        outputURL: stitchedURL,
                        quality: settings.outputSettings.quality,
                        addTransitions: false,
                        onProgress: { [self] prog in
                            let phaseProgress = 0.75 + prog * 0.15
                            self.progress.updateProgress(phase: .stitching, progress: phaseProgress)
                        }
                    )

                    progress.addLog("✓ Created stitched video: \(stitchedFilename)", level: .success)

                } catch {
                    progress.addLog("✗ Stitching failed: \(error.localizedDescription)", level: .error)
                }
            }

            // Phase 6: Generate CSV report
            progress.updateProgress(phase: .generatingCSV, progress: 0.90)
            progress.addLog("Phase 6: Generating CSV report...")

            do {
                let csvURL = try await csvExporter.generateReport(videos: videos, includePisteInfo: true)
                let finalCSVURL = outputDirectory.appendingPathComponent("GoPro_Analysis.csv")

                try FileManager.default.copyItem(at: csvURL, to: finalCSVURL)

                progress.addLog("✓ CSV report saved: GoPro_Analysis.csv", level: .success)

            } catch {
                progress.addLog("✗ CSV generation failed: \(error.localizedDescription)", level: .error)
            }

            // Complete
            progress.updateProgress(phase: .completed, progress: 1.0)
            progress.addLog("🎉 Processing completed successfully!", level: .success)
            progress.addLog("Output directory: \(outputDirectory.path)", level: .info)

            // Mark all videos as completed
            for index in videos.indices {
                var video = videos[index]
                video.processingStatus = .completed
                videos[index] = video
            }

        } catch {
            errorMessage = "Processing failed: \(error.localizedDescription)"
            showError = true
            progress.addLog("❌ Processing failed: \(error.localizedDescription)", level: .error)
        }

        isProcessing = false
        progress.filesCompleted = videos.count
    }

    // MARK: - Apply Overlays
    private func applyOverlays(
        inputURL: URL,
        video: GoProVideo,
        outputDir: URL
    ) async throws {
        progress.addLog("    → Applying overlays...")

        let overlayOutputURL = inputURL.deletingPathExtension()
            .appendingPathExtension("_overlay")
            .appendingPathExtension(settings.outputSettings.format.fileExtension)

        try await overlayRenderer.renderOverlays(
            inputURL: inputURL,
            outputURL: overlayOutputURL,
            telemetry: video.telemetry,
            overlaySettings: settings.overlaySettings,
            quality: settings.outputSettings.quality
        )

        // Replace original with overlay version
        try FileManager.default.removeItem(at: inputURL)
        try FileManager.default.moveItem(at: overlayOutputURL, to: inputURL)

        progress.addLog("    ✓ Overlays applied", level: .success)
    }

    // MARK: - Export CSV
    func exportCSV(to url: URL) async {
        progress.addLog("Exporting CSV to: \(url.lastPathComponent)")

        do {
            let csvURL = try await csvExporter.generateReport(videos: videos, includePisteInfo: true)
            try FileManager.default.copyItem(at: csvURL, to: url)

            progress.addLog("✓ CSV exported successfully", level: .success)

        } catch {
            errorMessage = "CSV export failed: \(error.localizedDescription)"
            showError = true
            progress.addLog("✗ CSV export failed: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Clear Videos
    func clearVideos() {
        videos.removeAll()
        selectedFolderURL = nil
        progress.reset()
        progress.addLog("Cleared all videos")
    }
}

// MARK: - Errors
enum ProcessingError: LocalizedError {
    case noOutputDirectory

    var errorDescription: String? {
        switch self {
        case .noOutputDirectory:
            return "No output directory specified"
        }
    }
}
