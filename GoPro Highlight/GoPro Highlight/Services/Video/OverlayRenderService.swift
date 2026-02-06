//
//  OverlayRenderService.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreGraphics
@preconcurrency import QuartzCore
@preconcurrency import AppKit
import CoreText

/// Service for rendering overlays (speed gauge, date/time) onto videos
actor OverlayRenderService {
    private var currentExportSession: AVAssetExportSession?

    /// Renders overlays onto a video
    func renderOverlays(
        inputURL: URL,
        outputURL: URL,
        telemetry: Telemetry?,
        videoStartDate: Date?,
        overlaySettings: ExportSettings.OverlaySettings,
        quality: ExportSettings.OutputSettings.ExportQuality,
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async throws {
        let asset = AVAsset(url: inputURL)

        guard try await asset.load(.isReadable) else {
            throw OverlayError.assetNotReadable
        }

        // Create composition
        let composition = AVMutableComposition()
        let videoComposition = AVMutableVideoComposition()

        // Get video track
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw OverlayError.noVideoTrack
        }

        // Add video track to composition
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw OverlayError.trackCreationFailed
        }

        let duration = try await asset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)

        try compositionVideoTrack.insertTimeRange(
            timeRange,
            of: videoTrack,
            at: .zero
        )

        // Add audio track if present
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw OverlayError.trackCreationFailed
            }

            try compositionAudioTrack.insertTimeRange(
                timeRange,
                of: audioTrack,
                at: .zero
            )
        }

        // Get video properties
        let videoSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let actualSize = videoSize.applying(transform)

        // Setup video composition
        videoComposition.renderSize = CGSize(
            width: abs(actualSize.width),
            height: abs(actualSize.height)
        )
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30) // 30fps

        // Create overlay layers
        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: videoComposition.renderSize)
        videoLayer.frame = CGRect(origin: .zero, size: videoComposition.renderSize)
        parentLayer.addSublayer(videoLayer)

        // Add speed gauge overlay if enabled
        if overlaySettings.speedGaugeEnabled, let telemetry = telemetry {
            let gaugeLayer = try createSpeedGaugeLayer(
                size: videoComposition.renderSize,
                telemetry: telemetry,
                settings: overlaySettings,
                duration: duration
            )
            parentLayer.addSublayer(gaugeLayer)
        }

        // Add date/time overlay if enabled
        if overlaySettings.dateTimeEnabled {
            let dateTimeLayer = createDateTimeLayer(
                size: videoComposition.renderSize,
                settings: overlaySettings,
                videoStartDate: videoStartDate ?? Date()
            )
            parentLayer.addSublayer(dateTimeLayer)
        }

        // Create animation tool
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        // Create instruction
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timeRange

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        layerInstruction.setTransform(transform, at: .zero)

        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // Export with overlays
        try await exportWithComposition(
            composition: composition,
            videoComposition: videoComposition,
            outputURL: outputURL,
            quality: quality,
            onProgress: onProgress
        )
    }

    // MARK: - Speed Gauge Layer

    private func createSpeedGaugeLayer(
        size: CGSize,
        telemetry: Telemetry,
        settings: ExportSettings.OverlaySettings,
        duration: CMTime
    ) throws -> CALayer {
        let gaugeSize: CGFloat = 200
        let position = calculatePosition(for: settings.gaugePosition, in: size, overlaySize: gaugeSize)

        let gaugeLayer = CALayer()
        gaugeLayer.frame = CGRect(x: position.x - gaugeSize/2, y: position.y - gaugeSize/2, width: gaugeSize, height: gaugeSize)
        gaugeLayer.opacity = Float(settings.gaugeOpacity)

        // Create gauge background
        let backgroundLayer = CAShapeLayer()
        backgroundLayer.frame = CGRect(x: 0, y: 0, width: gaugeSize, height: gaugeSize)

        // Semi-circular gauge path
        let center = CGPoint(x: gaugeSize / 2, y: gaugeSize / 2)
        let radius = gaugeSize * 0.4

        let gaugePath = CGMutablePath()
        gaugePath.addArc(center: center, radius: radius, startAngle: .pi, endAngle: 0, clockwise: false)

        backgroundLayer.path = gaugePath
        backgroundLayer.strokeColor = NSColor.white.withAlphaComponent(0.3).cgColor
        backgroundLayer.fillColor = NSColor.clear.cgColor
        backgroundLayer.lineWidth = 20

        gaugeLayer.addSublayer(backgroundLayer)

        // Create animated speed indicator layer
        // This is a simplified version - full implementation would animate based on telemetry
        let needleLayer = CAShapeLayer()
        needleLayer.frame = backgroundLayer.frame

        // TODO: Animate needle based on speed samples over time
        // For now, show the peak speed in the segment.
        let peakSpeedMps = telemetry.speedSamples.map(\.speed).max() ?? 0
        let peakSpeedDisplay = settings.speedUnits == .mph ? peakSpeedMps * 2.23694 : peakSpeedMps * 3.6
        let maxDisplaySpeed = max(settings.maxSpeed, 1)
        let normalizedSpeed = min(max(peakSpeedDisplay / maxDisplaySpeed, 0), 1)
        let angle = CGFloat(.pi - normalizedSpeed * .pi)

        let needlePath = CGMutablePath()
        needlePath.move(to: center)
        needlePath.addLine(to: CGPoint(
            x: center.x + cos(angle) * radius * 0.8,
            y: center.y - sin(angle) * radius * 0.8
        ))

        needleLayer.path = needlePath
        needleLayer.strokeColor = NSColor.systemBlue.cgColor
        needleLayer.lineWidth = 4
        needleLayer.lineCap = .round

        gaugeLayer.addSublayer(needleLayer)

        // Add speed text
        let speedTextLayer = CATextLayer()
        speedTextLayer.frame = CGRect(x: 0, y: gaugeSize * 0.6, width: gaugeSize, height: 40)
        speedTextLayer.string = String(format: "%.0f", peakSpeedDisplay)
        speedTextLayer.font = NSFont.boldSystemFont(ofSize: 32)
        speedTextLayer.fontSize = 32
        speedTextLayer.foregroundColor = NSColor.white.cgColor
        speedTextLayer.alignmentMode = .center
        speedTextLayer.contentsScale = 2.0 // Retina

        gaugeLayer.addSublayer(speedTextLayer)

        // Add unit label
        let unitLabel = CATextLayer()
        unitLabel.frame = CGRect(x: 0, y: gaugeSize * 0.7, width: gaugeSize, height: 20)
        unitLabel.string = settings.speedUnits.rawValue
        unitLabel.fontSize = 14
        unitLabel.foregroundColor = NSColor.white.withAlphaComponent(0.7).cgColor
        unitLabel.alignmentMode = .center
        unitLabel.contentsScale = 2.0

        gaugeLayer.addSublayer(unitLabel)

        return gaugeLayer
    }

    // MARK: - Date/Time Layer

    private func createDateTimeLayer(
        size: CGSize,
        settings: ExportSettings.OverlaySettings,
        videoStartDate: Date
    ) -> CALayer {
        let dateTimeText = settings.dateTimeFormat.format(date: videoStartDate)
        let font = NSFont.systemFont(ofSize: settings.dateTimeFontSize, weight: .medium)

        // Calculate text size
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (dateTimeText as NSString).size(withAttributes: attributes)

        // Add padding
        let padding: CGFloat = 16
        let layerWidth = max(80, textSize.width + padding * 2)
        let layerHeight = max(30, textSize.height + padding)

        // Calculate position
        let position = calculatePosition(
            for: settings.dateTimePosition,
            in: size,
            overlaySize: max(layerWidth, layerHeight)
        )

        let containerFrame = CGRect(
            x: position.x - layerWidth / 2,
            y: position.y - layerHeight / 2,
            width: layerWidth,
            height: layerHeight
        )

        // Add background
        let backgroundLayer = CALayer()
        backgroundLayer.frame = CGRect(origin: .zero, size: containerFrame.size)
        backgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        backgroundLayer.cornerRadius = 8

        let textLayer = CALayer()
        textLayer.frame = CGRect(origin: .zero, size: containerFrame.size).insetBy(dx: padding, dy: padding / 2)
        textLayer.contentsGravity = .center
        textLayer.contentsScale = 2.0
        if let textImage = makeTextImage(
            text: dateTimeText,
            fontName: font.fontName,
            fontSize: CGFloat(settings.dateTimeFontSize),
            color: NSColor.white,
            canvasSize: textLayer.bounds.size
        ) {
            textLayer.contents = textImage
        }

        backgroundLayer.opacity = Float(settings.dateTimeOpacity)
        textLayer.opacity = Float(settings.dateTimeOpacity)

        // Container
        let container = CALayer()
        container.frame = containerFrame
        container.addSublayer(backgroundLayer)
        container.addSublayer(textLayer)

        return container
    }

    private func makeTextImage(
        text: String,
        fontName: String,
        fontSize: CGFloat,
        color: NSColor,
        canvasSize: CGSize
    ) -> CGImage? {
        let width = max(Int(canvasSize.width * 2.0), 1)
        let height = max(Int(canvasSize.height * 2.0), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(NSColor.clear.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)

        let ctFont = CTFontCreateWithName(fontName as CFString, fontSize * 2.0, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): color.cgColor
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)

        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds, .excludeTypographicLeading])
        let x = max((CGFloat(width) - bounds.width) / 2.0 - bounds.origin.x, 0)
        let y = max((CGFloat(height) - bounds.height) / 2.0 - bounds.origin.y, 0)

        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)

        return context.makeImage()
    }

    // MARK: - Helper Methods

    private func calculatePosition(
        for position: ExportSettings.OverlaySettings.OverlayPosition,
        in videoSize: CGSize,
        overlaySize: CGFloat
    ) -> CGPoint {
        let alignment = position.alignment
        let margin: CGFloat = 40

        let x: CGFloat
        if alignment.horizontal < 0.3 {
            x = margin + overlaySize / 2
        } else if alignment.horizontal > 0.7 {
            x = videoSize.width - margin - overlaySize / 2
        } else {
            x = videoSize.width / 2
        }

        let y: CGFloat
        if alignment.vertical < 0.3 {
            y = videoSize.height - margin - overlaySize / 2
        } else if alignment.vertical > 0.7 {
            y = margin + overlaySize / 2
        } else {
            y = videoSize.height / 2
        }

        return CGPoint(x: x, y: y)
    }

    private func exportWithComposition(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        outputURL: URL,
        quality: ExportSettings.OutputSettings.ExportQuality,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        // Remove existing file
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // Passthrough does not apply videoComposition, so force a re-encode preset for overlays.
        let presetName = quality == .original ? AVAssetExportPresetHighestQuality : quality.avPreset

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: presetName
        ) else {
            throw OverlayError.exportSessionCreationFailed
        }
        currentExportSession = exportSession

        exportSession.outputURL = outputURL
        let preferredFileType = preferredOutputFileType(for: outputURL)
        if exportSession.supportedFileTypes.contains(preferredFileType) {
            exportSession.outputFileType = preferredFileType
        } else if let fallbackFileType = exportSession.supportedFileTypes.first {
            exportSession.outputFileType = fallbackFileType
        } else {
            throw OverlayError.exportFailed("No supported output file type for overlay export")
        }
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = true

        // Monitor progress with Task
        let progressTask = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                let progress = await currentExportProgress()
                await MainActor.run {
                    onProgress(progress)
                }
            }
        }

        await withTaskCancellationHandler(
            operation: {
                await runCurrentExport()
            },
            onCancel: {
                Task { [self] in
                    await cancelCurrentExport()
                }
            }
        )

        progressTask.cancel()
        currentExportSession = nil

        if let error = exportSession.error {
            throw OverlayError.exportFailed(error.localizedDescription)
        }

        guard exportSession.status == .completed else {
            throw OverlayError.exportFailed("Export did not complete")
        }
    }

    private func runCurrentExport() async {
        await currentExportSession?.export()
    }

    private func cancelCurrentExport() {
        currentExportSession?.cancelExport()
    }

    private func currentExportProgress() -> Double {
        Double(currentExportSession?.progress ?? 0)
    }

    private func preferredOutputFileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mov":
            return .mov
        default:
            return .mp4
        }
    }
}

// MARK: - Errors
enum OverlayError: LocalizedError {
    case assetNotReadable
    case noVideoTrack
    case trackCreationFailed
    case exportSessionCreationFailed
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .assetNotReadable:
            return "Video file could not be read"
        case .noVideoTrack:
            return "No video track found"
        case .trackCreationFailed:
            return "Failed to create composition track"
        case .exportSessionCreationFailed:
            return "Failed to create export session"
        case .exportFailed(let message):
            return "Overlay rendering failed: \(message)"
        }
    }
}
