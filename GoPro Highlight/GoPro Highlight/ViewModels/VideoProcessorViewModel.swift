//
//  VideoProcessorViewModel.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import Foundation
import Observation
import SwiftUI

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

            // Create GoProVideo objects
            var loadedVideos: [GoProVideo] = []
            for videoURL in videoFiles {
                var video = GoProVideo(url: videoURL)

                // Get file size
                if let resources = try? videoURL.resourceValues(forKeys: [.fileSizeKey]),
                   let fileSize = resources.fileSize {
                    video = GoProVideo(url: videoURL)
                    loadedVideos.append(video)
                }
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
        progress.addLog("Starting video processing...")

        // This will be implemented in later phases
        // For now, just show a placeholder
        progress.updateProgress(phase: .parsing, progress: 0.1)
        progress.addLog("Phase 1: Parsing metadata (not yet implemented)")

        // TODO: Phase 2 - Implement GPMF parsing
        // TODO: Phase 3 - Implement speed analysis
        // TODO: Phase 4 - Implement highlight extraction
        // TODO: Phase 5 - Implement max speed extraction
        // TODO: Phase 6 - Implement overlays
        // TODO: Phase 7 - Implement piste identification
        // TODO: Phase 8 - Implement video stitching

        // Simulate processing
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        progress.updateProgress(phase: .completed, progress: 1.0)
        progress.addLog("Processing placeholder completed", level: .success)
        isProcessing = false
    }

    // MARK: - Export CSV
    func exportCSV(to url: URL) async {
        progress.addLog("Exporting CSV to: \(url.lastPathComponent)")

        // This will be implemented in Phase 3
        progress.addLog("CSV export not yet implemented")
    }

    // MARK: - Clear Videos
    func clearVideos() {
        videos.removeAll()
        selectedFolderURL = nil
        progress.reset()
        progress.addLog("Cleared all videos")
    }
}
