//
//  MaxSpeedSettingsView.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import SwiftUI

struct MaxSpeedSettingsView: View {
    @Binding var settings: ExportSettings.MaxSpeedSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Extract max speed videos", isOn: $settings.enabled)
                .fontWeight(.medium)

            if settings.enabled {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Number of top speed videos:")
                            .frame(width: 200, alignment: .leading)

                        Stepper("\(settings.topN)", value: $settings.topN, in: 1...10)
                            .frame(width: 100)
                    }

                    HStack {
                        Text("Seconds before max speed:")
                            .frame(width: 200, alignment: .leading)

                        TextField("", value: $settings.beforeSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)

                        Text("seconds")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Seconds after max speed:")
                            .frame(width: 200, alignment: .leading)

                        TextField("", value: $settings.afterSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)

                        Text("seconds")
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Include overlays on max speed videos", isOn: $settings.includeOverlay)

                    Divider()

                    Text("Will extract the top \(settings.topN) video(s) with the highest recorded speed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 20)
            }
        }
    }
}

#Preview {
    @Previewable @State var settings = ExportSettings.MaxSpeedSettings()

    return MaxSpeedSettingsView(settings: $settings)
        .padding()
        .frame(width: 500)
}
