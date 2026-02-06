//
//  GPMFParserService.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import Foundation
@preconcurrency import AVFoundation

/// Service for parsing GoPro Metadata Format (GPMF) from MP4 files
actor GPMFParserService {

    // MARK: - Public API

    /// Extracts telemetry data (GPS, speed) from a GoPro video's GPMF metadata track
    func extractTelemetry(from videoURL: URL) async throws -> Telemetry {
        let asset = AVAsset(url: videoURL)
        let duration = try await CMTimeGetSeconds(asset.load(.duration))
        guard duration > 0 else { throw GPMFError.parseFailed }

        // Find the GPMF metadata track
        guard let metadataTrack = try await findGPMFTrack(in: asset) else {
            throw GPMFError.noMetadata
        }

        // Read all GPMF payloads and extract GPS data
        let rawGPSPoints = try await readGPMFTrack(asset: asset, track: metadataTrack)

        guard !rawGPSPoints.isEmpty else {
            throw GPMFError.noMetadata
        }

        return buildTelemetry(from: rawGPSPoints, duration: duration)
    }

    /// Finds highlight markers by parsing the MP4 box structure (moov/udta/GPMF)
    func findHighlights(in videoURL: URL) throws -> [Highlight] {
        return try extractHighlightsFromMP4(url: videoURL)
    }

    // MARK: - GPMF Track Discovery

    private func findGPMFTrack(in asset: AVAsset) async throws -> AVAssetTrack? {
        let allTracks = try await asset.load(.tracks)

        // Look for track with 'gpmd' format (GoPro Metadata)
        for track in allTracks {
            let formatDescriptions = try await track.load(.formatDescriptions)
            for desc in formatDescriptions {
                let subType = CMFormatDescriptionGetMediaSubType(desc)
                // 'gpmd' = 0x67706D64
                if subType == 0x67706D64 {
                    return track
                }
            }
        }

        // Fallback: try metadata tracks
        let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)
        if let first = metadataTracks.first {
            return first
        }

        return nil
    }

    // MARK: - GPMF Track Reading via AVAssetReader

    private func readGPMFTrack(asset: AVAsset, track: AVAssetTrack) async throws -> [RawGPSPoint] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)

        guard reader.startReading() else {
            throw GPMFError.parseFailed
        }

        var allPoints: [RawGPSPoint] = []

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var length = 0
            var dataPointer: UnsafeMutablePointer<CChar>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &dataPointer
            )

            guard status == kCMBlockBufferNoErr, let ptr = dataPointer, length > 0 else { continue }

            let data = Data(bytes: ptr, count: length)
            let elements = parseGPMFElements(from: data)
            let points = extractGPSPoints(from: elements)
            allPoints.append(contentsOf: points)
        }

        return allPoints
    }

    // MARK: - GPMF Binary Format Parser

    private struct GPMFElement {
        let key: String
        let type: UInt8
        let structSize: Int
        let repeatCount: Int
        let rawData: Data
        let children: [GPMFElement]
    }

    private func parseGPMFElements(from data: Data, offset: Int = 0, end: Int? = nil) -> [GPMFElement] {
        var elements: [GPMFElement] = []
        var pos = offset
        let endPos = end ?? data.count

        while pos + 8 <= endPos {
            // Read 4-byte key
            guard pos + 8 <= data.count else { break }
            let keyBytes = data[data.startIndex + pos ..< data.startIndex + pos + 4]
            guard let key = String(data: keyBytes, encoding: .ascii) else {
                pos += 4
                continue
            }

            let type = data[data.startIndex + pos + 4]
            let structSize = Int(data[data.startIndex + pos + 5])
            let repeatCount = Int(data[data.startIndex + pos + 6]) << 8 | Int(data[data.startIndex + pos + 7])

            let dataSize = structSize * repeatCount
            let paddedDataSize = (dataSize + 3) & ~3
            let dataStart = pos + 8
            let dataEnd = min(dataStart + dataSize, endPos)

            if type == 0 && dataSize > 0 {
                // Container — parse children recursively
                let children = parseGPMFElements(from: data, offset: dataStart, end: dataEnd)
                elements.append(GPMFElement(
                    key: key, type: type, structSize: structSize,
                    repeatCount: repeatCount, rawData: Data(), children: children
                ))
            } else if dataSize > 0 {
                let safeEnd = min(dataEnd, data.count)
                let elementData = safeEnd > dataStart ? Data(data[data.startIndex + dataStart ..< data.startIndex + safeEnd]) : Data()
                elements.append(GPMFElement(
                    key: key, type: type, structSize: structSize,
                    repeatCount: repeatCount, rawData: elementData, children: []
                ))
            }

            pos = dataStart + paddedDataSize
        }

        return elements
    }

    // MARK: - GPS Data Extraction from GPMF Tree

    private struct RawGPSPoint {
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let speed2d: Double  // m/s
        let speed3d: Double  // m/s
    }

    private func extractGPSPoints(from elements: [GPMFElement]) -> [RawGPSPoint] {
        var allPoints: [RawGPSPoint] = []

        for element in elements {
            if element.key == "DEVC" {
                // Device container — look for GPS streams inside
                for child in element.children where child.key == "STRM" {
                    let points = extractGPSFromStream(child.children)
                    allPoints.append(contentsOf: points)
                }
            } else if element.key == "STRM" {
                let points = extractGPSFromStream(element.children)
                allPoints.append(contentsOf: points)
            }

            // Recurse into any other containers
            if !element.children.isEmpty && element.key != "DEVC" && element.key != "STRM" {
                let nested = extractGPSPoints(from: element.children)
                allPoints.append(contentsOf: nested)
            }
        }

        return allPoints
    }

    private func extractGPSFromStream(_ children: [GPMFElement]) -> [RawGPSPoint] {
        var scale: [Double] = []
        var gpsElement: GPMFElement?
        var fieldCount = 5

        for child in children {
            if child.key == "SCAL" {
                scale = parseScaleValues(child)
            }
            if child.key == "GPS5" {
                gpsElement = child
                fieldCount = 5
            }
            if child.key == "GPS9" {
                gpsElement = child
                fieldCount = 9
            }
        }

        guard let gps = gpsElement, gps.repeatCount > 0 else { return [] }

        if scale.isEmpty {
            scale = Array(repeating: 1.0, count: fieldCount)
        }

        return parseGPSData(gps.rawData, repeatCount: gps.repeatCount, fieldCount: fieldCount, scale: scale)
    }

    private func parseScaleValues(_ element: GPMFElement) -> [Double] {
        var values: [Double] = []
        let data = element.rawData

        // SCAL values are typically int32 or int16
        let bytesPerValue: Int
        switch element.type {
        case 0x6C, 0x4C: // 'l' int32, 'L' uint32
            bytesPerValue = 4
        case 0x73, 0x53: // 's' int16, 'S' uint16
            bytesPerValue = 2
        default:
            bytesPerValue = 4
        }

        if bytesPerValue == 4 {
            for i in stride(from: 0, to: data.count, by: 4) {
                guard i + 4 <= data.count else { break }
                let val = readInt32BE(data, at: i)
                values.append(Double(val))
            }
        } else {
            for i in stride(from: 0, to: data.count, by: 2) {
                guard i + 2 <= data.count else { break }
                let val = readInt16BE(data, at: i)
                values.append(Double(val))
            }
        }

        return values
    }

    private func parseGPSData(_ data: Data, repeatCount: Int, fieldCount: Int, scale: [Double]) -> [RawGPSPoint] {
        var points: [RawGPSPoint] = []
        let bytesPerSample = fieldCount * 4

        for i in 0..<repeatCount {
            let offset = i * bytesPerSample
            guard offset + 20 <= data.count else { break } // Need at least 5 int32s

            var rawValues: [Int32] = []
            for j in 0..<5 {
                rawValues.append(readInt32BE(data, at: offset + j * 4))
            }

            let lat = scale.count > 0 && scale[0] != 0 ? Double(rawValues[0]) / scale[0] : Double(rawValues[0])
            let lon = scale.count > 1 && scale[1] != 0 ? Double(rawValues[1]) / scale[1] : Double(rawValues[1])
            let alt = scale.count > 2 && scale[2] != 0 ? Double(rawValues[2]) / scale[2] : Double(rawValues[2])
            let speed2d = scale.count > 3 && scale[3] != 0 ? Double(rawValues[3]) / scale[3] : Double(rawValues[3])
            let speed3d = scale.count > 4 && scale[4] != 0 ? Double(rawValues[4]) / scale[4] : Double(rawValues[4])

            points.append(RawGPSPoint(
                latitude: lat, longitude: lon, altitude: alt,
                speed2d: speed2d, speed3d: speed3d
            ))
        }

        return points
    }

    // MARK: - Build Telemetry Model

    private func buildTelemetry(from rawPoints: [RawGPSPoint], duration: TimeInterval) -> Telemetry {
        var gpsPoints: [Telemetry.GPSPoint] = []
        var speedSamples: [Telemetry.SpeedSample] = []
        var timestamps: [TimeInterval] = []

        let totalSamples = rawPoints.count

        for (idx, point) in rawPoints.enumerated() {
            // Distribute samples linearly across video duration (matches Python approach)
            let timestamp = totalSamples > 1
                ? (Double(idx) / Double(totalSamples - 1)) * duration
                : 0

            gpsPoints.append(Telemetry.GPSPoint(
                latitude: point.latitude,
                longitude: point.longitude,
                altitude: point.altitude,
                timestamp: timestamp,
                accuracy: nil
            ))

            // Use max(speed_2d, speed_3d) as the speed (matches Python: max(speed_2d, speed_3d))
            let speedMs = max(point.speed2d, point.speed3d)

            speedSamples.append(Telemetry.SpeedSample(
                speed: speedMs,
                timestamp: timestamp,
                isAnomaly: false
            ))

            timestamps.append(timestamp)
        }

        return Telemetry(
            gpsPoints: gpsPoints,
            speedSamples: speedSamples,
            timestamps: timestamps
        )
    }

    // MARK: - Highlight Extraction (MP4 Box Parsing)

    private struct MP4Box {
        let boxType: Data
        let start: UInt64
        let size: UInt64
        let headerSize: Int

        var dataStart: UInt64 { start + UInt64(headerSize) }
        var end: UInt64 { start + size }

        var typeString: String {
            String(data: boxType, encoding: .ascii) ?? "????"
        }
    }

    private func extractHighlightsFromMP4(url: URL) throws -> [Highlight] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw GPMFError.openFailed
        }
        defer { try? handle.close() }

        // Get file size
        let fileSize = handle.seekToEndOfFile()
        handle.seek(toFileOffset: 0)

        // Find top-level boxes
        let topBoxes = findMP4Boxes(handle: handle, start: 0, end: fileSize)

        // Find moov box
        guard let moov = topBoxes.first(where: { $0.typeString == "moov" }) else {
            return []
        }

        // Find udta child
        let moovChildren = findMP4Boxes(handle: handle, start: moov.dataStart, end: moov.end)
        guard let udta = moovChildren.first(where: { $0.typeString == "udta" }) else {
            return []
        }

        // Find GPMF or HMMT child
        let udtaChildren = findMP4Boxes(handle: handle, start: udta.dataStart, end: udta.end)

        if let gpmf = udtaChildren.first(where: { $0.typeString == "GPMF" }) {
            let timestampsMs = parseHighlightsGPMF(handle: handle, start: gpmf.dataStart, end: gpmf.end)
            return timestampsMs.map { ms in
                Highlight(timestamp: Double(ms) / 1000.0, type: .manual)
            }
        }

        if let hmmt = udtaChildren.first(where: { $0.typeString == "HMMT" }) {
            let timestampsMs = parseHighlightsHMMT(handle: handle, start: hmmt.dataStart, end: hmmt.end)
            return timestampsMs.map { ms in
                Highlight(timestamp: Double(ms) / 1000.0, type: .manual)
            }
        }

        return []
    }

    private func findMP4Boxes(handle: FileHandle, start: UInt64, end: UInt64) -> [MP4Box] {
        var boxes: [MP4Box] = []
        var pos = start

        while pos + 8 <= end {
            handle.seek(toFileOffset: pos)
            let sizeData = handle.readData(ofLength: 4)
            let typeData = handle.readData(ofLength: 4)
            guard sizeData.count == 4, typeData.count == 4 else { break }

            var size = UInt64(readUInt32BE(sizeData, at: 0))
            var headerSize = 8

            if size == 1 {
                let extData = handle.readData(ofLength: 8)
                guard extData.count == 8 else { break }
                size = readUInt64BE(extData, at: 0)
                headerSize = 16
            } else if size == 0 {
                size = end - pos
            }

            guard size >= UInt64(headerSize) else { break }

            boxes.append(MP4Box(boxType: typeData, start: pos, size: size, headerSize: headerSize))
            pos += size
        }

        return boxes
    }

    private func parseHighlightsGPMF(handle: FileHandle, start: UInt64, end: UInt64) -> [UInt32] {
        var highlights: [UInt32] = []
        var inHighlights = false
        var inHLMT = false

        handle.seek(toFileOffset: start)

        while handle.offsetInFile + 4 <= end {
            let data = handle.readData(ofLength: 4)
            guard data.count == 4 else { break }

            if data == Data("High".utf8) && !inHighlights {
                let nextData = handle.readData(ofLength: 4)
                if nextData == Data("ligh".utf8) {
                    inHighlights = true
                }
            }

            if data == Data("HLMT".utf8) && inHighlights && !inHLMT {
                inHLMT = true
            }

            if data == Data("MANL".utf8) && inHighlights && inHLMT {
                let currPos = handle.offsetInFile
                guard currPos >= 20 else { continue }
                handle.seek(toFileOffset: currPos - 20)
                let tsData = handle.readData(ofLength: 4)
                if tsData.count == 4 {
                    let timestamp = readUInt32BE(tsData, at: 0)
                    if timestamp != 0 {
                        highlights.append(timestamp)
                    }
                }
                handle.seek(toFileOffset: currPos)
            }
        }

        return highlights
    }

    private func parseHighlightsHMMT(handle: FileHandle, start: UInt64, end: UInt64) -> [UInt32] {
        var highlights: [UInt32] = []
        handle.seek(toFileOffset: start)

        while handle.offsetInFile + 8 <= end {
            let tsData = handle.readData(ofLength: 4)
            guard tsData.count == 4 else { break }
            let timestamp = readUInt32BE(tsData, at: 0)
            if timestamp == 0 { break }
            highlights.append(timestamp)
            _ = handle.readData(ofLength: 4) // skip unused data
        }

        return highlights
    }

    // MARK: - Binary Reading Helpers

    private func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        guard i + 3 < data.endIndex else { return 0 }
        return UInt32(data[i]) << 24 | UInt32(data[i+1]) << 16 | UInt32(data[i+2]) << 8 | UInt32(data[i+3])
    }

    private func readInt32BE(_ data: Data, at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32BE(data, at: offset))
    }

    private func readInt16BE(_ data: Data, at offset: Int) -> Int16 {
        let i = data.startIndex + offset
        guard i + 1 < data.endIndex else { return 0 }
        return Int16(bitPattern: UInt16(data[i]) << 8 | UInt16(data[i+1]))
    }

    private func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        let i = data.startIndex + offset
        guard i + 7 < data.endIndex else { return 0 }
        return UInt64(data[i]) << 56 | UInt64(data[i+1]) << 48 | UInt64(data[i+2]) << 40 | UInt64(data[i+3]) << 32
             | UInt64(data[i+4]) << 24 | UInt64(data[i+5]) << 16 | UInt64(data[i+6]) << 8 | UInt64(data[i+7])
    }
}

// MARK: - Errors
enum GPMFError: LocalizedError {
    case invalidPath
    case openFailed
    case parseFailed
    case noMetadata

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "Invalid video file path"
        case .openFailed:
            return "Failed to open video file"
        case .parseFailed:
            return "Failed to parse GPMF metadata"
        case .noMetadata:
            return "No GPMF metadata found in video"
        }
    }
}
