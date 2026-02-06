//
//  OverlaySettingsView.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import SwiftUI

struct OverlaySettingsView: View {
    @Binding var settings: ExportSettings.OverlaySettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Speed Gauge Section
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Speed Gauge Overlay", isOn: $settings.speedGaugeEnabled)
                    .fontWeight(.medium)

                if settings.speedGaugeEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Gauge Style:")
                                .frame(width: 140, alignment: .leading)

                            Picker("", selection: $settings.gaugeStyle) {
                                ForEach(ExportSettings.OverlaySettings.GaugeStyle.allCases, id: \.self) { style in
                                    Text(style.rawValue).tag(style)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        HStack {
                            Text("Max Speed:")
                                .frame(width: 140, alignment: .leading)

                            TextField("", value: $settings.maxSpeed, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)

                            Picker("", selection: $settings.speedUnits) {
                                ForEach(ExportSettings.OverlaySettings.SpeedUnit.allCases, id: \.self) { unit in
                                    Text(unit.rawValue).tag(unit)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 120)
                        }

                        HStack {
                            Text("Position:")
                                .frame(width: 140, alignment: .leading)

                            Picker("", selection: $settings.gaugePosition) {
                                ForEach(ExportSettings.OverlaySettings.OverlayPosition.allCases, id: \.self) { position in
                                    Text(position.rawValue).tag(position)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        HStack {
                            Text("Opacity:")
                                .frame(width: 140, alignment: .leading)

                            Slider(value: $settings.gaugeOpacity, in: 0.3...1.0)
                                .frame(width: 150)

                            Text("\(Int(settings.gaugeOpacity * 100))%")
                                .frame(width: 40, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 20)
                }
            }

            Divider()

            // Date/Time Section
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Date/Time Overlay", isOn: $settings.dateTimeEnabled)
                    .fontWeight(.medium)

                if settings.dateTimeEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Format:")
                                .frame(width: 140, alignment: .leading)

                            Picker("", selection: $settings.dateTimeFormat) {
                                ForEach(ExportSettings.OverlaySettings.DateTimeFormat.allCases, id: \.self) { format in
                                    Text(format.rawValue).tag(format)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        HStack {
                            Text("Position:")
                                .frame(width: 140, alignment: .leading)

                            Picker("", selection: $settings.dateTimePosition) {
                                ForEach(ExportSettings.OverlaySettings.OverlayPosition.allCases, id: \.self) { position in
                                    Text(position.rawValue).tag(position)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        HStack {
                            Text("Font Size:")
                                .frame(width: 140, alignment: .leading)

                            Slider(value: $settings.dateTimeFontSize, in: 12...72, step: 2)
                                .frame(width: 150)

                            Text("\(Int(settings.dateTimeFontSize))pt")
                                .frame(width: 40, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Opacity:")
                                .frame(width: 140, alignment: .leading)

                            Slider(value: $settings.dateTimeOpacity, in: 0.3...1.0)
                                .frame(width: 150)

                            Text("\(Int(settings.dateTimeOpacity * 100))%")
                                .frame(width: 40, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        }

                        // Preview
                        HStack {
                            Text("Preview:")
                                .frame(width: 140, alignment: .leading)

                            Text(settings.dateTimeFormat.format(date: Date()))
                                .font(.system(size: settings.dateTimeFontSize * 0.5))
                                .opacity(settings.dateTimeOpacity)
                                .padding(8)
                                .background(Color.black.opacity(0.5))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.leading, 20)
                }
            }

            if settings.speedGaugeEnabled || settings.dateTimeEnabled {
                Divider()

                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)

                    Text("Overlays will be rendered onto the exported videos. This will increase processing time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var settings = ExportSettings.OverlaySettings()
    settings.speedGaugeEnabled = true
    settings.dateTimeEnabled = true

    return ScrollView {
        OverlaySettingsView(settings: $settings)
            .padding()
    }
    .frame(width: 600, height: 700)
}
