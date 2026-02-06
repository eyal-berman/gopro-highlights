//
//  ProcessingProgress.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import Foundation
import Observation

/// Tracks the progress of video processing operations
@Observable
class ProcessingProgress {
    var currentPhase: Phase = .idle
    var overallProgress: Double = 0.0
    var currentFile: String = ""
    var filesCompleted: Int = 0
    var totalFiles: Int = 0
    var estimatedTimeRemaining: TimeInterval?
    var logs: [LogEntry] = []
    var isProcessing: Bool = false

    enum Phase: String {
        case idle = "Idle"
        case parsing = "Parsing Metadata"
        case analyzing = "Analyzing Speed Data"
        case identifyingPistes = "Identifying Ski Pistes"
        case extracting = "Extracting Segments"
        case rendering = "Rendering Overlays"
        case stitching = "Stitching Videos"
        case exporting = "Exporting"
        case generatingCSV = "Generating CSV Report"
        case completed = "Completed"
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let level: LogLevel

        enum LogLevel {
            case info, warning, error, success
        }

        var formattedTimestamp: String {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            return formatter.string(from: timestamp)
        }
    }

    func addLog(_ message: String, level: LogEntry.LogLevel = .info) {
        let entry = LogEntry(timestamp: Date(), message: message, level: level)
        logs.append(entry)
    }

    func reset() {
        currentPhase = .idle
        overallProgress = 0.0
        currentFile = ""
        filesCompleted = 0
        totalFiles = 0
        estimatedTimeRemaining = nil
        logs.removeAll()
        isProcessing = false
    }

    func updateProgress(phase: Phase, progress: Double, currentFile: String = "") {
        self.currentPhase = phase
        self.overallProgress = progress
        self.currentFile = currentFile
    }
}
