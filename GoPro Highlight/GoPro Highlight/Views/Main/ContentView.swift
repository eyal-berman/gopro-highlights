//
//  ContentView.swift
//  GoPro Highlight
//
//  Created by Eyal Berman on 06/02/2026.
//

import SwiftUI

struct ContentView: View {
    @State private var viewModel = VideoProcessorViewModel()
    @State private var settingsViewModel = SettingsViewModel()
    @State private var selectedTab: Tab = .videos

    enum Tab {
        case videos
        case settings
        case processing
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
                }
            }
        }
        .onAppear {
            viewModel.settings = settingsViewModel.settings
        }
        .onChange(of: settingsViewModel.settings) {
            viewModel.settings = settingsViewModel.settings
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
                }

                Button(action: { viewModel.selectFolder() }) {
                    Label("Select Folder", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
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

#Preview {
    ContentView()
        .frame(width: 900, height: 600)
}
