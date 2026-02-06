//
//  OverlayRenderService.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import QuartzCore
import AppKit

/// Service for rendering overlays (speed gauge, date/time) onto videos
actor OverlayRenderService {

    /// Renders overlays onto a video
    func renderOverlays(
        inputURL: URL,
        outputURL: URL,
        telemetry: Telemetry?,
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
                videoStartDate: Date() // TODO: Extract from video metadata
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

        let gaugePath = NSBezierPath()
        gaugePath.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 180,
            endAngle: 0,
            clockwise: false
        )

        backgroundLayer.path = gaugePath.cgPath
        backgroundLayer.strokeColor = NSColor.white.withAlphaComponent(0.3).cgColor
        backgroundLayer.fillColor = NSColor.clear.cgColor
        backgroundLayer.lineWidth = 20

        gaugeLayer.addSublayer(backgroundLayer)

        // Create animated speed indicator layer
        // This is a simplified version - full implementation would animate based on telemetry
        let needleLayer = CAShapeLayer()
        needleLayer.frame = backgroundLayer.frame

        // TODO: Animate needle based on speed samples over time
        // For now, create a static needle
        let needlePath = NSBezierPath()
        needlePath.move(to: center)
        needlePath.line(to: CGPoint(x: center.x + radius * 0.8, y: center.y))

        needleLayer.path = needlePath.cgPath
        needleLayer.strokeColor = NSColor.systemBlue.cgColor
        needleLayer.lineWidth = 4
        needleLayer.lineCap = .round

        gaugeLayer.addSublayer(needleLayer)

        // Add speed text
        let speedTextLayer = CATextLayer()
        speedTextLayer.frame = CGRect(x: 0, y: gaugeSize * 0.6, width: gaugeSize, height: 40)
        speedTextLayer.string = "0" // Will be animated
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

        let textLayer = CATextLayer()
        textLayer.string = dateTimeText
        textLayer.fontSize = settings.dateTimeFontSize
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.contentsScale = 2.0 // Retina

        // Calculate text size
        let font = NSFont.systemFont(ofSize: settings.dateTimeFontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (dateTimeText as NSString).size(withAttributes: attributes)

        // Add padding
        let padding: CGFloat = 16
        let layerWidth = textSize.width + padding * 2
        let layerHeight = textSize.height + padding * 2

        // Calculate position
        let position = calculatePosition(
            for: settings.dateTimePosition,
            in: size,
            overlaySize: max(layerWidth, layerHeight)
        )

        textLayer.frame = CGRect(
            x: position.x - layerWidth / 2,
            y: position.y - layerHeight / 2,
            width: layerWidth,
            height: layerHeight
        )

        // Add background
        let backgroundLayer = CALayer()
        backgroundLayer.frame = textLayer.frame
        backgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        backgroundLayer.cornerRadius = 8

        backgroundLayer.opacity = Float(settings.dateTimeOpacity)
        textLayer.opacity = Float(settings.dateTimeOpacity)

        // Container
        let container = CALayer()
        container.addSublayer(backgroundLayer)
        container.addSublayer(textLayer)

        return container
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

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: quality.avPreset
        ) else {
            throw OverlayError.exportSessionCreationFailed
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = true

        // Monitor progress
        let progressTimer = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                onProgress(Double(exportSession.progress))
            }

        await exportSession.export()

        progressTimer.cancel()

        if let error = exportSession.error {
            throw OverlayError.exportFailed(error.localizedDescription)
        }

        guard exportSession.status == .completed else {
            throw OverlayError.exportFailed("Export did not complete")
        }
    }
}

// MARK: - NSBezierPath to CGPath Extension
extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)

        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            @unknown default:
                break
            }
        }

        return path
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
