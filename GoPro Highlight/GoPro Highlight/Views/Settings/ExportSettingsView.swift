//
//  ExportSettingsView.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import SwiftUI

struct ExportSettingsView: View {
    @Binding var settings: ExportSettings.OutputSettings
    @State private var showOutputDirectoryError = false
    @State private var outputDirectoryErrorMessage = ""

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
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Preserve original encoding when no overlays are applied (Passthrough)", isOn: $settings.preferPassthroughWhenNoOverlays)
                        .toggleStyle(.checkbox)

                    if settings.preferPassthroughWhenNoOverlays {
                        Text("Individual clips without overlays are exported without re-encoding when supported. Stitched output and overlayed clips are re-encoded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("All exports will be re-encoded, including clips without overlays.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 120)
            }

            HStack {
                Text("Format:")
                    .frame(width: 120, alignment: .leading)
                Text("MP4")
                    .foregroundStyle(.secondary)
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

            HStack(alignment: .top) {
                Text("Piste Naming:")
                    .frame(width: 120, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Identify ski piste/resort for output filenames", isOn: $settings.includePisteInFilenames)
                        .toggleStyle(.checkbox)
                    Text("When disabled, filenames will not include piste/resort tokens.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                        _ = settings.setOutputDirectory(nil)
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
        .alert("Output Folder Warning", isPresented: $showOutputDirectoryError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(outputDirectoryErrorMessage)
        }
    }

    private var outputModeDescription: String {
        switch settings.outputMode {
        case .individual:
            return "Each highlight or max speed segment will be exported as a separate video file."
        case .stitched:
            return "All segments will be combined into a single video file. Stitched export is always re-encoded."
        case .both:
            return "Creates individual segment files AND a single stitched video containing all segments. The stitched file is always re-encoded."
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
                let stored = settings.setOutputDirectory(url)
                if !stored {
                    outputDirectoryErrorMessage = "Selected folder was saved for this session, but persistent access could not be stored. Please re-select the folder if needed after restarting the app."
                    showOutputDirectoryError = true
                }
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
