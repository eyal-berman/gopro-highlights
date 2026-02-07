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
    private var processingTask: Task<Void, Never>?

    // MARK: - Computed Properties
    var hasVideos: Bool {
        !videos.isEmpty
    }

    var canProcess: Bool {
        hasVideos && !isProcessing
    }

    // MARK: - Processing Control
    func beginProcessing() {
        guard canProcess else { return }

        processingTask = Task { [weak self] in
            await self?.startProcessing()
        }
    }

    func stopProcessing() {
        guard isProcessing else { return }
        progress.addLog("Stopping processing...", level: .warning)
        processingTask?.cancel()
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
            let sortedVideoFiles = videoFiles.sorted { lhs, rhs in
                let lhsDate = fileSystemDate(for: lhs)
                let rhsDate = fileSystemDate(for: rhs)
                if let lhsDate, let rhsDate,
                   isPlausibleCaptureDate(lhsDate), isPlausibleCaptureDate(rhsDate) {
                    if lhsDate != rhsDate { return lhsDate < rhsDate }
                }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }

            progress.addLog("Found \(sortedVideoFiles.count) video file(s)")

            // Create GoProVideo objects with duration
            var loadedVideos: [GoProVideo] = []
            for videoURL in sortedVideoFiles {
                var video = GoProVideo(url: videoURL)
                video.captureDate = fileSystemDate(for: videoURL)
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
        progress.addLog("  → Output mode: \(settings.outputSettings.outputMode.rawValue)")
        progress.addLog("  → Quality: \(settings.outputSettings.quality.rawValue), Format: \(settings.outputSettings.format.rawValue)")
        progress.addLog("  → Overlays: speed=\(settings.overlaySettings.speedGaugeEnabled), datetime=\(settings.overlaySettings.dateTimeEnabled)")
        progress.addLog("  → Highlight overlay: \(settings.highlightSettings.includeOverlay), Max-speed overlay: \(settings.maxSpeedSettings.includeOverlay)")

        do {
            try Task.checkCancellation()

            // Phase 1: Parse GPMF metadata
            progress.updateProgress(phase: .parsing, progress: 0.0)
            progress.addLog("Phase 1: Parsing GPMF metadata from videos...")

            for index in videos.indices {
                try Task.checkCancellation()
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

                    if video.captureDate == nil {
                        video.captureDate = try await extractCaptureDate(from: asset)
                    }
                    progress.addLog(
                        "  → \(video.filename): duration \(String(format: "%.1f", max(0, video.duration)))s, size \(formatFileSize(video.fileSize))"
                    )
                    if let captureDate = video.captureDate, isPlausibleCaptureDate(captureDate) {
                        progress.addLog("  → \(video.filename): capture date \(captureDate.formatted(date: .abbreviated, time: .standard))")
                    }
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
                try Task.checkCancellation()
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
                } else {
                    progress.addLog("  → \(video.filename): Skipping speed analysis (no telemetry)", level: .info)
                }

                let phaseProgress = 0.15 + Double(index + 1) / Double(videos.count) * 0.10
                progress.updateProgress(phase: .analyzing, progress: phaseProgress)
            }

            // Phase 3: Identify ski pistes
            if true { // Can be made configurable
                progress.updateProgress(phase: .identifyingPistes, progress: 0.25)
                progress.addLog("Phase 3: Identifying ski pistes...")

                for index in videos.indices {
                    try Task.checkCancellation()
                    var video = videos[index]
                    if let telemetry = video.telemetry {
                        do {
                            progress.addLog("  → \(video.filename): Running piste detection on \(telemetry.gpsPoints.count) GPS points")
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
                    } else {
                        progress.addLog("  → \(video.filename): Skipping piste detection (no telemetry)", level: .info)
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
                try Task.checkCancellation()
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
                        try Task.checkCancellation()
                        progress.addLog(
                            "    → Segment \(segIndex + 1): \(String(format: "%.2f", segment.startTime))s - \(String(format: "%.2f", segment.endTime))s"
                        )
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

                            // Apply overlays to highlight segments if enabled.
                            if settings.highlightSettings.includeOverlay &&
                               (settings.overlaySettings.speedGaugeEnabled || settings.overlaySettings.dateTimeEnabled) {
                                try Task.checkCancellation()
                                do {
                                    try await applyOverlays(
                                        inputURL: segmentOutputURL,
                                        video: video,
                                        outputDir: outputDirectory
                                    )
                                } catch {
                                    progress.addLog("    ✗ Overlay failed: \(error.localizedDescription)", level: .warning)
                                }
                            }

                            allSegmentFiles.append(VideoStitchService.SegmentFile(
                                url: segmentOutputURL,
                                originalVideoName: video.filename,
                                durationSeconds: segment.duration,
                                sourceCaptureDate: video.captureDate,
                                segmentStartTime: segment.startTime,
                                kind: .highlight
                            ))

                        } catch {
                            progress.addLog("    ✗ Failed: \(error.localizedDescription)", level: .error)
                        }
                    }
                } else if video.highlights.isEmpty {
                    progress.addLog("  → \(video.filename): No highlight segments to extract", level: .info)
                }

                // Extract max speed segments
                if settings.maxSpeedSettings.enabled,
                   let stats = video.speedStats,
                   stats.maxSpeed > 0 {
                    try Task.checkCancellation()

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
                    progress.addLog(
                        "  → Max-speed segment range: \(String(format: "%.2f", segment.startTime))s - \(String(format: "%.2f", segment.endTime))s"
                    )

                    do {
                        try await videoSegmenter.extractSegment(
                            from: video.url,
                            segment: segment,
                            outputURL: segmentOutputURL,
                            quality: settings.outputSettings.quality
                        )

                        progress.addLog("  ✓ Max speed segment: \(outputFilename)", level: .success)

                        allSegmentFiles.append(VideoStitchService.SegmentFile(
                            url: segmentOutputURL,
                            originalVideoName: video.filename,
                            durationSeconds: segment.duration,
                            sourceCaptureDate: video.captureDate,
                            segmentStartTime: segment.startTime,
                            kind: .maxSpeed
                        ))

                        // Apply overlays if needed
                        if settings.maxSpeedSettings.includeOverlay &&
                           (settings.overlaySettings.speedGaugeEnabled || settings.overlaySettings.dateTimeEnabled) {
                            try Task.checkCancellation()
                            do {
                                try await applyOverlays(
                                    inputURL: segmentOutputURL,
                                    video: video,
                                    outputDir: outputDirectory
                                )
                            } catch {
                                progress.addLog("  ✗ Overlay failed: \(error.localizedDescription)", level: .warning)
                            }
                        }

                    } catch {
                        progress.addLog("  ✗ Max speed extraction failed: \(error.localizedDescription)", level: .error)
                    }
                } else if !settings.maxSpeedSettings.enabled {
                    progress.addLog("  → \(video.filename): Max-speed extraction disabled", level: .info)
                } else {
                    progress.addLog("  → \(video.filename): No valid max-speed telemetry segment", level: .info)
                }

                let phaseProgress = 0.35 + Double(videoIndex + 1) / Double(videos.count) * 0.40
                progress.updateProgress(phase: .extracting, progress: phaseProgress)
            }

            // Phase 5: Stitch videos if requested
            if settings.outputSettings.outputMode != .individual && !allSegmentFiles.isEmpty {
                try Task.checkCancellation()
                progress.updateProgress(phase: .stitching, progress: 0.75)
                progress.addLog("Phase 5: Stitching segments together...")
                let sortedSegmentFiles = sortSegmentsForStitching(allSegmentFiles)
                progress.addLog("  → Stitch order resolved for \(sortedSegmentFiles.count) segment(s)")
                for segment in sortedSegmentFiles.prefix(20) {
                    let sourceDateString = segment.sourceCaptureDate?.formatted(date: .abbreviated, time: .standard) ?? "n/a"
                    progress.addLog("    → \(segment.originalVideoName) @ \(String(format: "%.2f", segment.segmentStartTime))s (date: \(sourceDateString))")
                }
                if sortedSegmentFiles.count > 20 {
                    progress.addLog("    → ... \(sortedSegmentFiles.count - 20) more segment(s)")
                }

                let stitchedFilename = await videoStitcher.generateStitchedFilename(
                    baseVideoName: "GoPro_Highlights",
                    segmentCount: sortedSegmentFiles.count,
                    totalDurationSeconds: sortedSegmentFiles.reduce(0) { $0 + $1.durationSeconds },
                    format: settings.outputSettings.format
                )
                var stitchedURL = outputDirectory.appendingPathComponent(stitchedFilename)
                var suffix = 1
                while FileManager.default.fileExists(atPath: stitchedURL.path) {
                    let baseName = (stitchedFilename as NSString).deletingPathExtension
                    let ext = (stitchedFilename as NSString).pathExtension
                    stitchedURL = outputDirectory.appendingPathComponent("\(baseName)_\(suffix).\(ext)")
                    suffix += 1
                }

                do {
                    try await videoStitcher.stitchSegments(
                        sortedSegmentFiles,
                        outputURL: stitchedURL,
                        quality: settings.outputSettings.quality,
                        addTransitions: false,
                        onProgress: { [self] prog in
                            let phaseProgress = 0.75 + prog * 0.15
                            self.progress.updateProgress(phase: .stitching, progress: phaseProgress)
                        }
                    )

                    progress.addLog("✓ Created stitched video: \(stitchedURL.lastPathComponent)", level: .success)
                    if settings.outputSettings.outputMode == .stitched {
                        var deletedCount = 0
                        for segment in sortedSegmentFiles where segment.kind == .highlight {
                            if FileManager.default.fileExists(atPath: segment.url.path) {
                                do {
                                    try FileManager.default.removeItem(at: segment.url)
                                    deletedCount += 1
                                } catch {
                                    progress.addLog("  → Could not remove temporary segment \(segment.url.lastPathComponent)", level: .warning)
                                }
                            }
                        }
                        let keptCount = sortedSegmentFiles.filter { $0.kind == .maxSpeed }.count
                        progress.addLog("  ✓ Removed \(deletedCount) temporary highlight file(s) for stitched-only output")
                        if keptCount > 0 {
                            progress.addLog("  ✓ Kept \(keptCount) max-speed file(s)")
                        }
                    }

                } catch {
                    progress.addLog("✗ Stitching failed: \(error.localizedDescription)", level: .error)
                }
            }

            // Phase 6: Generate CSV report
            progress.updateProgress(phase: .generatingCSV, progress: 0.90)
            progress.addLog("Phase 6: Generating CSV report...")
            try Task.checkCancellation()

            do {
                let csvURL = try await csvExporter.generateReport(videos: videos, includePisteInfo: true)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd_HHmmss"
                let timestamp = formatter.string(from: Date())
                var finalCSVURL = outputDirectory.appendingPathComponent("GoPro_Analysis_\(timestamp).csv")
                var suffix = 1
                while FileManager.default.fileExists(atPath: finalCSVURL.path) {
                    finalCSVURL = outputDirectory.appendingPathComponent("GoPro_Analysis_\(timestamp)_\(suffix).csv")
                    suffix += 1
                }

                try FileManager.default.copyItem(at: csvURL, to: finalCSVURL)

                progress.addLog("✓ CSV report saved: \(finalCSVURL.lastPathComponent)", level: .success)

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

        } catch is CancellationError {
            progress.addLog("Processing stopped.", level: .warning)
            progress.updateProgress(phase: .idle, progress: progress.overallProgress)
            markCancelledVideos()
        } catch {
            errorMessage = "Processing failed: \(error.localizedDescription)"
            showError = true
            progress.addLog("❌ Processing failed: \(error.localizedDescription)", level: .error)
        }

        isProcessing = false
        progress.isProcessing = false
        progress.currentFile = ""
        processingTask = nil
        progress.filesCompleted = videos.filter { video in
            if case .completed = video.processingStatus {
                return true
            }
            return false
        }.count
    }

    // MARK: - Apply Overlays
    private func applyOverlays(
        inputURL: URL,
        video: GoProVideo,
        outputDir: URL
    ) async throws {
        progress.addLog("    → Applying overlays...")
        progress.addLog(
            "      → telemetry samples: \(video.telemetry?.speedSamples.count ?? 0), speedGauge=\(settings.overlaySettings.speedGaugeEnabled), dateTime=\(settings.overlaySettings.dateTimeEnabled)"
        )
        if settings.overlaySettings.speedGaugeEnabled {
            progress.addLog(
                "      → gauge settings: pos=\(settings.overlaySettings.gaugePosition.rawValue), max=\(Int(settings.overlaySettings.maxSpeed)) \(settings.overlaySettings.speedUnits.rawValue), opacity=\(Int(settings.overlaySettings.gaugeOpacity * 100))%"
            )
        }
        if settings.overlaySettings.dateTimeEnabled {
            let overlayDate = video.captureDate ?? Date()
            progress.addLog("      → date/time text: \(settings.overlaySettings.dateTimeFormat.format(date: overlayDate))")
        }

        let overlayFilename = "\(inputURL.deletingPathExtension().lastPathComponent)_overlay"
        let overlayOutputURL = outputDir
            .appendingPathComponent(overlayFilename)
            .appendingPathExtension(settings.outputSettings.format.fileExtension)

        try await overlayRenderer.renderOverlays(
            inputURL: inputURL,
            outputURL: overlayOutputURL,
            telemetry: video.telemetry,
            videoStartDate: video.captureDate,
            overlaySettings: settings.overlaySettings,
            quality: settings.outputSettings.quality
        )

        // Replace original with overlay version
        try FileManager.default.removeItem(at: inputURL)
        try FileManager.default.moveItem(at: overlayOutputURL, to: inputURL)

        progress.addLog("    ✓ Overlays applied", level: .success)
    }

    private func markCancelledVideos() {
        for index in videos.indices {
            var video = videos[index]
            switch video.processingStatus {
            case .completed:
                continue
            default:
                video.processingStatus = .failed("Cancelled")
                videos[index] = video
            }
        }
    }

    private func fileSystemDate(for url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        if let creationDate = values?.creationDate, isPlausibleCaptureDate(creationDate) {
            return creationDate
        }
        if let modificationDate = values?.contentModificationDate, isPlausibleCaptureDate(modificationDate) {
            return modificationDate
        }
        return nil
    }

    private func isPlausibleCaptureDate(_ date: Date) -> Bool {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year], from: date)
        let year = components.year ?? 0
        let now = Date()
        let oneDayInFuture = now.addingTimeInterval(24 * 60 * 60)
        return year >= 2000 && date <= oneDayInFuture
    }

    private func extractCaptureDate(from asset: AVAsset) async throws -> Date? {
        let commonMetadata = try await asset.load(.commonMetadata)
        if let date = metadataDate(from: commonMetadata) {
            return date
        }

        let fullMetadata = try await asset.load(.metadata)
        return metadataDate(from: fullMetadata)
    }

    private func metadataDate(from items: [AVMetadataItem]) -> Date? {
        for item in items {
            if let date = item.dateValue, isPlausibleCaptureDate(date) {
                return date
            }
            if let dateString = item.stringValue, let parsedDate = parseMetadataDateString(dateString), isPlausibleCaptureDate(parsedDate) {
                return parsedDate
            }
        }
        return nil
    }

    private func parseMetadataDateString(_ dateString: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: dateString) {
            return date
        }

        let fallbackISO = ISO8601DateFormatter()
        if let date = fallbackISO.date(from: dateString) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = formatter.date(from: dateString) {
            return date
        }

        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.date(from: dateString)
    }

    private func sortSegmentsForStitching(_ segments: [VideoStitchService.SegmentFile]) -> [VideoStitchService.SegmentFile] {
        return segments.sorted { lhs, rhs in
            let lhsHasValidDate = lhs.sourceCaptureDate.map(isPlausibleCaptureDate) ?? false
            let rhsHasValidDate = rhs.sourceCaptureDate.map(isPlausibleCaptureDate) ?? false

            if lhsHasValidDate && rhsHasValidDate,
               let lhsDate = lhs.sourceCaptureDate,
               let rhsDate = rhs.sourceCaptureDate,
               lhsDate != rhsDate {
                return lhsDate < rhsDate
            }

            let fileNameComparison = lhs.originalVideoName.localizedStandardCompare(rhs.originalVideoName)
            if fileNameComparison != .orderedSame {
                return fileNameComparison == .orderedAscending
            }

            if lhs.segmentStartTime != rhs.segmentStartTime {
                return lhs.segmentStartTime < rhs.segmentStartTime
            }

            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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
