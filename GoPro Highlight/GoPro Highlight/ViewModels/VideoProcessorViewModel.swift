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

private enum PipelineWorkerLogLevel: Sendable {
    case info
    case warning
    case error
    case success
}

private struct PipelineWorkerLog: Sendable {
    let message: String
    let level: PipelineWorkerLogLevel
}

private struct PipelinePhase1Result: Sendable {
    let index: Int
    let video: GoProVideo
    let logs: [PipelineWorkerLog]
}

private struct PipelinePhase3Result: Sendable {
    let index: Int
    let telemetry: Telemetry?
    let pisteInfo: PisteInfoData?
    let logs: [PipelineWorkerLog]
}

private struct PipelinePhase4Result: Sendable {
    let index: Int
    let logs: [PipelineWorkerLog]
    let segmentFiles: [VideoStitchService.SegmentFile]
}

/// Main ViewModel that orchestrates video processing workflow
@MainActor
@Observable
class VideoProcessorViewModel {
    struct QualityEstimate {
        let quality: ExportSettings.OutputSettings.ExportQuality
        let standaloneBytes: Int64
        let stitchedBytes: Int64
        let totalOutputBytes: Int64
        let outputFileCount: Int
        let estimatedProcessingTimeSeconds: TimeInterval
        let highlightPassthrough: Bool
        let maxSpeedPassthrough: Bool
    }

    struct PreProcessingSummary {
        let outputDirectory: URL
        let totalMovies: Int
        let moviesWithHighlights: Int
        let totalClipDurationSeconds: TimeInterval
        let requestedMaxSpeedTopN: Int
        let maxSpeedCandidateCount: Int
        let plannedMaxSpeedClipCount: Int
        let maxSpeedClipDurationSeconds: TimeInterval
        let standaloneFileCount: Int
        let stitchedWillBeCreated: Bool
        let availableDiskBytes: Int64?
        let estimatesByQuality: [ExportSettings.OutputSettings.ExportQuality: QualityEstimate]
        let defaultQuality: ExportSettings.OutputSettings.ExportQuality
        let recommendedQuality: ExportSettings.OutputSettings.ExportQuality?
        let anyOverlayLayerEnabled: Bool
    }

    enum PreProcessingDecision {
        case continueWithQuality(ExportSettings.OutputSettings.ExportQuality)
        case cancel
    }

    // MARK: - Published State
    var videos: [GoProVideo] = []
    var selectedFolderURL: URL?
    var progress = ProcessingProgress()
    var settings = ExportSettings()
    var isProcessing: Bool = false
    var showError: Bool = false
    var errorMessage: String = ""
    var isAwaitingPreProcessingDecision: Bool = false
    var preProcessingSummary: PreProcessingSummary?

    // MARK: - Services
    private let speedAnalyzer = SpeedAnalysisService()
    private let csvExporter = CSVExportService()
    private let videoStitcher = VideoStitchService()
    private var processingTask: Task<Void, Never>?
    private var selectedFolderHasSecurityScopeAccess: Bool = false
    private let maxParallelWorkers = 2
    private var preProcessingDecisionContinuation: CheckedContinuation<PreProcessingDecision, Never>?

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
        settings.outputSettings.format = .mp4

        processingTask = Task { [weak self] in
            await self?.startProcessing()
        }
    }

    func stopProcessing() {
        guard isProcessing else { return }
        progress.addLog("Stopping processing...", level: .warning)
        cancelPreProcessingDecision()
        processingTask?.cancel()
    }

    func continuePreProcessing(with quality: ExportSettings.OutputSettings.ExportQuality) {
        guard let continuation = preProcessingDecisionContinuation else { return }
        preProcessingDecisionContinuation = nil
        isAwaitingPreProcessingDecision = false
        preProcessingSummary = nil
        continuation.resume(returning: .continueWithQuality(quality))
    }

    func cancelPreProcessingDecision() {
        guard let continuation = preProcessingDecisionContinuation else { return }
        preProcessingDecisionContinuation = nil
        isAwaitingPreProcessingDecision = false
        preProcessingSummary = nil
        continuation.resume(returning: .cancel)
    }

    // MARK: - Folder Selection
    func selectFolder() {
        guard !isProcessing else {
            progress.addLog("Cannot change source folder while processing is running.", level: .warning)
            return
        }

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
                    self.setSelectedFolder(url)
                    await self.loadVideos(from: url)
                }
            }
        }
    }

    // MARK: - Load Videos
    func loadVideos(from folderURL: URL) async {
        guard !isProcessing else {
            progress.addLog("Cannot load videos while processing is running.", level: .warning)
            return
        }

        if selectedFolderURL != folderURL {
            setSelectedFolder(folderURL)
        }

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
                let lhsDate = Self.fileSystemDate(for: lhs)
                let rhsDate = Self.fileSystemDate(for: rhs)
                if let lhsDate, let rhsDate,
                   Self.isPlausibleCaptureDate(lhsDate), Self.isPlausibleCaptureDate(rhsDate) {
                    if lhsDate != rhsDate { return lhsDate < rhsDate }
                }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }

            progress.addLog("Found \(sortedVideoFiles.count) video file(s)")

            // Create GoProVideo objects with duration
            var loadedVideos: [GoProVideo] = []
            for videoURL in sortedVideoFiles {
                var video = GoProVideo(url: videoURL)
                video.captureDate = nil
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

        let runStart = Date()
        let parallelWorkers = min(maxParallelWorkers, max(1, ProcessInfo.processInfo.activeProcessorCount))

        progress.addLog("Starting video processing...", level: .info)
        progress.addLog("  → Output mode: \(settings.outputSettings.outputMode.rawValue)")
        progress.addLog("  → Quality: \(settings.outputSettings.quality.rawValue), Format: \(settings.outputSettings.format.rawValue)")
        progress.addLog("  → Overlays: speed=\(settings.overlaySettings.speedGaugeEnabled), datetime=\(settings.overlaySettings.dateTimeEnabled), piste=\(settings.overlaySettings.pisteDetailsEnabled)")
        progress.addLog("  → Highlight overlay: \(settings.highlightSettings.includeOverlay), Max-speed overlay: \(settings.maxSpeedSettings.includeOverlay)")
        if settings.outputSettings.shouldAttemptPassthrough {
            progress.addLog("  → Passthrough mode: enabled for original-quality clips without overlays")
        } else {
            progress.addLog("  → Passthrough mode: disabled (outputs will be re-encoded)")
        }
        if settings.outputSettings.outputMode != .individual {
            progress.addLog("  → Note: stitched output is always re-encoded", level: .info)
        }
        progress.addLog("  → Parallel workers: \(parallelWorkers)")

        do {
            try Task.checkCancellation()

            // Phase 1: Parse GPMF metadata
            let phase1Start = Date()
            progress.updateProgress(phase: .parsing, progress: 0.0)
            progress.addLog("Phase 1: Parsing GPMF metadata from videos...")

            for index in videos.indices {
                videos[index].processingStatus = .parsing
            }

            let phase1Input = videos
            var phase1Completed = 0

            try await withThrowingTaskGroup(of: PipelinePhase1Result.self) { group in
                var nextIndex = 0
                let initialTasks = min(parallelWorkers, phase1Input.count)
                for _ in 0..<initialTasks {
                    let index = nextIndex
                    let video = phase1Input[index]
                    nextIndex += 1
                    group.addTask {
                        try await Self.parseVideoPhaseTask(index: index, video: video)
                    }
                }

                while let result = try await group.next() {
                    try Task.checkCancellation()
                    phase1Completed += 1
                    videos[result.index] = result.video
                    progress.currentFile = result.video.filename
                    addWorkerLogs(result.logs)

                    let phaseProgress = Double(phase1Completed) / Double(max(phase1Input.count, 1)) * 0.15
                    progress.updateProgress(phase: .parsing, progress: phaseProgress)

                    if nextIndex < phase1Input.count {
                        let index = nextIndex
                        let video = phase1Input[index]
                        nextIndex += 1
                        group.addTask {
                            try await Self.parseVideoPhaseTask(index: index, video: video)
                        }
                    }
                }
            }

            progress.addLog("✓ Phase 1 completed in \(elapsedString(since: phase1Start))", level: .success)

            let resolvedOutputDirectory = settings.outputSettings.resolveOutputDirectory()
            let outputDir = resolvedOutputDirectory ?? selectedFolderURL?.appendingPathComponent("GoPro_Output")
            guard let outputDirectory = outputDir else {
                throw ProcessingError.noOutputDirectory
            }
            let outputDirectoryHasSecurityScopeAccess = outputDirectory.startAccessingSecurityScopedResource()
            defer {
                if outputDirectoryHasSecurityScopeAccess {
                    outputDirectory.stopAccessingSecurityScopedResource()
                }
            }

            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

            // Pre-Processing Review: quick estimate (highlights-first), check disk space, and persist analysis CSV.
            progress.updateProgress(phase: .preProcessingReview, progress: 0.16)
            progress.addLog("Pre-processing review: calculating output estimates...", level: .info)
            let preProcessingSummary = try await buildPreProcessingSummary(outputDirectory: outputDirectory)

            _ = try await saveCSVReport(
                videos: videos,
                outputDirectory: outputDirectory,
                prefix: "GoPro_Analysis_Preflight"
            )

            let preDecision = await awaitPreProcessingDecision(summary: preProcessingSummary)
            switch preDecision {
            case .cancel:
                throw CancellationError()
            case .continueWithQuality(let quality):
                settings.outputSettings.quality = quality
                progress.addLog("Pre-processing approved. Using quality: \(quality.rawValue)", level: .success)
            }

            // Phase 2: Load telemetry if needed and analyze max speed when enabled.
            let phase2Start = Date()
            progress.updateProgress(phase: .analyzing, progress: 0.25)
            let needsMaxSpeedAnalysis = settings.maxSpeedSettings.enabled
            let needsSpeedGaugeTelemetryForExports = settings.overlaySettings.speedGaugeEnabled &&
                (settings.highlightSettings.includeOverlay || (settings.maxSpeedSettings.enabled && settings.maxSpeedSettings.includeOverlay))
            let phase2Input: [(videoIndex: Int, video: GoProVideo)] = videos.enumerated().compactMap { entry in
                let video = entry.element
                if needsMaxSpeedAnalysis {
                    return (entry.offset, video)
                }
                if needsSpeedGaugeTelemetryForExports && !video.highlights.isEmpty {
                    return (entry.offset, video)
                }
                return nil
            }

            if phase2Input.isEmpty {
                progress.addLog("Phase 2: Skipped (no max-speed analysis or speed-gauge telemetry required).", level: .info)
                progress.updateProgress(phase: .analyzing, progress: 0.35)
            } else {
                progress.addLog(
                    needsMaxSpeedAnalysis
                        ? "Phase 2: Loading telemetry and analyzing max speed..."
                        : "Phase 2: Loading telemetry for speed-gauge overlays...",
                    level: .info
                )
                let parser = GPMFParserService()
                var phase2Completed = 0

                for input in phase2Input {
                    try Task.checkCancellation()
                    var video = videos[input.videoIndex]
                    guard video.duration > 0 else {
                        phase2Completed += 1
                        let phaseProgress = 0.25 + Double(phase2Completed) / Double(max(phase2Input.count, 1)) * 0.10
                        progress.updateProgress(phase: .analyzing, progress: phaseProgress)
                        continue
                    }

                    if video.telemetry == nil {
                        do {
                            let telemetry = try await parser.extractTelemetry(from: video.url)
                            video.telemetry = telemetry
                            progress.addLog("  → \(video.filename): Loaded telemetry (\(telemetry.speedSamples.count) samples)", level: .info)
                        } catch {
                            if error is CancellationError {
                                throw error
                            }
                            progress.addLog("  → \(video.filename): No GPS telemetry (\(error.localizedDescription))", level: .warning)
                        }
                    }

                    if needsMaxSpeedAnalysis, let telemetry = video.telemetry {
                        video.processingStatus = .analyzing
                        let stats = await speedAnalyzer.analyzeSpeed(
                            telemetry: telemetry,
                            videoDuration: video.duration
                        )
                        video.speedStats = stats
                        progress.addLog("  ✓ \(video.filename): Max speed \(String(format: "%.1f", stats.maxSpeed)) km/h, avg \(String(format: "%.1f", stats.avgSpeed)) km/h", level: .success)
                    }
                    videos[input.videoIndex] = video

                    phase2Completed += 1
                    let phaseProgress = 0.25 + Double(phase2Completed) / Double(max(phase2Input.count, 1)) * 0.10
                    progress.updateProgress(phase: .analyzing, progress: phaseProgress)
                }
                progress.addLog("✓ Phase 2 completed in \(elapsedString(since: phase2Start))", level: .success)
            }

            let highlightVideoIDs = Set(videos.filter { !$0.highlights.isEmpty }.map(\.id))
            let selectedMaxSpeedVideoIDs = selectedMaxSpeedVideoIDs(
                from: videos,
                maxSpeedSettings: settings.maxSpeedSettings
            )
            let normalizedTopN = max(settings.maxSpeedSettings.topN, 1)
            if settings.maxSpeedSettings.enabled {
                progress.addLog("  → Max-speed selection: \(selectedMaxSpeedVideoIDs.count) video(s) chosen for top \(normalizedTopN)", level: .info)
            }

            // Phase 3: Identify ski pistes only when needed for overlays or filename tokens.
            let phase3Start = Date()
            progress.updateProgress(phase: .identifyingPistes, progress: 0.35)
            let shouldIdentifyPistes = Self.shouldIdentifyPistes(settings)
            let phase3CandidateIDs = highlightVideoIDs.union(selectedMaxSpeedVideoIDs)

            if !shouldIdentifyPistes {
                progress.addLog("Phase 3: Skipped (piste identification not requested).", level: .info)
                progress.updateProgress(phase: .identifyingPistes, progress: 0.45)
            } else {
                let phase3Input: [(videoIndex: Int, video: GoProVideo)] = videos.enumerated()
                    .compactMap { entry in
                        phase3CandidateIDs.contains(entry.element.id) ? (entry.offset, entry.element) : nil
                    }

                if phase3Input.isEmpty {
                    progress.addLog("Phase 3: Skipped (no videos require piste identification for export).", level: .info)
                    progress.updateProgress(phase: .identifyingPistes, progress: 0.45)
                } else {
                    progress.addLog("Phase 3: Identifying ski pistes...")
                    let pisteIdentifier = PisteIdentificationService()
                    var phase3Completed = 0

                    try await withThrowingTaskGroup(of: PipelinePhase3Result.self) { group in
                        var nextIndex = 0
                        let initialTasks = min(parallelWorkers, phase3Input.count)
                        for _ in 0..<initialTasks {
                            let index = nextIndex
                            let input = phase3Input[index]
                            nextIndex += 1
                            group.addTask {
                                try await Self.identifyPistePhaseTask(
                                    index: input.videoIndex,
                                    video: input.video,
                                    pisteIdentifier: pisteIdentifier
                                )
                            }
                        }

                        while let result = try await group.next() {
                            try Task.checkCancellation()
                            phase3Completed += 1
                            if let telemetry = result.telemetry {
                                videos[result.index].telemetry = telemetry
                            }
                            if let pisteInfo = result.pisteInfo {
                                videos[result.index].pisteInfo = pisteInfo
                            }
                            addWorkerLogs(result.logs)

                            let phaseProgress = 0.35 + Double(phase3Completed) / Double(max(phase3Input.count, 1)) * 0.10
                            progress.updateProgress(phase: .identifyingPistes, progress: phaseProgress)

                            if nextIndex < phase3Input.count {
                                let index = nextIndex
                                let input = phase3Input[index]
                                nextIndex += 1
                                group.addTask {
                                    try await Self.identifyPistePhaseTask(
                                        index: input.videoIndex,
                                        video: input.video,
                                        pisteIdentifier: pisteIdentifier
                                    )
                                }
                            }
                        }
                    }

                    let pisteMetrics = await pisteIdentifier.metricsSnapshot()
                    progress.addLog(
                        "  → Piste API metrics: identify requests=\(pisteMetrics.identifyRequests), nearby queries=\(pisteMetrics.nearbyLogicalQueries), resort queries=\(pisteMetrics.resortLogicalQueries), HTTP attempts=\(pisteMetrics.httpAttempts), HTTP successes=\(pisteMetrics.httpSuccesses)",
                        level: .info
                    )
                    progress.addLog(
                        "  → Piste cache metrics: nearby cache hits=\(pisteMetrics.nearbyCacheHits), nearby in-flight joins=\(pisteMetrics.nearbyInflightJoins), resort cache hits=\(pisteMetrics.resortCacheHits), resort in-flight joins=\(pisteMetrics.resortInflightJoins)",
                        level: .info
                    )
                    progress.addLog("✓ Phase 3 completed in \(elapsedString(since: phase3Start))", level: .success)
                }
            }

            // Phase 4: Extract video segments
            let phase4Start = Date()
            progress.updateProgress(phase: .extracting, progress: 0.45)
            progress.addLog("Phase 4: Extracting video segments...")

            let phase4Input: [(videoIndex: Int, video: GoProVideo)] = videos.enumerated()
                .compactMap { entry in
                    let videoID = entry.element.id
                    let shouldExportHighlight = highlightVideoIDs.contains(videoID)
                    let shouldExportMaxSpeed = selectedMaxSpeedVideoIDs.contains(videoID)
                    return (shouldExportHighlight || shouldExportMaxSpeed) ? (entry.offset, entry.element) : nil
                }
            let settingsSnapshot = settings
            var phase4Completed = 0
            var allSegmentFiles: [VideoStitchService.SegmentFile] = []
            if phase4Input.isEmpty {
                progress.addLog("Phase 4: No exportable videos found (no highlights and no max-speed selections).", level: .info)
                progress.updateProgress(phase: .extracting, progress: 0.75)
            } else {
                try await withThrowingTaskGroup(of: PipelinePhase4Result.self) { group in
                    var nextIndex = 0
                    let initialTasks = min(parallelWorkers, phase4Input.count)
                    for _ in 0..<initialTasks {
                        let phase4Entry = phase4Input[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            try await Self.extractSegmentsPhaseTask(
                                index: phase4Entry.videoIndex,
                                video: phase4Entry.video,
                                settings: settingsSnapshot,
                                outputDirectory: outputDirectory,
                                shouldExtractMaxSpeed: selectedMaxSpeedVideoIDs.contains(phase4Entry.video.id),
                                includeLocationInFilename: settingsSnapshot.outputSettings.includePisteInFilenames
                            )
                        }
                    }

                    while let result = try await group.next() {
                        try Task.checkCancellation()
                        phase4Completed += 1
                        progress.currentFile = videos[result.index].filename
                        addWorkerLogs(result.logs)
                        allSegmentFiles.append(contentsOf: result.segmentFiles)

                        let phaseProgress = 0.45 + Double(phase4Completed) / Double(max(phase4Input.count, 1)) * 0.30
                        progress.updateProgress(phase: .extracting, progress: phaseProgress)

                        if nextIndex < phase4Input.count {
                            let phase4Entry = phase4Input[nextIndex]
                            nextIndex += 1
                            group.addTask {
                                try await Self.extractSegmentsPhaseTask(
                                    index: phase4Entry.videoIndex,
                                    video: phase4Entry.video,
                                    settings: settingsSnapshot,
                                    outputDirectory: outputDirectory,
                                    shouldExtractMaxSpeed: selectedMaxSpeedVideoIDs.contains(phase4Entry.video.id),
                                    includeLocationInFilename: settingsSnapshot.outputSettings.includePisteInFilenames
                                )
                            }
                        }
                    }
                }
            }

            progress.addLog("✓ Phase 4 completed in \(elapsedString(since: phase4Start)); produced \(allSegmentFiles.count) segment(s)", level: .success)

            // Phase 5: Stitch videos if requested
            let phase5Start = Date()
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
                    locationToken: settings.outputSettings.includePisteInFilenames
                        ? Self.stitchedLocationToken(from: sortedSegmentFiles)
                        : nil,
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
                    if error is CancellationError {
                        throw error
                    }
                    progress.addLog("✗ Stitching failed: \(error.localizedDescription)", level: .error)
                }
            } else {
                progress.addLog("Phase 5: Stitching skipped (output mode or no segments)", level: .info)
            }
            progress.addLog("✓ Phase 5 completed in \(elapsedString(since: phase5Start))", level: .success)

            // Phase 6: Generate CSV report
            let phase6Start = Date()
            progress.updateProgress(phase: .generatingCSV, progress: 0.90)
            progress.addLog("Phase 6: Generating CSV report...")
            try Task.checkCancellation()

            do {
                _ = try await saveCSVReport(
                    videos: videos,
                    outputDirectory: outputDirectory,
                    prefix: "GoPro_Analysis"
                )
            } catch {
                if error is CancellationError {
                    throw error
                }
                progress.addLog("✗ CSV generation failed: \(error.localizedDescription)", level: .error)
            }

            progress.addLog("✓ Phase 6 completed in \(elapsedString(since: phase6Start))", level: .success)

            // Complete
            progress.updateProgress(phase: .completed, progress: 1.0)
            progress.addLog("🎉 Processing completed successfully!", level: .success)
            progress.addLog("Total processing time: \(elapsedString(since: runStart))", level: .success)
            progress.addLog("Output directory: \(outputDirectory.path)", level: .info)

            for index in videos.indices {
                var video = videos[index]
                video.processingStatus = .completed
                videos[index] = video
            }

        } catch is CancellationError {
            progress.addLog("Processing stopped after \(elapsedString(since: runStart)).", level: .warning)
            progress.updateProgress(phase: .idle, progress: progress.overallProgress)
            markCancelledVideos()
        } catch {
            errorMessage = "Processing failed: \(error.localizedDescription)"
            showError = true
            progress.addLog("❌ Processing failed after \(elapsedString(since: runStart)): \(error.localizedDescription)", level: .error)
        }

        isProcessing = false
        progress.isProcessing = false
        progress.currentFile = ""
        isAwaitingPreProcessingDecision = false
        preProcessingSummary = nil
        preProcessingDecisionContinuation = nil
        processingTask = nil
        progress.filesCompleted = videos.filter { video in
            if case .completed = video.processingStatus {
                return true
            }
            return false
        }.count
    }

    private func addWorkerLogs(_ logs: [PipelineWorkerLog]) {
        for log in logs {
            let level: ProcessingProgress.LogEntry.LogLevel
            switch log.level {
            case .info:
                level = .info
            case .warning:
                level = .warning
            case .error:
                level = .error
            case .success:
                level = .success
            }
            progress.addLog(log.message, level: level)
        }
    }

    private func elapsedString(since start: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(start))
    }

    private func awaitPreProcessingDecision(summary: PreProcessingSummary) async -> PreProcessingDecision {
        preProcessingSummary = summary
        isAwaitingPreProcessingDecision = true
        return await withCheckedContinuation { continuation in
            preProcessingDecisionContinuation = continuation
        }
    }

    func preProcessingEstimate(for quality: ExportSettings.OutputSettings.ExportQuality) -> QualityEstimate? {
        preProcessingSummary?.estimatesByQuality[quality]
    }

    func preProcessingHasEnoughDiskSpace(for quality: ExportSettings.OutputSettings.ExportQuality) -> Bool {
        guard let summary = preProcessingSummary,
              let estimate = summary.estimatesByQuality[quality] else {
            return true
        }
        guard let available = summary.availableDiskBytes else { return true }

        let reserveBytes = Int64(512 * 1024 * 1024) // keep at least 512MB free
        return available - reserveBytes >= estimate.totalOutputBytes
    }

    func preProcessingEncodingDescription(for quality: ExportSettings.OutputSettings.ExportQuality) -> String {
        guard let summary = preProcessingSummary,
              let estimate = summary.estimatesByQuality[quality] else {
            return "Encoding plan unavailable."
        }

        if quality != .original {
            return "Selected quality re-encodes all outputs and may change dimensions."
        }

        var lines: [String] = []
        if estimate.highlightPassthrough {
            lines.append("Highlight clips without overlays: passthrough (no re-encode) when container/codec support it.")
        } else {
            lines.append("Highlight clips: re-encoded.")
        }

        if estimate.maxSpeedPassthrough {
            lines.append("Max-speed clips without overlays: passthrough (no re-encode) when container/codec support it.")
        } else {
            lines.append("Max-speed clips: re-encoded.")
        }

        if summary.stitchedWillBeCreated {
            lines.append("Stitched output is always re-encoded.")
        }
        lines.append("If passthrough is not supported for a specific source/format combination, that clip falls back to re-encode.")

        return lines.joined(separator: " ")
    }

    private func buildPreProcessingSummary(outputDirectory: URL) async throws -> PreProcessingSummary {
        try Task.checkCancellation()

        let videosSnapshot = videos
        let settingsSnapshot = settings
        let segmenter = VideoSegmentService()

        var moviesWithHighlights = 0
        var highlightSegmentCount = 0
        var highlightDuration: TimeInterval = 0

        for video in videosSnapshot {
            if !video.highlights.isEmpty {
                moviesWithHighlights += 1
                let segments = await segmenter.calculateHighlightSegments(
                    highlights: video.highlights,
                    beforeSeconds: settingsSnapshot.highlightSettings.beforeSeconds,
                    afterSeconds: settingsSnapshot.highlightSettings.afterSeconds,
                    videoDuration: video.duration,
                    mergeOverlapping: settingsSnapshot.highlightSettings.mergeOverlapping
                )
                highlightSegmentCount += segments.count
                highlightDuration += segments.reduce(0) { $0 + $1.duration }
            }
        }

        // Keep pre-processing fast: no detailed max-speed ranking or piste work here.
        let maxSpeedCandidateCount = videosSnapshot.count
        let requestedTopN = max(settingsSnapshot.maxSpeedSettings.topN, 1)
        let maxSpeedClipDuration = max(0, settingsSnapshot.maxSpeedSettings.beforeSeconds)
            + max(0, settingsSnapshot.maxSpeedSettings.afterSeconds)
        let plannedMaxSpeedClipCount = settingsSnapshot.maxSpeedSettings.enabled
            ? min(requestedTopN, maxSpeedCandidateCount)
            : 0
        let maxSpeedDuration = TimeInterval(plannedMaxSpeedClipCount) * maxSpeedClipDuration

        let standaloneDuration = highlightDuration + maxSpeedDuration
        let standaloneFileCount = highlightSegmentCount + plannedMaxSpeedClipCount
        let stitchedWillBeCreated = settingsSnapshot.outputSettings.outputMode != .individual && standaloneFileCount > 0
        let availableBytes = availableDiskBytes(for: outputDirectory)
        let sourceAverageBitrateMbps = averageSourceBitrateMbps(from: videosSnapshot)
        let anyOverlayLayerEnabled = Self.anyOverlayLayerEnabled(settingsSnapshot.overlaySettings)
        let highlightNeedsOverlay = settingsSnapshot.highlightSettings.includeOverlay && anyOverlayLayerEnabled
        let maxSpeedNeedsOverlay = settingsSnapshot.maxSpeedSettings.includeOverlay && anyOverlayLayerEnabled

        var estimates: [ExportSettings.OutputSettings.ExportQuality: QualityEstimate] = [:]
        for quality in ExportSettings.OutputSettings.ExportQuality.allCases {
            let reencodeBitrateMbps = bitrateMbps(for: quality, sourceAverageMbps: sourceAverageBitrateMbps)
            let qualityAllowsPassthrough = quality == .original && settingsSnapshot.outputSettings.preferPassthroughWhenNoOverlays
            let highlightPassthrough = qualityAllowsPassthrough && !highlightNeedsOverlay
            let maxSpeedPassthrough = qualityAllowsPassthrough && !maxSpeedNeedsOverlay
            let highlightBitrateMbps = highlightPassthrough ? sourceAverageBitrateMbps : reencodeBitrateMbps
            let maxSpeedBitrateMbps = maxSpeedPassthrough ? sourceAverageBitrateMbps : reencodeBitrateMbps

            let highlightBytes = bytesForDuration(highlightDuration, bitrateMbps: highlightBitrateMbps)
            let maxSpeedBytes = bytesForDuration(maxSpeedDuration, bitrateMbps: maxSpeedBitrateMbps)
            let standaloneBytes = highlightBytes + maxSpeedBytes
            let stitchedBytes = stitchedWillBeCreated
                ? bytesForDuration(standaloneDuration, bitrateMbps: reencodeBitrateMbps)
                : 0

            let totalBytes: Int64
            switch settingsSnapshot.outputSettings.outputMode {
            case .individual:
                totalBytes = standaloneBytes
            case .both:
                totalBytes = standaloneBytes + stitchedBytes
            case .stitched:
                // In stitched mode highlight clips are removed, max-speed clips are kept.
                totalBytes = stitchedBytes + maxSpeedBytes
            }

            let outputFileCount: Int
            switch settingsSnapshot.outputSettings.outputMode {
            case .individual:
                outputFileCount = standaloneFileCount
            case .both:
                outputFileCount = standaloneFileCount + (stitchedWillBeCreated ? 1 : 0)
            case .stitched:
                outputFileCount = plannedMaxSpeedClipCount + (stitchedWillBeCreated ? 1 : 0)
            }

            estimates[quality] = QualityEstimate(
                quality: quality,
                standaloneBytes: standaloneBytes,
                stitchedBytes: stitchedBytes,
                totalOutputBytes: totalBytes,
                outputFileCount: outputFileCount,
                estimatedProcessingTimeSeconds: estimateProcessingTime(
                    for: quality,
                    totalClipDurationSeconds: standaloneDuration,
                    settings: settingsSnapshot
                ),
                highlightPassthrough: highlightPassthrough,
                maxSpeedPassthrough: maxSpeedPassthrough
            )
        }

        let recommendedQuality = recommendedQuality(
            from: estimates,
            availableDiskBytes: availableBytes
        )

        progress.addLog(
            "Pre-processing: found \(moviesWithHighlights) movies with highlights out of \(videosSnapshot.count).",
            level: .info
        )
        progress.addLog(
            "Pre-processing: skipping piste detection and detailed max-speed ranking at this stage.",
            level: .info
        )
        if settingsSnapshot.outputSettings.shouldAttemptPassthrough {
            progress.addLog(
                "Pre-processing: passthrough is enabled for original-quality clips without overlays (stitched output is still re-encoded).",
                level: .info
            )
        } else {
            progress.addLog(
                "Pre-processing: passthrough is disabled; all outputs are estimated as re-encoded.",
                level: .info
            )
        }
        progress.addLog(
            "Pre-processing: planned max-speed clips \(plannedMaxSpeedClipCount) (top \(requestedTopN), candidate videos \(maxSpeedCandidateCount), clip length \(String(format: "%.1fs", maxSpeedClipDuration))).",
            level: .info
        )
        if let availableBytes {
            progress.addLog(
                "Pre-processing: available disk space \(Self.formatBytes(availableBytes)).",
                level: .info
            )
        } else {
            progress.addLog(
                "Pre-processing: could not determine available disk space.",
                level: .warning
            )
        }

        return PreProcessingSummary(
            outputDirectory: outputDirectory,
            totalMovies: videosSnapshot.count,
            moviesWithHighlights: moviesWithHighlights,
            totalClipDurationSeconds: standaloneDuration,
            requestedMaxSpeedTopN: requestedTopN,
            maxSpeedCandidateCount: maxSpeedCandidateCount,
            plannedMaxSpeedClipCount: plannedMaxSpeedClipCount,
            maxSpeedClipDurationSeconds: maxSpeedClipDuration,
            standaloneFileCount: standaloneFileCount,
            stitchedWillBeCreated: stitchedWillBeCreated,
            availableDiskBytes: availableBytes,
            estimatesByQuality: estimates,
            defaultQuality: settingsSnapshot.outputSettings.quality,
            recommendedQuality: recommendedQuality,
            anyOverlayLayerEnabled: anyOverlayLayerEnabled
        )
    }

    private func saveCSVReport(
        videos: [GoProVideo],
        outputDirectory: URL,
        prefix: String
    ) async throws -> URL {
        let csvURL = try await csvExporter.generateReport(videos: videos, includePisteInfo: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let filename = "\(prefix)_\(timestamp).csv"
        var finalCSVURL = outputDirectory.appendingPathComponent(filename)
        var suffix = 1
        while FileManager.default.fileExists(atPath: finalCSVURL.path) {
            finalCSVURL = outputDirectory.appendingPathComponent("\(prefix)_\(timestamp)_\(suffix).csv")
            suffix += 1
        }

        try FileManager.default.copyItem(at: csvURL, to: finalCSVURL)
        progress.addLog("✓ CSV report saved: \(finalCSVURL.lastPathComponent)", level: .success)
        return finalCSVURL
    }

    private func recommendedQuality(
        from estimates: [ExportSettings.OutputSettings.ExportQuality: QualityEstimate],
        availableDiskBytes: Int64?
    ) -> ExportSettings.OutputSettings.ExportQuality? {
        let preferredOrder: [ExportSettings.OutputSettings.ExportQuality] = [.original, .high, .medium, .low]
        guard let availableDiskBytes else {
            return preferredOrder.first(where: { estimates[$0] != nil })
        }

        let reserveBytes = Int64(512 * 1024 * 1024)
        let limit = max(0, availableDiskBytes - reserveBytes)
        return preferredOrder.first { quality in
            guard let estimate = estimates[quality] else { return false }
            return estimate.totalOutputBytes <= limit
        }
    }

    private func bytesForDuration(_ seconds: TimeInterval, bitrateMbps: Double) -> Int64 {
        guard seconds > 0, bitrateMbps > 0 else { return 0 }
        let bits = seconds * bitrateMbps * 1_000_000
        return Int64(bits / 8.0)
    }

    private nonisolated static func anyOverlayLayerEnabled(_ settings: ExportSettings.OverlaySettings) -> Bool {
        settings.speedGaugeEnabled || settings.dateTimeEnabled || settings.pisteDetailsEnabled
    }

    private nonisolated static func shouldIdentifyPistes(_ settings: ExportSettings) -> Bool {
        let pisteOverlayRequested = settings.overlaySettings.pisteDetailsEnabled &&
            (settings.highlightSettings.includeOverlay ||
             (settings.maxSpeedSettings.enabled && settings.maxSpeedSettings.includeOverlay))
        return pisteOverlayRequested || settings.outputSettings.includePisteInFilenames
    }

    private func averageSourceBitrateMbps(from videos: [GoProVideo]) -> Double {
        var totalBits = 0.0
        var totalSeconds = 0.0
        for video in videos where video.duration > 0 && video.fileSize > 0 {
            totalBits += Double(video.fileSize) * 8.0
            totalSeconds += video.duration
        }
        guard totalSeconds > 0 else { return 10.0 }
        return max(1.0, totalBits / totalSeconds / 1_000_000.0)
    }

    private func bitrateMbps(
        for quality: ExportSettings.OutputSettings.ExportQuality,
        sourceAverageMbps: Double
    ) -> Double {
        let normalizedSource = max(1.0, sourceAverageMbps)
        switch quality {
        case .original:
            // Re-encode estimate used when passthrough is not applicable.
            return min(max(normalizedSource * 0.35, 8.0), 24.0)
        case .high:
            return min(max(normalizedSource * 0.25, 6.0), 14.0)
        case .medium:
            return min(max(normalizedSource * 0.14, 3.5), 8.0)
        case .low:
            return min(max(normalizedSource * 0.08, 2.0), 4.5)
        }
    }

    private func estimateProcessingTime(
        for quality: ExportSettings.OutputSettings.ExportQuality,
        totalClipDurationSeconds: TimeInterval,
        settings: ExportSettings
    ) -> TimeInterval {
        var multiplier = 1.1 // parse + analyze overhead

        switch quality {
        case .original:
            let anyOverlayLayerEnabled = Self.anyOverlayLayerEnabled(settings.overlaySettings)
            let highlightNeedsOverlay = settings.highlightSettings.includeOverlay && anyOverlayLayerEnabled
            let maxSpeedNeedsOverlay = settings.maxSpeedSettings.includeOverlay && anyOverlayLayerEnabled
            if settings.outputSettings.preferPassthroughWhenNoOverlays &&
                !highlightNeedsOverlay && !maxSpeedNeedsOverlay &&
                settings.outputSettings.outputMode == .individual {
                multiplier += 0.2
            } else if settings.outputSettings.preferPassthroughWhenNoOverlays &&
                        (!highlightNeedsOverlay || !maxSpeedNeedsOverlay) {
                multiplier += 0.35
            } else {
                multiplier += 0.5
            }
        case .high:
            multiplier += 1.5
        case .medium:
            multiplier += 1.0
        case .low:
            multiplier += 0.7
        }

        if settings.overlaySettings.speedGaugeEnabled {
            multiplier += 0.5
        }
        if settings.overlaySettings.dateTimeEnabled {
            multiplier += 0.3
        }
        if settings.overlaySettings.pisteDetailsEnabled {
            multiplier += 0.2
        }
        if settings.outputSettings.outputMode != .individual {
            multiplier += 0.5
        }

        return max(0, totalClipDurationSeconds) * multiplier
    }

    private func availableDiskBytes(for outputDirectory: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? outputDirectory.resourceValues(forKeys: keys) else {
            return nil
        }
        if let important = values.volumeAvailableCapacityForImportantUsage {
            return Int64(important)
        }
        if let standard = values.volumeAvailableCapacity {
            return Int64(standard)
        }
        return nil
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private nonisolated static func parseVideoPhaseTask(index: Int, video: GoProVideo) async throws -> PipelinePhase1Result {
        try Task.checkCancellation()
        let parser = GPMFParserService()
        var parsedVideo = video
        var logs: [PipelineWorkerLog] = []
        let start = Date()

        let asset = AVAsset(url: video.url)
        do {
            let dur = try await asset.load(.duration)
            parsedVideo.duration = CMTimeGetSeconds(dur)
            let attrs = try FileManager.default.attributesOfItem(atPath: video.url.path)
            parsedVideo.fileSize = (attrs[.size] as? Int64) ?? 0
            logs.append(PipelineWorkerLog(message: "  → \(video.filename): duration \(String(format: "%.1f", max(0, parsedVideo.duration)))s, size \(Self.formatFileSize(parsedVideo.fileSize))", level: .info))

            if let metadataCaptureDate = try await Self.extractCaptureDate(from: asset),
               Self.isPlausibleCaptureDate(metadataCaptureDate) {
                parsedVideo.captureDate = metadataCaptureDate
                logs.append(PipelineWorkerLog(message: "  → \(video.filename): capture date \(metadataCaptureDate.formatted(date: .abbreviated, time: .standard)) (metadata)", level: .info))
            } else if let fileDate = Self.fileSystemDate(for: video.url), Self.isPlausibleCaptureDate(fileDate) {
                parsedVideo.captureDate = fileDate
                logs.append(PipelineWorkerLog(message: "  → \(video.filename): capture date \(fileDate.formatted(date: .abbreviated, time: .standard)) (filesystem fallback)", level: .warning))
            }
        } catch {
            if error is CancellationError {
                throw error
            }
            logs.append(PipelineWorkerLog(message: "  → \(video.filename): Could not load duration (\(error.localizedDescription))", level: .warning))
        }

        do {
            let highlights = try await parser.findHighlights(in: video.url)
            parsedVideo.highlights = highlights
            if !highlights.isEmpty {
                logs.append(PipelineWorkerLog(message: "  ✓ \(video.filename): Found \(highlights.count) highlight(s)", level: .success))
            } else {
                logs.append(PipelineWorkerLog(message: "  → \(video.filename): No highlights marked", level: .info))
            }
        } catch {
            if error is CancellationError {
                throw error
            }
            logs.append(PipelineWorkerLog(message: "  → \(video.filename): Could not read highlights (\(error.localizedDescription))", level: .warning))
        }

        logs.append(PipelineWorkerLog(message: "  ✓ \(video.filename): Phase 1 done in \(workerElapsed(since: start))", level: .info))
        return PipelinePhase1Result(index: index, video: parsedVideo, logs: logs)
    }

    private nonisolated static func identifyPistePhaseTask(
        index: Int,
        video: GoProVideo,
        pisteIdentifier: PisteIdentificationService
    ) async throws -> PipelinePhase3Result {
        try Task.checkCancellation()
        var logs: [PipelineWorkerLog] = []
        let start = Date()
        var telemetry = video.telemetry

        if telemetry == nil {
            do {
                let parser = GPMFParserService()
                telemetry = try await parser.extractTelemetry(from: video.url)
                logs.append(PipelineWorkerLog(message: "  → \(video.filename): Loaded telemetry for piste detection (\(telemetry?.gpsPoints.count ?? 0) GPS points)", level: .info))
            } catch {
                if error is CancellationError {
                    throw error
                }
                logs.append(PipelineWorkerLog(message: "  → \(video.filename): Skipping piste detection (no telemetry: \(error.localizedDescription))", level: .warning))
                return PipelinePhase3Result(index: index, telemetry: nil, pisteInfo: nil, logs: logs)
            }
        }

        guard let telemetry else {
            logs.append(PipelineWorkerLog(message: "  → \(video.filename): Skipping piste detection (no telemetry)", level: .info))
            return PipelinePhase3Result(index: index, telemetry: nil, pisteInfo: nil, logs: logs)
        }

        logs.append(PipelineWorkerLog(message: "  → \(video.filename): Running piste detection on \(telemetry.gpsPoints.count) GPS points", level: .info))

        do {
            if let piste = try await pisteIdentifier.identifyPiste(from: telemetry) {
                let mapped = PisteInfoData(
                    name: piste.name,
                    difficulty: piste.difficulty,
                    resort: piste.resort,
                    confidence: piste.confidence
                )
                let resortSuffix = mapped.resort.map { " | \($0)" } ?? ""
                logs.append(PipelineWorkerLog(message: "  ✓ \(video.filename): \(mapped.name)\(resortSuffix) (confidence: \(Int(mapped.confidence * 100))%)", level: .success))
                logs.append(PipelineWorkerLog(message: "  ✓ \(video.filename): Phase 3 done in \(workerElapsed(since: start))", level: .info))
                return PipelinePhase3Result(index: index, telemetry: telemetry, pisteInfo: mapped, logs: logs)
            }

            logs.append(PipelineWorkerLog(message: "  → \(video.filename): No piste identified", level: .info))
            logs.append(PipelineWorkerLog(message: "  ✓ \(video.filename): Phase 3 done in \(workerElapsed(since: start))", level: .info))
            return PipelinePhase3Result(index: index, telemetry: telemetry, pisteInfo: nil, logs: logs)
        } catch {
            if error is CancellationError {
                throw error
            }
            logs.append(PipelineWorkerLog(message: "  ✗ \(video.filename): Piste identification failed (\(error.localizedDescription))", level: .warning))
            logs.append(PipelineWorkerLog(message: "  ✓ \(video.filename): Phase 3 done in \(workerElapsed(since: start))", level: .info))
            return PipelinePhase3Result(index: index, telemetry: telemetry, pisteInfo: nil, logs: logs)
        }
    }

    private nonisolated static func extractSegmentsPhaseTask(
        index: Int,
        video: GoProVideo,
        settings: ExportSettings,
        outputDirectory: URL,
        shouldExtractMaxSpeed: Bool,
        includeLocationInFilename: Bool
    ) async throws -> PipelinePhase4Result {
        try Task.checkCancellation()
        let start = Date()
        var logs: [PipelineWorkerLog] = []
        var segmentFiles: [VideoStitchService.SegmentFile] = []

        let segmenter = VideoSegmentService()
        let renderer = OverlayRenderService()
        let anyOverlayLayerEnabled = Self.anyOverlayLayerEnabled(settings.overlaySettings)
        let highlightNeedsOverlay = settings.highlightSettings.includeOverlay && anyOverlayLayerEnabled
        let maxSpeedNeedsOverlay = settings.maxSpeedSettings.includeOverlay && anyOverlayLayerEnabled
        let highlightCanPassthrough = settings.outputSettings.shouldAttemptPassthrough && !highlightNeedsOverlay
        let maxSpeedCanPassthrough = settings.outputSettings.shouldAttemptPassthrough && !maxSpeedNeedsOverlay

        if !video.highlights.isEmpty && settings.highlightSettings.beforeSeconds >= 0 {
            let segments = await segmenter.calculateHighlightSegments(
                highlights: video.highlights,
                beforeSeconds: settings.highlightSettings.beforeSeconds,
                afterSeconds: settings.highlightSettings.afterSeconds,
                videoDuration: video.duration,
                mergeOverlapping: settings.highlightSettings.mergeOverlapping
            )

            logs.append(PipelineWorkerLog(message: "  → \(video.filename): Extracting \(segments.count) highlight segment(s)...", level: .info))

            for (segmentIndex, segment) in segments.enumerated() {
                try Task.checkCancellation()
                logs.append(PipelineWorkerLog(message: "    → Segment \(segmentIndex + 1): \(String(format: "%.2f", segment.startTime))s - \(String(format: "%.2f", segment.endTime))s", level: .info))
                let outputFilename = Self.highlightOutputFilename(
                    video: video,
                    segment: segment,
                    includeLocationInFilename: includeLocationInFilename,
                    format: settings.outputSettings.format
                )
                let outputURL = Self.uniqueOutputURL(
                    outputDirectory: outputDirectory,
                    outputFilename: outputFilename
                )

                do {
                    let extractStart = Date()
                    let extractionResult = try await segmenter.extractSegment(
                        from: video.url,
                        segment: segment,
                        outputURL: outputURL,
                        quality: settings.outputSettings.quality,
                        preferPassthrough: highlightCanPassthrough
                    )
                    if let fallbackReason = extractionResult.fallbackReason {
                        logs.append(PipelineWorkerLog(message: "    → \(outputFilename): \(fallbackReason)", level: .warning))
                    }
                    let encodingLabel = extractionResult.mode == .passthrough ? "passthrough" : "re-encoded"
                    logs.append(PipelineWorkerLog(message: "    ✓ Created: \(outputFilename) [\(encodingLabel)] (\(workerElapsed(since: extractStart)))", level: .success))

                    if settings.highlightSettings.includeOverlay &&
                       (settings.overlaySettings.speedGaugeEnabled || settings.overlaySettings.dateTimeEnabled || settings.overlaySettings.pisteDetailsEnabled) {
                        let overlayLogs = try await renderOverlaysForTask(
                            inputURL: outputURL,
                            video: video,
                            outputDir: outputDirectory,
                            sourceSegmentStartTime: segment.startTime,
                            settings: settings,
                            renderer: renderer
                        )
                        logs.append(contentsOf: overlayLogs)
                    }

                    segmentFiles.append(
                        VideoStitchService.SegmentFile(
                            url: outputURL,
                            originalVideoName: video.filename,
                            durationSeconds: segment.duration,
                            sourceCaptureDate: video.captureDate,
                            segmentStartTime: segment.startTime,
                            kind: .highlight,
                            pisteName: video.pisteInfo?.name,
                            resortName: video.pisteInfo?.resort
                        )
                    )
                } catch {
                    if error is CancellationError {
                        throw error
                    }
                    logs.append(PipelineWorkerLog(message: "    ✗ Failed: \(error.localizedDescription)", level: .error))
                }
            }
        }

        if settings.maxSpeedSettings.enabled,
           shouldExtractMaxSpeed,
           let stats = video.speedStats,
           stats.maxSpeed > 0 {
            try Task.checkCancellation()

            let segment = await segmenter.calculateMaxSpeedSegment(
                maxSpeedTime: stats.maxSpeedTime,
                beforeSeconds: settings.maxSpeedSettings.beforeSeconds,
                afterSeconds: settings.maxSpeedSettings.afterSeconds,
                videoDuration: video.duration
            )
            logs.append(PipelineWorkerLog(message: "  → Max-speed segment range: \(String(format: "%.2f", segment.startTime))s - \(String(format: "%.2f", segment.endTime))s", level: .info))

            let outputFilename = Self.maxSpeedOutputFilename(
                video: video,
                maxSpeed: stats.maxSpeed,
                maxSpeedTimestamp: stats.maxSpeedTime,
                includeLocationInFilename: includeLocationInFilename,
                format: settings.outputSettings.format
            )
            let outputURL = Self.uniqueOutputURL(
                outputDirectory: outputDirectory,
                outputFilename: outputFilename
            )

            do {
                    let extractStart = Date()
                    let extractionResult = try await segmenter.extractSegment(
                        from: video.url,
                        segment: segment,
                        outputURL: outputURL,
                        quality: settings.outputSettings.quality,
                        preferPassthrough: maxSpeedCanPassthrough
                    )
                    if let fallbackReason = extractionResult.fallbackReason {
                        logs.append(PipelineWorkerLog(message: "  → \(outputFilename): \(fallbackReason)", level: .warning))
                    }
                    let encodingLabel = extractionResult.mode == .passthrough ? "passthrough" : "re-encoded"
                    logs.append(PipelineWorkerLog(message: "  ✓ Max speed segment: \(outputFilename) [\(encodingLabel)] (\(workerElapsed(since: extractStart)))", level: .success))

                if settings.maxSpeedSettings.includeOverlay &&
                   (settings.overlaySettings.speedGaugeEnabled || settings.overlaySettings.dateTimeEnabled || settings.overlaySettings.pisteDetailsEnabled) {
                    let overlayLogs = try await renderOverlaysForTask(
                        inputURL: outputURL,
                        video: video,
                        outputDir: outputDirectory,
                        sourceSegmentStartTime: segment.startTime,
                        settings: settings,
                        renderer: renderer
                    )
                    logs.append(contentsOf: overlayLogs)
                }

                segmentFiles.append(
                    VideoStitchService.SegmentFile(
                        url: outputURL,
                        originalVideoName: video.filename,
                        durationSeconds: segment.duration,
                        sourceCaptureDate: video.captureDate,
                        segmentStartTime: segment.startTime,
                        kind: .maxSpeed,
                        pisteName: video.pisteInfo?.name,
                        resortName: video.pisteInfo?.resort
                    )
                )
            } catch {
                if error is CancellationError {
                    throw error
                }
                logs.append(PipelineWorkerLog(message: "  ✗ Max speed extraction failed: \(error.localizedDescription)", level: .error))
            }
        } else if settings.maxSpeedSettings.enabled && shouldExtractMaxSpeed {
            logs.append(PipelineWorkerLog(message: "  → \(video.filename): No valid max-speed telemetry segment", level: .info))
        }

        logs.append(PipelineWorkerLog(message: "  ✓ \(video.filename): Phase 4 done in \(workerElapsed(since: start))", level: .info))
        return PipelinePhase4Result(index: index, logs: logs, segmentFiles: segmentFiles)
    }

    private nonisolated static func renderOverlaysForTask(
        inputURL: URL,
        video: GoProVideo,
        outputDir: URL,
        sourceSegmentStartTime: TimeInterval,
        settings: ExportSettings,
        renderer: OverlayRenderService
    ) async throws -> [PipelineWorkerLog] {
        var logs: [PipelineWorkerLog] = []
        let overlayStart = Date()

        logs.append(PipelineWorkerLog(message: "    → Applying overlays...", level: .info))
        logs.append(PipelineWorkerLog(message: "      → telemetry samples: \(video.telemetry?.speedSamples.count ?? 0), speedGauge=\(settings.overlaySettings.speedGaugeEnabled), dateTime=\(settings.overlaySettings.dateTimeEnabled), piste=\(settings.overlaySettings.pisteDetailsEnabled)", level: .info))
        logs.append(PipelineWorkerLog(message: "      → segment start: \(String(format: "%.2f", sourceSegmentStartTime))s", level: .info))
        if settings.overlaySettings.speedGaugeEnabled {
            logs.append(PipelineWorkerLog(message: "      → gauge settings: style=\(settings.overlaySettings.gaugeStyle.rawValue), pos=\(settings.overlaySettings.gaugePosition.rawValue), max=\(Int(settings.overlaySettings.maxSpeed)) \(settings.overlaySettings.speedUnits.rawValue), size=\(Int(settings.overlaySettings.gaugeScale * 100))%, opacity=\(Int(settings.overlaySettings.gaugeOpacity * 100))%", level: .info))
        }
        if settings.overlaySettings.dateTimeEnabled {
            let overlayDate = video.captureDate ?? Date()
            logs.append(PipelineWorkerLog(message: "      → date/time text: \(settings.overlaySettings.dateTimeFormat.format(date: overlayDate))", level: .info))
        }
        if settings.overlaySettings.pisteDetailsEnabled {
            let pisteText = video.pisteInfo.map { "\($0.name) | \($0.resort ?? "Unknown resort")" } ?? "No piste data"
            logs.append(PipelineWorkerLog(message: "      → piste text: \(pisteText)", level: .info))
        }

        let overlayFilename = "\(inputURL.deletingPathExtension().lastPathComponent)_overlay"
        let overlayOutputURL = outputDir
            .appendingPathComponent(overlayFilename)
            .appendingPathExtension(settings.outputSettings.format.fileExtension)

        try await renderer.renderOverlays(
            inputURL: inputURL,
            outputURL: overlayOutputURL,
            telemetry: video.telemetry,
            pisteInfo: video.pisteInfo,
            videoStartDate: video.captureDate,
            sourceSegmentStartTime: sourceSegmentStartTime,
            overlaySettings: settings.overlaySettings,
            quality: settings.outputSettings.quality
        )

        try FileManager.default.removeItem(at: inputURL)
        try FileManager.default.moveItem(at: overlayOutputURL, to: inputURL)

        logs.append(PipelineWorkerLog(message: "    ✓ Overlays applied (\(workerElapsed(since: overlayStart)))", level: .success))
        return logs
    }

    private nonisolated static func workerElapsed(since start: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(start))
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

    private nonisolated static func fileSystemDate(for url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        if let creationDate = values?.creationDate, isPlausibleCaptureDate(creationDate) {
            return creationDate
        }
        if let modificationDate = values?.contentModificationDate, isPlausibleCaptureDate(modificationDate) {
            return modificationDate
        }
        return nil
    }

    private nonisolated static func isPlausibleCaptureDate(_ date: Date) -> Bool {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year], from: date)
        let year = components.year ?? 0
        let now = Date()
        let oneDayInFuture = now.addingTimeInterval(24 * 60 * 60)
        return year >= 2000 && date <= oneDayInFuture
    }

    private nonisolated static func extractCaptureDate(from asset: AVAsset) async throws -> Date? {
        if let creationDateItem = try await asset.load(.creationDate) {
            if #available(macOS 13.0, *) {
                if let directDate = try? await creationDateItem.load(.dateValue),
                   isPlausibleCaptureDate(directDate) {
                    return directDate
                }
                if let dateString = try? await creationDateItem.load(.stringValue),
                   let parsedDate = parseMetadataDateString(dateString),
                   isPlausibleCaptureDate(parsedDate) {
                    return parsedDate
                }
            } else {
                if let directDate = creationDateItem.dateValue, isPlausibleCaptureDate(directDate) {
                    return directDate
                }
                if let dateString = creationDateItem.stringValue,
                   let parsedDate = parseMetadataDateString(dateString),
                   isPlausibleCaptureDate(parsedDate) {
                    return parsedDate
                }
            }
        }

        let commonMetadata = try await asset.load(.commonMetadata)
        if let date = await metadataDate(from: commonMetadata) {
            return date
        }

        let metadataFormats = try await asset.load(.availableMetadataFormats)
        for format in metadataFormats {
            let items: [AVMetadataItem]
            if #available(macOS 13.0, *) {
                items = try await asset.loadMetadata(for: format)
            } else {
                items = asset.metadata(forFormat: format)
            }
            if let date = await metadataDate(from: items) {
                return date
            }
        }

        let fullMetadata = try await asset.load(.metadata)
        return await metadataDate(from: fullMetadata)
    }

    private nonisolated static func metadataDate(from items: [AVMetadataItem]) async -> Date? {
        for item in items {
            if #available(macOS 13.0, *) {
                if let date = try? await item.load(.dateValue),
                   isPlausibleCaptureDate(date) {
                    return date
                }
                if let dateString = try? await item.load(.stringValue),
                   let parsedDate = parseMetadataDateString(dateString),
                   isPlausibleCaptureDate(parsedDate) {
                    return parsedDate
                }
            } else {
                if let date = item.dateValue, isPlausibleCaptureDate(date) {
                    return date
                }
                if let dateString = item.stringValue,
                   let parsedDate = parseMetadataDateString(dateString),
                   isPlausibleCaptureDate(parsedDate) {
                    return parsedDate
                }
            }
        }
        return nil
    }

    private nonisolated static func parseMetadataDateString(_ dateString: String) -> Date? {
        let normalized = dateString.trimmingCharacters(in: .whitespacesAndNewlines)

        let isoWithFractional = ISO8601DateFormatter()
        isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoWithFractional.date(from: normalized) {
            return date
        }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: normalized) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy:MM:dd HH:mm:ss"
        ]

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: normalized) {
                return date
            }
        }

        return nil
    }

    private func sortSegmentsForStitching(_ segments: [VideoStitchService.SegmentFile]) -> [VideoStitchService.SegmentFile] {
        return segments.sorted { lhs, rhs in
            let lhsHasValidDate = lhs.sourceCaptureDate.map(Self.isPlausibleCaptureDate) ?? false
            let rhsHasValidDate = rhs.sourceCaptureDate.map(Self.isPlausibleCaptureDate) ?? false

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

    private nonisolated static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private nonisolated static func highlightOutputFilename(
        video: GoProVideo,
        segment: VideoSegmentService.VideoSegment,
        includeLocationInFilename: Bool,
        format: ExportSettings.OutputSettings.VideoFormat
    ) -> String {
        let baseName = sanitizeFilenameToken((video.filename as NSString).deletingPathExtension)
        let dateToken = exportDateToken(from: video.captureDate)
        let highlightTimestampToken = timestampToken(from: segment.highlightTime ?? segment.startTime)
        let locationSuffix: String
        if includeLocationInFilename,
           let locationToken = pisteResortToken(from: video.pisteInfo) {
            locationSuffix = "_\(locationToken)"
        } else {
            locationSuffix = ""
        }
        return "\(baseName)_fottage_\(dateToken)_\(highlightTimestampToken)\(locationSuffix).\(format.fileExtension)"
    }

    private nonisolated static func maxSpeedOutputFilename(
        video: GoProVideo,
        maxSpeed: Double,
        maxSpeedTimestamp: TimeInterval,
        includeLocationInFilename: Bool,
        format: ExportSettings.OutputSettings.VideoFormat
    ) -> String {
        let baseName = sanitizeFilenameToken((video.filename as NSString).deletingPathExtension)
        let dateToken = exportDateToken(from: video.captureDate)
        let speedToken = speedToken(from: maxSpeed)
        let timestampToken = timestampToken(from: maxSpeedTimestamp)
        let locationSuffix: String
        if includeLocationInFilename,
           let locationToken = pisteResortToken(from: video.pisteInfo) {
            locationSuffix = "_\(locationToken)"
        } else {
            locationSuffix = ""
        }

        return "\(baseName)_fottage_\(dateToken)_max_speed_\(speedToken)_\(timestampToken)\(locationSuffix).\(format.fileExtension)"
    }

    private nonisolated static func uniqueOutputURL(
        outputDirectory: URL,
        outputFilename: String
    ) -> URL {
        var outputURL = outputDirectory.appendingPathComponent(outputFilename)
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            return outputURL
        }

        let baseName = (outputFilename as NSString).deletingPathExtension
        let ext = (outputFilename as NSString).pathExtension
        var suffix = 1
        while FileManager.default.fileExists(atPath: outputURL.path) {
            outputURL = outputDirectory.appendingPathComponent("\(baseName)_\(suffix).\(ext)")
            suffix += 1
        }
        return outputURL
    }

    private nonisolated static func exportDateToken(from date: Date?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date ?? Date())
    }

    private nonisolated static func speedToken(from speed: Double) -> String {
        let value = String(format: "%.1f", max(0, speed))
            .replacingOccurrences(of: ".", with: "_")
        return "\(value)kmh"
    }

    private nonisolated static func timestampToken(from seconds: TimeInterval) -> String {
        let value = String(format: "%.2f", max(0, seconds))
            .replacingOccurrences(of: ".", with: "_")
        return "\(value)s"
    }

    private nonisolated static func pisteResortToken(from pisteInfo: PisteInfoData?) -> String? {
        guard let pisteInfo else { return nil }

        let piste = pisteInfo.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resort = (pisteInfo.resort ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !piste.isEmpty && !resort.isEmpty {
            return sanitizeFilenameToken("\(piste)+\(resort)")
        }
        if !piste.isEmpty {
            return sanitizeFilenameToken(piste)
        }
        if !resort.isEmpty {
            return sanitizeFilenameToken(resort)
        }
        return nil
    }

    private nonisolated static func stitchedLocationToken(
        from segments: [VideoStitchService.SegmentFile]
    ) -> String? {
        var resortCounts: [String: Int] = [:]
        var pisteCounts: [String: Int] = [:]

        for segment in segments {
            if let resort = segment.resortName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !resort.isEmpty {
                resortCounts[resort, default: 0] += 1
            }
            if let piste = segment.pisteName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !piste.isEmpty {
                pisteCounts[piste, default: 0] += 1
            }
        }

        let topResort = resortCounts.max { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key > rhs.key }
            return lhs.value < rhs.value
        }?.key
        let topPiste = pisteCounts.max { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key > rhs.key }
            return lhs.value < rhs.value
        }?.key

        if let topPiste, let topResort {
            return sanitizeFilenameToken("\(topPiste)+\(topResort)")
        }
        if let topResort {
            return sanitizeFilenameToken(topResort)
        }
        if let topPiste {
            return sanitizeFilenameToken(topPiste)
        }
        return nil
    }

    private nonisolated static func sanitizeFilenameToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-+"))
        let normalized = value
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var scalarView = String.UnicodeScalarView()
        for scalar in normalized.unicodeScalars {
            if allowed.contains(scalar) {
                scalarView.append(scalar)
            } else {
                scalarView.append("_".unicodeScalars.first!)
            }
        }

        let sanitized = String(scalarView)
            .replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        return sanitized.isEmpty ? "unknown" : sanitized
    }

    private func setSelectedFolder(_ url: URL?) {
        if selectedFolderHasSecurityScopeAccess, let currentFolderURL = selectedFolderURL {
            currentFolderURL.stopAccessingSecurityScopedResource()
        }
        selectedFolderHasSecurityScopeAccess = false
        selectedFolderURL = nil

        guard let url else { return }
        selectedFolderHasSecurityScopeAccess = url.startAccessingSecurityScopedResource()
        selectedFolderURL = url
    }

    private func selectedMaxSpeedVideoIDs(
        from phase4Input: [GoProVideo],
        maxSpeedSettings: ExportSettings.MaxSpeedSettings
    ) -> Set<UUID> {
        guard maxSpeedSettings.enabled else { return [] }

        let ranked: [(id: UUID, speed: Double)] = phase4Input
            .compactMap { video in
                guard let stats = video.speedStats, stats.maxSpeed > 0 else { return nil }
                return (id: video.id, speed: stats.maxSpeed)
            }
            .sorted { (lhs: (id: UUID, speed: Double), rhs: (id: UUID, speed: Double)) in
                if lhs.speed != rhs.speed {
                    return lhs.speed > rhs.speed
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }

        let selectionCount = max(maxSpeedSettings.topN, 1)
        return Set(ranked.prefix(selectionCount).map { $0.id })
    }

    func buildBugReport(userDescription: String) -> String {
        let issueDescription = userDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let timestamp = ISO8601DateFormatter().string(from: Date())

        var sections: [String] = []
        sections.append("GoPro Highlight Bug Report")
        sections.append("Generated: \(timestamp)")
        sections.append("App Version: \(appVersion) (\(buildNumber))")
        sections.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        let selectedFolderText = selectedFolderURL?.path ?? "Not selected"
        sections.append("Selected Folder: \(selectedFolderText)")
        sections.append("Videos Loaded: \(videos.count)")
        sections.append("Is Processing: \(isProcessing)")

        if issueDescription.isEmpty {
            sections.append("Issue Description:\n(No user description provided)")
        } else {
            sections.append("Issue Description:\n\(issueDescription)")
        }

        if let settingsJSON = formattedSettingsJSON() {
            sections.append("Settings:\n\(settingsJSON)")
        }

        let videoLines = videos.prefix(50).map { video in
            let maxSpeed = video.speedStats.map { String(format: "%.1f km/h", $0.maxSpeed) } ?? "n/a"
            return "- \(video.filename) | status: \(video.processingStatus.description) | duration: \(String(format: "%.1fs", max(0, video.duration))) | maxSpeed: \(maxSpeed)"
        }
        let videoSection = videoLines.isEmpty ? "(No videos loaded)" : videoLines.joined(separator: "\n")
        sections.append("Video Summary:\n\(videoSection)")

        let logLines = progress.logs.suffix(200).map { log in
            "[\(log.formattedTimestamp)] [\(String(describing: log.level).uppercased())] \(log.message)"
        }
        let logsSection = logLines.isEmpty ? "(No logs available)" : logLines.joined(separator: "\n")
        sections.append("Recent Logs:\n\(logsSection)")

        return sections.joined(separator: "\n\n")
    }

    private func formattedSettingsJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
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
        guard !isProcessing else {
            progress.addLog("Cannot clear videos while processing is running.", level: .warning)
            return
        }
        videos.removeAll()
        setSelectedFolder(nil)
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
