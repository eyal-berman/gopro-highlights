//
//  ExportSettingsView.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import SwiftUI

struct ExportSettingsView: View {
    @Binding var settings: ExportSettings.OutputSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Quality:")
                    .frame(width: 120, alignment: .leading)

                Picker("", selection: $settings.quality) {
                    ForEach(ExportSettings.OutputSettings.ExportQuality.allCases, id: \.self) { quality in
                        Text(quality.rawValue).tag(quality)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
            }

            if settings.quality != .original {
                Text(settings.quality.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 120)
            }

            HStack {
                Text("Format:")
                    .frame(width: 120, alignment: .leading)

                Picker("", selection: $settings.format) {
                    ForEach(ExportSettings.OutputSettings.VideoFormat.allCases, id: \.self) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            HStack {
                Text("Output Mode:")
                    .frame(width: 120, alignment: .leading)

                Picker("", selection: $settings.outputMode) {
                    ForEach(ExportSettings.OutputSettings.OutputMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Output Directory:")
                    .fontWeight(.medium)

                HStack {
                    if let dir = settings.outputDirectory {
                        Text(dir.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Same as source folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Choose...") {
                        selectOutputDirectory()
                    }
                    .buttonStyle(.borderless)
                }

                if settings.outputDirectory != nil {
                    Button("Use Source Folder") {
                        settings.outputDirectory = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            Divider()

            // Info about output mode
            VStack(alignment: .leading, spacing: 4) {
                Text(outputModeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var outputModeDescription: String {
        switch settings.outputMode {
        case .individual:
            return "Each highlight or max speed segment will be exported as a separate video file."
        case .stitched:
            return "All segments will be combined into a single video file."
        case .both:
            return "Creates individual segment files AND a single stitched video containing all segments."
        }
    }

    private func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select output directory"
        panel.prompt = "Select"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                settings.outputDirectory = url
            }
        }
    }
}

#Preview {
    @Previewable @State var settings = ExportSettings.OutputSettings()

    return ExportSettingsView(settings: $settings)
        .padding()
        .frame(width: 500)
}
