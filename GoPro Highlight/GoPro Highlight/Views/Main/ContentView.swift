//
//  ContentView.swift
//  GoPro Highlight
//
//  Created by Eyal Berman on 06/02/2026.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var viewModel = VideoProcessorViewModel()
    @State private var settingsViewModel = SettingsViewModel()
    @State private var selectedTab: Tab = .videos
    @State private var showBugReportSheet = false

    enum Tab {
        case videos
        case settings
        case processing
        case help
    }

    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(selection: $selectedTab) {
                Label("Videos", systemImage: "film.stack")
                    .tag(Tab.videos)

                Label("Settings", systemImage: "gearshape")
                    .tag(Tab.settings)

                Label("Processing", systemImage: "waveform.circle")
                    .tag(Tab.processing)

                Label("Help", systemImage: "questionmark.circle")
                    .tag(Tab.help)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 250)
        } detail: {
            // Main content
            Group {
                switch selectedTab {
                case .videos:
                    VideosTabView(viewModel: viewModel)
                case .settings:
                    SettingsTabView(settingsViewModel: settingsViewModel, mainViewModel: viewModel)
                case .processing:
                    ProcessingTabView(viewModel: viewModel)
                case .help:
                    HelpTabView(openBugReporter: { showBugReportSheet = true })
                }
            }
        }
        .onAppear {
            viewModel.settings = settingsViewModel.settings
        }
        .onChange(of: settingsViewModel.settings) {
            viewModel.settings = settingsViewModel.settings
        }
        .onChange(of: viewModel.isAwaitingPreProcessingDecision) { _, isAwaiting in
            if isAwaiting {
                selectedTab = .processing
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openHelpCenter)) { _ in
            selectedTab = .help
        }
        .onReceive(NotificationCenter.default.publisher(for: .openBugReporter)) { _ in
            selectedTab = .help
            showBugReportSheet = true
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.isAwaitingPreProcessingDecision },
                set: { isPresented in
                    if !isPresented && viewModel.isAwaitingPreProcessingDecision {
                        viewModel.cancelPreProcessingDecision()
                    }
                }
            )
        ) {
            PreProcessingReviewSheet(viewModel: viewModel)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showBugReportSheet) {
            BugReportSheet(viewModel: viewModel)
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") {
                viewModel.showError = false
            }
        } message: {
            Text(viewModel.errorMessage)
        }
    }
}

// MARK: - Videos Tab
struct VideosTabView: View {
    @Bindable var viewModel: VideoProcessorViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("GoPro Videos")
                    .font(.title)
                    .fontWeight(.bold)

                Spacer()

                if viewModel.hasVideos {
                    Button(action: { viewModel.clearVideos() }) {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.isProcessing)
                }

                Button(action: { viewModel.selectFolder() }) {
                    Label("Select Folder", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isProcessing)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Content
            if viewModel.hasVideos {
                VideoListView(viewModel: viewModel)
            } else {
                EmptyStateView(viewModel: viewModel)
            }
        }
    }
}

// MARK: - Empty State
struct EmptyStateView: View {
    let viewModel: VideoProcessorViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "film.stack.fill")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)

            Text("No Videos Loaded")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Select a folder containing GoPro MP4 files to begin")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: { viewModel.selectFolder() }) {
                Label("Select Folder", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isProcessing)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Video List
struct VideoListView: View {
    @Bindable var viewModel: VideoProcessorViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Summary
            HStack {
                Text("\(viewModel.videos.count) video(s)")
                    .font(.headline)

                Spacer()

                Button(viewModel.isProcessing ? "Stop Processing" : "Start Processing") {
                    if viewModel.isProcessing {
                        viewModel.stopProcessing()
                    } else {
                        viewModel.beginProcessing()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.isProcessing ? .red : .accentColor)
                .disabled(!viewModel.hasVideos && !viewModel.isProcessing)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Video list
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(viewModel.videos) { video in
                        VideoRowView(video: video)
                    }
                }
            }
        }
    }
}

// MARK: - Video Row
struct VideoRowView: View {
    let video: GoProVideo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 44, height: 44)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(video.filename)
                    .font(.body)
                    .fontWeight(.medium)

                HStack(spacing: 12) {
                    Label(formatFileSize(video.fileSize), systemImage: "doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if video.highlights.count > 0 {
                        Label("\(video.highlights.count) highlights", systemImage: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
            }

            Spacer()

            StatusBadge(status: video.processingStatus)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Status Badge
struct StatusBadge: View {
    let status: ProcessingStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(status.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.1))
        .clipShape(Capsule())
    }

    private var statusColor: Color {
        switch status {
        case .pending: return .gray
        case .parsing, .analyzing, .exporting: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Settings Tab
struct SettingsTabView: View {
    @Bindable var settingsViewModel: SettingsViewModel
    let mainViewModel: VideoProcessorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings")
                    .font(.title)
                    .fontWeight(.bold)
                    .padding(.horizontal)
                    .padding(.top)

                if mainViewModel.isProcessing {
                    Label("Settings are locked while processing is running.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                }

                VStack(spacing: 16) {
                    SettingsSection(title: "Highlight Extraction", icon: "star.fill") {
                        HighlightSettingsView(settings: $settingsViewModel.settings.highlightSettings)
                    }

                    SettingsSection(title: "Max Speed Videos", icon: "speedometer") {
                        MaxSpeedSettingsView(settings: $settingsViewModel.settings.maxSpeedSettings)
                    }

                    SettingsSection(title: "Video Overlays", icon: "square.stack.3d.up") {
                        OverlaySettingsView(settings: $settingsViewModel.settings.overlaySettings)
                    }

                    SettingsSection(title: "Export Options", icon: "square.and.arrow.up") {
                        ExportSettingsView(settings: $settingsViewModel.settings.outputSettings)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .onChange(of: settingsViewModel.settings) {
            settingsViewModel.saveSettings()
            mainViewModel.settings = settingsViewModel.settings
        }
        .disabled(mainViewModel.isProcessing)
    }
}

// MARK: - Settings Section
struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)

            content
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Processing Tab
struct ProcessingTabView: View {
    @Bindable var viewModel: VideoProcessorViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Processing")
                    .font(.title)
                    .fontWeight(.bold)

                Spacer()

                if viewModel.isProcessing {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Progress content
            ProcessingProgressView(progress: viewModel.progress)
        }
    }
}

// MARK: - Processing Progress View
struct ProcessingProgressView: View {
    @Bindable var progress: ProcessingProgress

    var body: some View {
        VStack(spacing: 20) {
            if progress.isProcessing || !progress.logs.isEmpty {
                // Progress bar
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(progress.currentPhase.rawValue)
                            .font(.headline)

                        Spacer()

                        Text("\(Int(progress.overallProgress * 100))%")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: progress.overallProgress)
                        .progressViewStyle(.linear)

                    if !progress.currentFile.isEmpty {
                        Text(progress.currentFile)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Logs
                VStack(alignment: .leading, spacing: 8) {
                    Text("Activity Log")
                        .font(.headline)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(progress.logs) { log in
                                LogEntryView(entry: log)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            } else {
                // Empty state
                VStack(spacing: 16) {
                    Image(systemName: "waveform.circle")
                        .font(.system(size: 72))
                        .foregroundStyle(.secondary)

                    Text("No processing activity")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Start processing from the Videos tab")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
    }
}

// MARK: - Help Tab
struct HelpTabView: View {
    let openBugReporter: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("How To Use Each Feature")
                    .font(.title)
                    .fontWeight(.bold)

                HelpFeatureSection(
                    title: "1. Load Videos",
                    icon: "folder",
                    steps: [
                        "Open the Videos tab and click Select Folder.",
                        "Pick a folder that contains your GoPro MP4 or MOV files.",
                        "Confirm the loaded files and statuses in the list."
                    ]
                )

                HelpFeatureSection(
                    title: "2. Highlight Extraction",
                    icon: "star.fill",
                    steps: [
                        "In Settings, set seconds before and after each highlight.",
                        "Enable merge overlapping if you want fewer, longer clips.",
                        "Start processing to create highlight segments."
                    ]
                )

                HelpFeatureSection(
                    title: "3. Max Speed Videos",
                    icon: "speedometer",
                    steps: [
                        "Enable Extract max speed videos.",
                        "Set Top N to choose how many fastest source videos to export.",
                        "Set timing before and after peak speed."
                    ]
                )

                HelpFeatureSection(
                    title: "4. Overlays",
                    icon: "square.stack.3d.up",
                    steps: [
                        "Enable speed gauge, date/time, and optional piste details.",
                        "Adjust style, size, position, and opacity.",
                        "Enable per-feature include overlay toggles to render overlays on export."
                    ]
                )

                HelpFeatureSection(
                    title: "5. Export Options",
                    icon: "square.and.arrow.up",
                    steps: [
                        "Choose quality and output format.",
                        "Select output mode: individual, stitched, or both.",
                        "Optionally choose a dedicated output directory."
                    ]
                )

                HelpFeatureSection(
                    title: "6. Processing and Results",
                    icon: "waveform.circle",
                    steps: [
                        "Click Start Processing in the Videos tab.",
                        "Monitor progress and logs in the Processing tab.",
                        "Review exported clips, stitched output, and CSV report in the output folder."
                    ]
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("Need Help?")
                        .font(.headline)
                    Text("If processing fails or output looks wrong, send a bug report with diagnostics.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(action: openBugReporter) {
                        Label("Report a Bug", systemImage: "ladybug")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding()
        }
    }
}

struct HelpFeatureSection: View {
    let title: String
    let icon: String
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            ForEach(Array(steps.enumerated()), id: \.offset) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.caption)
                        .padding(.top, 2)
                    Text(entry.element)
                        .font(.body)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Pre-Processing Review Sheet
struct PreProcessingReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: VideoProcessorViewModel
    @State private var selectedQuality: ExportSettings.OutputSettings.ExportQuality = .high

    var body: some View {
        Group {
            if let summary = viewModel.preProcessingSummary,
               let estimate = viewModel.preProcessingEstimate(for: selectedQuality) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Pre-Processing Review")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Found \(summary.moviesWithHighlights) movies with highlights out of \(summary.totalMovies) movies. Total clip time is \(formatDuration(summary.totalClipDurationSeconds)).")
                        .font(.body)

                    Text("Estimated file size for standalone files / stitched file / total created files:")
                        .font(.headline)

                    Text("\(VideoProcessorViewModel.formatBytes(estimate.standaloneBytes)) / \(VideoProcessorViewModel.formatBytes(estimate.stitchedBytes)) / \(VideoProcessorViewModel.formatBytes(estimate.totalOutputBytes))")
                        .font(.body)

                    Text("Estimated output files: \(estimate.outputFileCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(viewModel.preProcessingEncodingDescription(for: selectedQuality))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !summary.anyOverlayLayerEnabled {
                        Text("No overlay layers are enabled, so passthrough can apply on eligible original-quality clips.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Planned max-speed output clips: \(summary.plannedMaxSpeedClipCount) (Top \(summary.requestedMaxSpeedTopN), candidate videos: \(summary.maxSpeedCandidateCount)).")
                        .font(.headline)
                    Text("Estimated max-speed clip length: \(formatDuration(summary.maxSpeedClipDurationSeconds)) each.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Pre-processing is highlights-first: piste detection and detailed max-speed ranking run only after you continue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    HStack {
                        Text("Quality:")
                        Picker("Quality", selection: $selectedQuality) {
                            ForEach(ExportSettings.OutputSettings.ExportQuality.allCases, id: \.self) { quality in
                                let fitText = viewModel.preProcessingHasEnoughDiskSpace(for: quality) ? "fits" : "no space"
                                Text("\(quality.rawValue) (\(fitText))").tag(quality)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    if let recommended = summary.recommendedQuality {
                        Text("Recommended quality based on free space: \(recommended.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Estimated processing time: \(formatDuration(estimate.estimatedProcessingTimeSeconds))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let available = summary.availableDiskBytes {
                            Text("Free space: \(VideoProcessorViewModel.formatBytes(available))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !viewModel.preProcessingHasEnoughDiskSpace(for: selectedQuality) {
                        Label("Not enough free space for selected quality. Choose a lower quality or free disk space.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack {
                        Button("Exit Now") {
                            viewModel.cancelPreProcessingDecision()
                            dismiss()
                        }
                        Spacer()
                        Button("Continue Processing") {
                            viewModel.continuePreProcessing(with: selectedQuality)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.preProcessingHasEnoughDiskSpace(for: selectedQuality))
                    }
                }
                .padding(20)
                .frame(minWidth: 760, minHeight: 560)
                .onAppear {
                    selectedQuality = summary.recommendedQuality ?? summary.defaultQuality
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Preparing pre-processing review...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 480, minHeight: 200)
                .padding()
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

// MARK: - Bug Report Sheet
struct BugReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: VideoProcessorViewModel
    @State private var issueDescription = ""
    @State private var statusMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Report a Bug")
                .font(.title2)
                .fontWeight(.bold)

            Text("Describe what happened. Diagnostics and recent logs will be included automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $issueDescription)
                .frame(minHeight: 140)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Copy Report") {
                    let report = viewModel.buildBugReport(userDescription: issueDescription)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    statusMessage = "Bug report copied to clipboard."
                }

                Button("Save Report...") {
                    let panel = NSSavePanel()
                    panel.title = "Save Bug Report"
                    panel.allowedContentTypes = [.plainText]
                    panel.canCreateDirectories = true
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyyMMdd_HHmmss"
                    panel.nameFieldStringValue = "GoProHighlight_BugReport_\(formatter.string(from: Date())).txt"

                    guard panel.runModal() == .OK, let url = panel.url else { return }

                    do {
                        let report = viewModel.buildBugReport(userDescription: issueDescription)
                        try report.write(to: url, atomically: true, encoding: .utf8)
                        statusMessage = "Saved bug report to \(url.lastPathComponent)."
                    } catch {
                        statusMessage = "Failed to save bug report: \(error.localizedDescription)"
                    }
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 360)
    }
}

// MARK: - Log Entry View
struct LogEntryView: View {
    let entry: ProcessingProgress.LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(iconColor)
                .frame(width: 16)

            Text(entry.formattedTimestamp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(entry.message)
                .font(.caption)
                .foregroundStyle(textColor)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var iconName: String {
        switch entry.level {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.circle"
        case .success: return "checkmark.circle"
        }
    }

    private var iconColor: Color {
        switch entry.level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }

    private var textColor: Color {
        switch entry.level {
        case .error: return .red
        default: return .primary
        }
    }

    private var backgroundColor: Color {
        switch entry.level {
        case .error: return .red.opacity(0.05)
        case .warning: return .orange.opacity(0.05)
        case .success: return .green.opacity(0.05)
        default: return Color(nsColor: .controlBackgroundColor)
        }
    }
}

extension Notification.Name {
    static let openHelpCenter = Notification.Name("GoProHighlight.OpenHelpCenter")
    static let openBugReporter = Notification.Name("GoProHighlight.OpenBugReporter")
}

#Preview {
    ContentView()
        .frame(width: 900, height: 600)
}
