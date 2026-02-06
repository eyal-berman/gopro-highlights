//
//  HighlightSettingsView.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import SwiftUI

struct HighlightSettingsView: View {
    @Binding var settings: ExportSettings.HighlightSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Seconds before highlight:")
                    .frame(width: 180, alignment: .leading)

                TextField("", value: $settings.beforeSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)

                Text("seconds")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Seconds after highlight:")
                    .frame(width: 180, alignment: .leading)

                TextField("", value: $settings.afterSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)

                Text("seconds")
                    .foregroundStyle(.secondary)
            }

            Toggle("Merge overlapping segments", isOn: $settings.mergeOverlapping)

            Toggle("Include overlays on highlight videos", isOn: $settings.includeOverlay)

            Divider()

            Text("Segments will be extracted from (highlight time - \(Int(settings.beforeSeconds))s) to (highlight time + \(Int(settings.afterSeconds))s)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    @Previewable @State var settings = ExportSettings.HighlightSettings()

    return HighlightSettingsView(settings: $settings)
        .padding()
        .frame(width: 500)
}
