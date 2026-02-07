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
        pisteInfo: PisteInfoData?,
        videoStartDate: Date?,
        sourceSegmentStartTime: TimeInterval = 0,
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
        let overlayLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: videoComposition.renderSize)
        videoLayer.frame = CGRect(origin: .zero, size: videoComposition.renderSize)
        overlayLayer.frame = CGRect(origin: .zero, size: videoComposition.renderSize)
        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(overlayLayer)

        // Add speed gauge overlay if enabled
        if overlaySettings.speedGaugeEnabled, let telemetry = telemetry {
            let gaugeLayer = createSpeedGaugeLayer(
                size: videoComposition.renderSize,
                telemetry: telemetry,
                settings: overlaySettings,
                duration: duration,
                sourceSegmentStartTime: sourceSegmentStartTime
            )
            overlayLayer.addSublayer(gaugeLayer)
        }

        // Add date/time overlay if enabled
        if overlaySettings.dateTimeEnabled {
            let dateTimeLayer = createDateTimeLayer(
                size: videoComposition.renderSize,
                settings: overlaySettings,
                videoStartDate: videoStartDate ?? Date()
            )
            overlayLayer.addSublayer(dateTimeLayer)
        }

        if overlaySettings.pisteDetailsEnabled, let pisteInfo {
            let pisteLayer = createPisteDetailsLayer(
                size: videoComposition.renderSize,
                settings: overlaySettings,
                pisteInfo: pisteInfo
            )
            overlayLayer.addSublayer(pisteLayer)
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
        duration: CMTime,
        sourceSegmentStartTime: TimeInterval
    ) -> CALayer {
        let clipDuration = max(CMTimeGetSeconds(duration), 0)
        let unitMultiplier = settings.speedUnits == .mph ? 2.23694 : 3.6
        let gaugeScale = max(0.6, min(2.0, settings.gaugeScale))
        let gaugeSize: CGFloat = 220 * CGFloat(gaugeScale)
        let position = calculatePosition(for: settings.gaugePosition, in: size, overlaySize: gaugeSize)
        let center = CGPoint(x: gaugeSize / 2, y: gaugeSize / 2)
        let radius = gaugeSize * 0.42
        let maxDisplaySpeed = max(settings.maxSpeed, 1)

        let gaugeLayer = CALayer()
        gaugeLayer.frame = CGRect(x: position.x - gaugeSize / 2, y: position.y - gaugeSize / 2, width: gaugeSize, height: gaugeSize)
        gaugeLayer.opacity = Float(settings.gaugeOpacity)

        let panelLayer = CAShapeLayer()
        panelLayer.path = CGPath(
            ellipseIn: CGRect(
                x: center.x - radius * 1.05,
                y: center.y - radius * 1.05,
                width: radius * 2.1,
                height: radius * 2.1
            ),
            transform: nil
        )
        panelLayer.fillColor = NSColor.black.withAlphaComponent(0.35).cgColor
        gaugeLayer.addSublayer(panelLayer)

        let trackLayer = CAShapeLayer()
        trackLayer.path = CGPath(
            ellipseIn: CGRect(
                x: center.x - radius * 0.82,
                y: center.y - radius * 0.82,
                width: radius * 1.64,
                height: radius * 1.64
            ),
            transform: nil
        )
        trackLayer.fillColor = NSColor.clear.cgColor
        trackLayer.strokeColor = NSColor.white.withAlphaComponent(0.35).cgColor
        trackLayer.lineWidth = 8
        trackLayer.lineCap = .round
        trackLayer.strokeStart = 0
        trackLayer.strokeEnd = 0.5
        gaugeLayer.addSublayer(trackLayer)

        let needleLayer = CAShapeLayer()
        needleLayer.frame = gaugeLayer.bounds
        needleLayer.fillColor = NSColor.clear.cgColor
        needleLayer.strokeColor = NSColor.systemBlue.cgColor
        needleLayer.lineWidth = 8
        needleLayer.lineCap = .round
        gaugeLayer.addSublayer(needleLayer)

        let hubLayer = CAShapeLayer()
        hubLayer.path = CGPath(
            ellipseIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12),
            transform: nil
        )
        hubLayer.fillColor = NSColor.white.cgColor
        gaugeLayer.addSublayer(hubLayer)

        let speedTextFrame = CGRect(
            x: 0,
            y: gaugeSize * 0.62,
            width: gaugeSize,
            height: gaugeSize * 0.22
        )
        let speedTextLayer = CALayer()
        speedTextLayer.frame = speedTextFrame
        speedTextLayer.contentsGravity = .center
        speedTextLayer.contentsScale = 2.0
        gaugeLayer.addSublayer(speedTextLayer)

        let samples = makeGaugeTimelineSamples(
            telemetry: telemetry,
            sourceSegmentStartTime: sourceSegmentStartTime,
            clipDuration: clipDuration,
            unitMultiplier: unitMultiplier
        )

        guard let firstSample = samples.first else {
            return gaugeLayer
        }

        needleLayer.path = makeNeedlePath(
            speedValue: firstSample.displaySpeed,
            maxSpeedValue: maxDisplaySpeed,
            gaugeSize: gaugeSize
        )
        let firstSpeedImage = makeTextImage(
            text: speedGaugeLabel(for: firstSample.displaySpeed, unitText: settings.speedUnits.rawValue),
            fontName: "Helvetica-Bold",
            fontSize: max(24, gaugeSize * 0.13),
            color: NSColor.white,
            canvasSize: speedTextFrame.size
        )
        speedTextLayer.contents = firstSpeedImage

        if clipDuration > 0, samples.count > 1 {
            let keyTimes = samples.map { NSNumber(value: $0.relativeTime / clipDuration) }
            let needlePaths = samples.map {
                makeNeedlePath(
                    speedValue: $0.displaySpeed,
                    maxSpeedValue: maxDisplaySpeed,
                    gaugeSize: gaugeSize
                ) as Any
            }

            let needleAnimation = CAKeyframeAnimation(keyPath: "path")
            needleAnimation.values = needlePaths
            needleAnimation.keyTimes = keyTimes
            needleAnimation.duration = clipDuration
            needleAnimation.beginTime = AVCoreAnimationBeginTimeAtZero
            needleAnimation.calculationMode = .linear
            needleAnimation.isRemovedOnCompletion = false
            needleAnimation.fillMode = .forwards
            needleLayer.add(needleAnimation, forKey: "needlePathAnimation")

            if let firstSpeedImage {
                let speedValues = samples.map { Int($0.displaySpeed.rounded()) }
                var speedImagesByValue: [Int: CGImage] = [:]
                let speedImages = speedValues.map { value -> Any in
                    if let image = speedImagesByValue[value] {
                        return image
                    }
                    let image = makeTextImage(
                        text: speedGaugeLabel(for: Double(value), unitText: settings.speedUnits.rawValue),
                        fontName: "Helvetica-Bold",
                        fontSize: max(24, gaugeSize * 0.13),
                        color: NSColor.white,
                        canvasSize: speedTextFrame.size
                    ) ?? firstSpeedImage
                    speedImagesByValue[value] = image
                    return image
                }

                let textAnimation = CAKeyframeAnimation(keyPath: "contents")
                textAnimation.values = speedImages
                textAnimation.keyTimes = keyTimes
                textAnimation.duration = clipDuration
                textAnimation.beginTime = AVCoreAnimationBeginTimeAtZero
                textAnimation.calculationMode = .discrete
                textAnimation.isRemovedOnCompletion = false
                textAnimation.fillMode = .forwards
                speedTextLayer.add(textAnimation, forKey: "speedTextAnimation")
            }
        }

        return gaugeLayer
    }

    private struct GaugeSample {
        let relativeTime: TimeInterval
        let displaySpeed: Double
    }

    private func makeGaugeTimelineSamples(
        telemetry: Telemetry,
        sourceSegmentStartTime: TimeInterval,
        clipDuration: TimeInterval,
        unitMultiplier: Double
    ) -> [GaugeSample] {
        guard !telemetry.speedSamples.isEmpty else {
            return [GaugeSample(relativeTime: 0, displaySpeed: 0)]
        }

        let samples = telemetry.speedSamples.sorted { $0.timestamp < $1.timestamp }
        let segmentStart = max(0, sourceSegmentStartTime)
        let segmentEnd = segmentStart + max(clipDuration, 0)
        let eps = 0.001

        let inRange = samples.filter { sample in
            sample.timestamp >= segmentStart - eps && sample.timestamp <= segmentEnd + eps
        }

        var timeline: [GaugeSample] = []
        timeline.reserveCapacity(max(inRange.count + 2, 2))

        let startSpeed = interpolateSpeed(at: segmentStart, samples: samples) * unitMultiplier
        timeline.append(GaugeSample(relativeTime: 0, displaySpeed: startSpeed))

        for sample in inRange {
            let relative = max(0, min(clipDuration, sample.timestamp - segmentStart))
            timeline.append(GaugeSample(relativeTime: relative, displaySpeed: sample.speed * unitMultiplier))
        }

        if clipDuration > 0 {
            let endSpeed = interpolateSpeed(at: segmentEnd, samples: samples) * unitMultiplier
            timeline.append(GaugeSample(relativeTime: clipDuration, displaySpeed: endSpeed))
        }

        timeline.sort { lhs, rhs in
            if lhs.relativeTime == rhs.relativeTime {
                return lhs.displaySpeed < rhs.displaySpeed
            }
            return lhs.relativeTime < rhs.relativeTime
        }

        var deduped: [GaugeSample] = []
        deduped.reserveCapacity(timeline.count)
        for sample in timeline {
            if let last = deduped.last, abs(last.relativeTime - sample.relativeTime) < 0.0005 {
                deduped[deduped.count - 1] = sample
            } else {
                deduped.append(sample)
            }
        }

        let maxKeyframes = 450
        if deduped.count <= maxKeyframes {
            return deduped
        }

        var compressed: [GaugeSample] = []
        compressed.reserveCapacity(maxKeyframes)
        let denominator = max(maxKeyframes - 1, 1)
        for index in 0..<maxKeyframes {
            let originalIndex = Int(round(Double(index) * Double(deduped.count - 1) / Double(denominator)))
            compressed.append(deduped[min(originalIndex, deduped.count - 1)])
        }
        return compressed
    }

    private func interpolateSpeed(
        at timestamp: TimeInterval,
        samples: [Telemetry.SpeedSample]
    ) -> Double {
        guard let first = samples.first else { return 0 }
        if timestamp <= first.timestamp { return first.speed }
        guard let last = samples.last else { return first.speed }
        if timestamp >= last.timestamp { return last.speed }

        for idx in 1..<samples.count {
            let left = samples[idx - 1]
            let right = samples[idx]
            if timestamp <= right.timestamp {
                let delta = right.timestamp - left.timestamp
                if delta <= 0 { return right.speed }
                let factor = (timestamp - left.timestamp) / delta
                return left.speed + (right.speed - left.speed) * factor
            }
        }

        return last.speed
    }

    private func makeNeedlePath(
        speedValue: Double,
        maxSpeedValue: Double,
        gaugeSize: CGFloat
    ) -> CGPath {
        let center = CGPoint(x: gaugeSize / 2, y: gaugeSize / 2)
        let radius = gaugeSize * 0.42
        let normalized = min(max(speedValue / max(maxSpeedValue, 1), 0), 1)
        let angle = CGFloat.pi - CGFloat(normalized) * CGFloat.pi
        let endPoint = CGPoint(
            x: center.x + cos(angle) * radius * 0.72,
            y: center.y + sin(angle) * radius * 0.72
        )

        let path = CGMutablePath()
        path.move(to: center)
        path.addLine(to: endPoint)
        return path
    }

    private func speedGaugeLabel(for speed: Double, unitText: String) -> String {
        "\(Int(speed.rounded())) \(unitText)"
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

    private func createPisteDetailsLayer(
        size: CGSize,
        settings: ExportSettings.OverlaySettings,
        pisteInfo: PisteInfoData
    ) -> CALayer {
        let resort = pisteInfo.resort?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resortText = (resort?.isEmpty == false) ? (resort ?? "Unknown resort") : "Unknown resort"
        let text = "\(pisteInfo.name) | \(resortText)"

        let font = NSFont.systemFont(ofSize: settings.pisteDetailsFontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).size(withAttributes: attributes)

        let padding: CGFloat = 16
        let layerWidth = max(140, textSize.width + padding * 2)
        let layerHeight = max(36, textSize.height + padding)

        let position = calculatePosition(
            for: settings.pisteDetailsPosition,
            in: size,
            overlaySize: max(layerWidth, layerHeight)
        )
        let containerFrame = CGRect(
            x: position.x - layerWidth / 2,
            y: position.y - layerHeight / 2,
            width: layerWidth,
            height: layerHeight
        )

        let backgroundLayer = CALayer()
        backgroundLayer.frame = CGRect(origin: .zero, size: containerFrame.size)
        backgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        backgroundLayer.cornerRadius = 8
        backgroundLayer.opacity = Float(settings.pisteDetailsOpacity)

        let textLayer = CALayer()
        textLayer.frame = CGRect(origin: .zero, size: containerFrame.size).insetBy(dx: padding, dy: padding / 2)
        textLayer.contentsGravity = .center
        textLayer.contentsScale = 2.0
        textLayer.opacity = Float(settings.pisteDetailsOpacity)
        if let textImage = makeTextImage(
            text: text,
            fontName: font.fontName,
            fontSize: CGFloat(settings.pisteDetailsFontSize),
            color: NSColor.white,
            canvasSize: textLayer.bounds.size
        ) {
            textLayer.contents = textImage
        }

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
