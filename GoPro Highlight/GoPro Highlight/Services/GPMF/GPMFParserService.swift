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
        let durationTime = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationTime)
        guard duration.isFinite, duration > 0 else { throw GPMFError.parseFailed }
        let rawGPSPoints = try await extractRawGPSPointsFromGpmdTrack(from: videoURL)
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

    private func findGPMFTrackCandidates(in asset: AVAsset) async throws -> [AVAssetTrack] {
        let allTracks = try await asset.load(.tracks)
        var gpmdTracks: [AVAssetTrack] = []
        var hintedTracks: [AVAssetTrack] = []

        // Look for tracks with 'gpmd' subtype first.
        for track in allTracks {
            let formatDescriptions = try await track.load(.formatDescriptions)
            var hasGpmdSubtype = false
            var hasGoProHint = false

            for case let desc as CMFormatDescription in formatDescriptions {
                let subType = CMFormatDescriptionGetMediaSubType(desc)
                // 'gpmd' = 0x67706D64
                if subType == 0x67706D64 || subType == 0x646D7067 {
                    hasGpmdSubtype = true
                    break
                }

                if let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any] {
                    let extText = String(describing: extensions).lowercased()
                    if extText.contains("gpmd") || extText.contains("gopro") {
                        hasGoProHint = true
                    }
                }
            }

            if hasGpmdSubtype {
                gpmdTracks.append(track)
            } else if hasGoProHint {
                hintedTracks.append(track)
            }
        }

        // Fallback: include any metadata tracks we haven't already added.
        let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)

        var orderedTracks: [AVAssetTrack] = []
        var seenTrackIDs = Set<CMPersistentTrackID>()

        let appendUniqueTracks: ([AVAssetTrack]) -> Void = { tracks in
            for track in tracks where !seenTrackIDs.contains(track.trackID) {
                orderedTracks.append(track)
                seenTrackIDs.insert(track.trackID)
            }
        }

        appendUniqueTracks(gpmdTracks)
        appendUniqueTracks(hintedTracks)
        appendUniqueTracks(metadataTracks)
        // Only include track types that may plausibly contain telemetry.
        let timecodeTracks = try await asset.loadTracks(withMediaType: .timecode)
        appendUniqueTracks(timecodeTracks)

        return orderedTracks
    }

    // MARK: - GPMF Track Reading via AVAssetReader

    private func readGPMFTrack(asset: AVAsset, track: AVAssetTrack) async throws -> [RawGPSPoint] {
        // Do not attempt to parse large video/audio essence tracks as metadata.
        if track.mediaType == .video || track.mediaType == .audio {
            return []
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)

        guard reader.startReading() else {
            throw GPMFError.parseFailed
        }

        var allPoints: [RawGPSPoint] = []

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length > 0 else { continue }

            var data = Data(repeating: 0, count: length)
            let status = data.withUnsafeMutableBytes { bytes in
                guard let destination = bytes.baseAddress else {
                    return OSStatus(kCMBlockBufferBadLengthParameterErr)
                }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: length,
                    destination: destination
                )
            }
            guard status == kCMBlockBufferNoErr else { continue }

            let points = extractGPSPoints(fromSampleData: data)
            allPoints.append(contentsOf: points)
        }

        // Some metadata tracks expose payload only via AVMetadata items.
        if allPoints.isEmpty && track.mediaType == .metadata {
            allPoints = try await readGPMFFromMetadataAdaptor(asset: asset, track: track)
        }

        return allPoints
    }

    private func readGPMFFromMetadataAdaptor(asset: AVAsset, track: AVAssetTrack) async throws -> [RawGPSPoint] {
        guard track.mediaType == .metadata else {
            return []
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
        reader.add(output)

        guard reader.startReading() else {
            throw GPMFError.parseFailed
        }

        var points: [RawGPSPoint] = []
        while let group = adaptor.nextTimedMetadataGroup() {
            for item in group.items {
                guard let data = extractMetadataDataValue(from: item), !data.isEmpty else { continue }
                points.append(contentsOf: extractGPSPoints(fromSampleData: data))
            }
        }

        return points
    }

    private func extractMetadataDataValue(from item: AVMetadataItem) -> Data? {
        if let data = item.dataValue {
            return data
        }

        if let data = item.value as? Data {
            return data
        }

        if let data = item.value as? NSData {
            return data as Data
        }

        return nil
    }

    private func trackDebugDescription(_ track: AVAssetTrack) -> String {
        "track#\(track.trackID),mediaType=\(track.mediaType.rawValue)"
    }

    private struct FFProbeStreams: Decodable {
        let streams: [FFProbeStream]
    }

    private struct FFProbeStream: Decodable {
        let index: Int
        let codec_type: String?
        let codec_name: String?
        let codec_tag_string: String?
        let codec_tag: String?
        let tags: [String: String]?
    }

    private struct FFmpegExtractionAttempt {
        let label: String
        let arguments: [String]
    }

    private func extractRawGPSPointsViaFFmpeg(from videoURL: URL) throws -> (points: [RawGPSPoint], diagnostic: String)? {
        guard let ffprobePath = findExecutable(named: "ffprobe"),
              let ffmpegPath = findExecutable(named: "ffmpeg") else {
            return nil
        }

        let probe = try runProcessCaptureOutput(
            executablePath: ffprobePath,
            arguments: [
                "-hide_banner",
                "-v", "error",
                "-print_format", "json",
                "-show_streams",
                videoURL.path
            ]
        )

        guard probe.exitCode == 0 else {
            throw NSError(
                domain: "GPMFParserService",
                code: 100,
                userInfo: [NSLocalizedDescriptionKey: "ffprobe failed: \(probe.stderr)"]
            )
        }

        let parsed = try JSONDecoder().decode(FFProbeStreams.self, from: probe.stdout)
        let candidateStreams = candidateGPMDStreams(from: parsed.streams)
        guard !candidateStreams.isEmpty else {
            return ([], "ffprobe found no gpmd/data candidate streams")
        }

        var attemptDiagnostics: [String] = []
        attemptDiagnostics.append("ffprobe streams=\(parsed.streams.count)")
        attemptDiagnostics.append("candidates=\(candidateStreams.map(\.index))")

        for stream in candidateStreams {
            let extractionAttempts = ffmpegExtractionAttempts(videoURL: videoURL, streamIndex: stream.index)
            for attempt in extractionAttempts {
                let tempOutput = temporaryURL(prefix: "gpmf_\(stream.index)", extension: "bin")
                defer { try? FileManager.default.removeItem(at: tempOutput) }

                var args = attempt.arguments
                args.append(tempOutput.path)
                let result = try runProcessWritingStdoutToFile(
                    executablePath: ffmpegPath,
                    arguments: args,
                    outputURL: tempOutput
                )

                if result.exitCode != 0 {
                    let stderr = result.stderr.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                    attemptDiagnostics.append("stream \(stream.index) \(attempt.label): ffmpeg failed (\(stderr))")
                    continue
                }

                let payload = (try? Data(contentsOf: tempOutput)) ?? Data()
                let points = extractGPSPoints(fromSampleData: payload)
                let validPoints = sanitizeRawGPSPoints(points)
                attemptDiagnostics.append("stream \(stream.index) \(attempt.label): bytes=\(payload.count), raw=\(points.count), valid=\(validPoints.count)")

                if !validPoints.isEmpty {
                    let diagnostic = attemptDiagnostics.joined(separator: "; ")
                    return (points, diagnostic)
                }
            }
        }

        return ([], attemptDiagnostics.joined(separator: "; "))
    }

    private func candidateGPMDStreams(from streams: [FFProbeStream]) -> [FFProbeStream] {
        streams
            .map { (stream: $0, score: gpmfStreamScore($0)) }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.stream.index < rhs.stream.index
            }
            .map(\.stream)
    }

    private func gpmfStreamScore(_ stream: FFProbeStream) -> Int {
        let codecType = stream.codec_type?.lowercased() ?? ""
        let codecName = stream.codec_name?.lowercased() ?? ""
        let tagString = stream.codec_tag_string?.lowercased() ?? ""
        let tagValue = stream.codec_tag?.lowercased() ?? ""
        let handlerName = stream.tags?["handler_name"]?.lowercased() ?? ""
        let handler = handlerName.replacingOccurrences(of: " ", with: "")

        var score = 0
        if tagString == "gpmd" || tagValue == "0x646d7067" {
            score += 100
        }

        if codecType == "data" {
            score += 30
        }

        if codecName.contains("bin_data") || codecName.contains("data") {
            score += 10
        }

        if handler.contains("gopromet") || handler.contains("gpmd") || handler.contains("metadata") {
            score += 40
        }

        return score
    }

    private func ffmpegExtractionAttempts(videoURL: URL, streamIndex: Int) -> [FFmpegExtractionAttempt] {
        let inputArgs = ["-hide_banner", "-v", "error", "-nostdin", "-y", "-i", videoURL.path, "-map", "0:\(streamIndex)"]
        return [
            FFmpegExtractionAttempt(
                label: "copy+data",
                arguments: inputArgs + ["-c", "copy", "-f", "data"]
            ),
            FFmpegExtractionAttempt(
                label: "copy+rawvideo",
                arguments: inputArgs + ["-c", "copy", "-f", "rawvideo"]
            ),
            FFmpegExtractionAttempt(
                label: "data",
                arguments: inputArgs + ["-f", "data"]
            )
        ]
    }

    private func temporaryURL(prefix: String, extension ext: String) -> URL {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return tempDir.appendingPathComponent("\(prefix)_\(UUID().uuidString).\(ext)")
    }

    private func extractRawGPSPointsViaFileScan(from videoURL: URL) async throws -> (points: [RawGPSPoint], diagnostic: String) {
        let attributes = try FileManager.default.attributesOfItem(atPath: videoURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            return ([], "file-scan skipped: empty file")
        }

        let chunkSize = 8 * 1024 * 1024
        let tailReserve = 32 * 1024

        let handle = try FileHandle(forReadingFrom: videoURL)
        defer { try? handle.close() }

        var pending = Data()
        var totalBytesRead = 0
        var allPoints: [RawGPSPoint] = []
        var runningScale = Array(repeating: 1.0, count: 9)

        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty {
                break
            }

            totalBytesRead += chunk.count
            pending.append(chunk)

            if pending.count <= tailReserve {
                continue
            }

            let parseLimit = pending.count - tailReserve
            let window = Data(pending.prefix(parseLimit))
            let parseResult = extractGPSPointsBySequentialScan(
                from: window,
                initialScale: runningScale,
                isFinalChunk: false
            )

            allPoints.append(contentsOf: parseResult.points)
            runningScale = parseResult.lastScale
            pending.removeFirst(parseResult.consumedBytes)
        }

        if !pending.isEmpty {
            let parseResult = extractGPSPointsBySequentialScan(
                from: pending,
                initialScale: runningScale,
                isFinalChunk: true
            )
            allPoints.append(contentsOf: parseResult.points)
        }

        let diagnostic = "file-scan bytesRead=\(totalBytesRead), points=\(allPoints.count)"
        return (allPoints, diagnostic)
    }

    private func extractGPSPointsBySequentialScan(
        from data: Data,
        initialScale: [Double],
        isFinalChunk: Bool
    ) -> (points: [RawGPSPoint], lastScale: [Double], consumedBytes: Int) {
        var points: [RawGPSPoint] = []
        var scale = initialScale
        var index = 0

        func makeKey(at offset: Int) -> String? {
            guard offset + 4 <= data.count else { return nil }
            let keyData = data[data.startIndex + offset ..< data.startIndex + offset + 4]
            return String(data: keyData, encoding: .ascii)
        }

        while index + 8 <= data.count {
            guard let key = makeKey(at: index) else {
                index += 1
                continue
            }

            let type = data[data.startIndex + index + 4]
            let structSize = Int(data[data.startIndex + index + 5])
            let repeatCount = Int(data[data.startIndex + index + 6]) << 8 | Int(data[data.startIndex + index + 7])

            let isGPS5 = key == "GPS5"
            let isGPS9 = key == "GPS9"
            let isSCAL = key == "SCAL"

            if !isGPS5 && !isGPS9 && !isSCAL {
                index += 1
                continue
            }

            guard structSize > 0, repeatCount > 0 else {
                index += 1
                continue
            }

            if isSCAL {
                let validScaleType = type == 0x6C || type == 0x4C || type == 0x73 || type == 0x53 // l/L/s/S
                if !validScaleType || (structSize != 2 && structSize != 4) || repeatCount > 64 {
                    index += 1
                    continue
                }
            }

            if isGPS5 || isGPS9 {
                let expectedFields = isGPS9 ? 9 : 5
                let expectedStructSize = expectedFields * 4
                if (type != 0x6C && type != 0x4C) || structSize != expectedStructSize || repeatCount > 20_000 {
                    index += 1
                    continue
                }
            }

            let dataLength = structSize * repeatCount
            let paddedLength = (dataLength + 3) & ~3
            let dataStart = index + 8
            let paddedEnd = dataStart + paddedLength
            let dataEnd = dataStart + dataLength

            if paddedEnd > data.count || dataEnd > data.count {
                if isFinalChunk {
                    index += 1
                    continue
                }
                break
            }

            let payload = Data(data[data.startIndex + dataStart ..< data.startIndex + dataEnd])

            if isSCAL {
                let parsed = parseScaleValuesFromPayload(payload: payload, type: type, structSize: structSize)
                if !parsed.isEmpty {
                    scale = parsed
                }
                index = paddedEnd
                continue
            }

            let fieldCount = isGPS9 ? 9 : 5
            guard (type == 0x6C || type == 0x4C), structSize == fieldCount * 4 else {
                index += 1
                continue
            }

            var scaleForGPS = scale
            if scaleForGPS.count < fieldCount {
                scaleForGPS += Array(repeating: 1.0, count: fieldCount - scaleForGPS.count)
            }

            points.append(contentsOf: parseGPSData(
                payload,
                repeatCount: repeatCount,
                fieldCount: fieldCount,
                scale: scaleForGPS
            ))
            index = paddedEnd
        }

        return (points, scale, index)
    }

    private func findExecutable(named command: String) -> String? {
        let fileManager = FileManager.default

        let environment = ProcessInfo.processInfo.environment
        let environmentOverrideKeys: [String]
        if command == "ffmpeg" {
            environmentOverrideKeys = ["FFMPEG_PATH", "FFMPEG_BINARY"]
        } else {
            environmentOverrideKeys = ["FFPROBE_PATH", "FFPROBE_BINARY"]
        }
        for key in environmentOverrideKeys {
            if let override = environment[key], fileManager.isExecutableFile(atPath: override) {
                return override
            }
        }

        let fixedPaths = [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/usr/bin/\(command)"
        ]

        let cwd = fileManager.currentDirectoryPath
        let cwdPaths = [
            "\(cwd)/vendor/ffmpeg/\(command)",
            "\(cwd)/\(command)"
        ]

        let bundleResourcePaths: [String] = {
            guard let resourceURL = Bundle.main.resourceURL else { return [] }
            return [
                resourceURL.appendingPathComponent(command).path,
                resourceURL.appendingPathComponent("vendor/ffmpeg/\(command)").path
            ]
        }()

        for path in fixedPaths + cwdPaths + bundleResourcePaths where fileManager.isExecutableFile(atPath: path) {
            return path
        }

        if let pathValue = environment["PATH"] {
            for directory in pathValue.split(separator: ":") {
                let candidate = "\(directory)/\(command)"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        return nil
    }

    private func runProcessCaptureOutput(
        executablePath: String,
        arguments: [String]
    ) throws -> (exitCode: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private func runProcessWritingStdoutToFile(
        executablePath: String,
        arguments: [String],
        outputURL: URL
    ) throws -> (exitCode: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? outputHandle.close()
        }
        process.standardOutput = outputHandle

        try process.run()
        process.waitUntilExit()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return (process.terminationStatus, stderr)
    }

    // MARK: - MP4 GPMD Track Parsing

    private struct StscEntry {
        let firstChunk: Int
        let samplesPerChunk: Int
        let sampleDescriptionIndex: Int
    }

    private struct SampleTable {
        let sampleSizes: [Int]
        let chunkOffsets: [UInt64]
        let stscEntries: [StscEntry]
    }

    private func extractRawGPSPointsFromGpmdTrack(from videoURL: URL) async throws -> [RawGPSPoint] {
        guard let handle = try? FileHandle(forReadingFrom: videoURL) else {
            throw GPMFError.openFailed
        }
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        handle.seek(toFileOffset: 0)

        let topBoxes = findMP4Boxes(handle: handle, start: 0, end: fileSize)
        guard let moov = topBoxes.first(where: { $0.typeString == "moov" }) else {
            throw GPMFError.parseFailed
        }

        let moovChildren = findMP4Boxes(handle: handle, start: moov.dataStart, end: moov.end)
        let trakBoxes = moovChildren.filter { $0.typeString == "trak" }

        for trak in trakBoxes {
            try Task.checkCancellation()
            guard let stbl = findSampleTableBox(in: trak, handle: handle) else { continue }
            guard trackHasGpmdSampleEntry(stbl: stbl, handle: handle) else { continue }

            let table = try readSampleTable(from: stbl, handle: handle)
            let points = try await readGPSPoints(from: table, handle: handle)
            if !points.isEmpty {
                return points
            }
        }

        return []
    }

    private func findSampleTableBox(in trak: MP4Box, handle: FileHandle) -> MP4Box? {
        let trakChildren = findMP4Boxes(handle: handle, start: trak.dataStart, end: trak.end)
        guard let mdia = trakChildren.first(where: { $0.typeString == "mdia" }) else { return nil }
        let mdiaChildren = findMP4Boxes(handle: handle, start: mdia.dataStart, end: mdia.end)
        guard let minf = mdiaChildren.first(where: { $0.typeString == "minf" }) else { return nil }
        let minfChildren = findMP4Boxes(handle: handle, start: minf.dataStart, end: minf.end)
        return minfChildren.first(where: { $0.typeString == "stbl" })
    }

    private func trackHasGpmdSampleEntry(stbl: MP4Box, handle: FileHandle) -> Bool {
        let stblChildren = findMP4Boxes(handle: handle, start: stbl.dataStart, end: stbl.end)
        guard let stsd = stblChildren.first(where: { $0.typeString == "stsd" }) else { return false }

        let payload = readBoxPayload(handle: handle, box: stsd)
        guard payload.count >= 8 else { return false }

        let entryCount = Int(readUInt32BE(payload, at: 4))
        var offset = 8
        for _ in 0..<entryCount {
            guard offset + 8 <= payload.count else { break }
            let size = Int(readUInt32BE(payload, at: offset))
            let typeData = payload[payload.startIndex + offset + 4 ..< payload.startIndex + offset + 8]
            let type = String(data: typeData, encoding: .ascii) ?? ""
            if type == "gpmd" {
                return true
            }
            if size <= 8 { break }
            offset += size
        }

        return false
    }

    private func readSampleTable(from stbl: MP4Box, handle: FileHandle) throws -> SampleTable {
        let stblChildren = findMP4Boxes(handle: handle, start: stbl.dataStart, end: stbl.end)

        guard let stsz = stblChildren.first(where: { $0.typeString == "stsz" }) else {
            throw GPMFError.parseFailed
        }
        guard let stsc = stblChildren.first(where: { $0.typeString == "stsc" }) else {
            throw GPMFError.parseFailed
        }

        let stco = stblChildren.first(where: { $0.typeString == "stco" })
        let co64 = stblChildren.first(where: { $0.typeString == "co64" })
        guard stco != nil || co64 != nil else {
            throw GPMFError.parseFailed
        }

        let sampleSizes = parseStsz(readBoxPayload(handle: handle, box: stsz))
        let stscEntries = parseStsc(readBoxPayload(handle: handle, box: stsc))
        let chunkOffsets: [UInt64]
        if let stco = stco {
            chunkOffsets = parseStco(readBoxPayload(handle: handle, box: stco))
        } else if let co64 = co64 {
            chunkOffsets = parseCo64(readBoxPayload(handle: handle, box: co64))
        } else {
            chunkOffsets = []
        }

        return SampleTable(sampleSizes: sampleSizes, chunkOffsets: chunkOffsets, stscEntries: stscEntries)
    }

    private func readGPSPoints(from table: SampleTable, handle: FileHandle) async throws -> [RawGPSPoint] {
        var points: [RawGPSPoint] = []
        let entries = table.stscEntries.sorted { $0.firstChunk < $1.firstChunk }
        var stscIndex = 0
        var sampleIndex = 0

        for chunkIndex in 1...table.chunkOffsets.count {
            try Task.checkCancellation()
            while stscIndex + 1 < entries.count && entries[stscIndex + 1].firstChunk <= chunkIndex {
                stscIndex += 1
            }
            let samplesPerChunk = entries[stscIndex].samplesPerChunk
            var offset = table.chunkOffsets[chunkIndex - 1]

            for _ in 0..<samplesPerChunk {
                if sampleIndex >= table.sampleSizes.count {
                    break
                }
                let sampleSize = table.sampleSizes[sampleIndex]
                sampleIndex += 1
                guard sampleSize > 0 else { continue }

                handle.seek(toFileOffset: offset)
                let data = handle.readData(ofLength: sampleSize)
                if data.count == sampleSize {
                    let samplePoints = extractGPSPoints(fromSampleData: data)
                    if !samplePoints.isEmpty {
                        points.append(contentsOf: samplePoints)
                    }
                }

                offset += UInt64(sampleSize)
            }
        }

        return points
    }

    private func readBoxPayload(handle: FileHandle, box: MP4Box) -> Data {
        handle.seek(toFileOffset: box.dataStart)
        let payloadSize = Int(box.size) - box.headerSize
        return handle.readData(ofLength: max(payloadSize, 0))
    }

    private func parseStsz(_ data: Data) -> [Int] {
        guard data.count >= 12 else { return [] }
        let sampleSize = readUInt32BE(data, at: 4)
        let sampleCount = Int(readUInt32BE(data, at: 8))
        if sampleCount <= 0 { return [] }
        if sampleSize != 0 {
            return Array(repeating: Int(sampleSize), count: sampleCount)
        }
        var sizes: [Int] = []
        sizes.reserveCapacity(sampleCount)
        var offset = 12
        for _ in 0..<sampleCount {
            guard offset + 4 <= data.count else { break }
            sizes.append(Int(readUInt32BE(data, at: offset)))
            offset += 4
        }
        return sizes
    }

    private func parseStsc(_ data: Data) -> [StscEntry] {
        guard data.count >= 8 else { return [] }
        let entryCount = Int(readUInt32BE(data, at: 4))
        var entries: [StscEntry] = []
        entries.reserveCapacity(entryCount)
        var offset = 8
        for _ in 0..<entryCount {
            guard offset + 12 <= data.count else { break }
            let firstChunk = Int(readUInt32BE(data, at: offset))
            let samplesPerChunk = Int(readUInt32BE(data, at: offset + 4))
            let sampleDescIndex = Int(readUInt32BE(data, at: offset + 8))
            entries.append(StscEntry(firstChunk: firstChunk, samplesPerChunk: samplesPerChunk, sampleDescriptionIndex: sampleDescIndex))
            offset += 12
        }
        return entries
    }

    private func parseStco(_ data: Data) -> [UInt64] {
        guard data.count >= 8 else { return [] }
        let entryCount = Int(readUInt32BE(data, at: 4))
        var offsets: [UInt64] = []
        offsets.reserveCapacity(entryCount)
        var offset = 8
        for _ in 0..<entryCount {
            guard offset + 4 <= data.count else { break }
            offsets.append(UInt64(readUInt32BE(data, at: offset)))
            offset += 4
        }
        return offsets
    }

    private func parseCo64(_ data: Data) -> [UInt64] {
        guard data.count >= 8 else { return [] }
        let entryCount = Int(readUInt32BE(data, at: 4))
        var offsets: [UInt64] = []
        offsets.reserveCapacity(entryCount)
        var offset = 8
        for _ in 0..<entryCount {
            guard offset + 8 <= data.count else { break }
            offsets.append(readUInt64BE(data, at: offset))
            offset += 8
        }
        return offsets
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

    private func extractGPSPoints(fromSampleData data: Data) -> [RawGPSPoint] {
        let directElements = parseGPMFElements(from: data)
        let directPoints = extractGPSPoints(from: directElements)
        if !directPoints.isEmpty {
            return directPoints
        }

        // Some samples have non-GPMF prefix bytes. Re-sync by scanning for known container keys.
        let offsets = Set(findKeyOffsets("DEVC", in: data) + findKeyOffsets("STRM", in: data)).sorted()
        var recoveredPoints: [RawGPSPoint] = []

        for offset in offsets {
            let elements = parseGPMFElements(from: data, offset: offset, end: data.count)
            let points = extractGPSPoints(from: elements)
            if !points.isEmpty {
                recoveredPoints.append(contentsOf: points)
            }
        }

        if !recoveredPoints.isEmpty {
            return recoveredPoints
        }

        // Final fallback: scan for GPS5/GPS9 payloads directly and pair them with nearby SCAL.
        return extractGPSPointsByDirectScan(from: data)
    }

    private func findKeyOffsets(_ key: String, in data: Data) -> [Int] {
        let pattern = Data(key.utf8)
        guard !pattern.isEmpty, data.count >= pattern.count else { return [] }

        var offsets: [Int] = []
        var searchStart = data.startIndex

        while searchStart < data.endIndex,
              let range = data.range(of: pattern, options: [], in: searchStart..<data.endIndex) {
            offsets.append(range.lowerBound)
            searchStart = range.lowerBound + 1
        }

        return offsets
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

    private func extractGPSPointsByDirectScan(from data: Data) -> [RawGPSPoint] {
        var points: [RawGPSPoint] = []
        let gpsOffsets = (findKeyOffsets("GPS5", in: data).map { ($0, 5) } +
                          findKeyOffsets("GPS9", in: data).map { ($0, 9) })
            .sorted { $0.0 < $1.0 }

        for (offset, fieldCount) in gpsOffsets {
            guard offset + 8 <= data.count else { continue }

            let type = data[data.startIndex + offset + 4]
            let structSize = Int(data[data.startIndex + offset + 5])
            let repeatCount = Int(data[data.startIndex + offset + 6]) << 8 | Int(data[data.startIndex + offset + 7])
            guard repeatCount > 0 else { continue }

            // GPS payload is big-endian int32 tuples.
            guard type == 0x6C || type == 0x4C else { continue } // 'l' / 'L'
            guard structSize == fieldCount * 4 else { continue }

            let dataStart = offset + 8
            let dataLength = structSize * repeatCount
            let dataEnd = dataStart + dataLength
            guard dataStart < data.count, dataEnd <= data.count else { continue }

            let payload = Data(data[data.startIndex + dataStart ..< data.startIndex + dataEnd])
            let scale = findNearestScaleValues(in: data, before: offset, expectedFieldCount: fieldCount)
            points.append(contentsOf: parseGPSData(payload, repeatCount: repeatCount, fieldCount: fieldCount, scale: scale))
        }

        return points
    }

    private func findNearestScaleValues(in data: Data, before gpsOffset: Int, expectedFieldCount: Int) -> [Double] {
        let searchStart = max(0, gpsOffset - 1024)
        let searchRange = searchStart..<gpsOffset

        guard searchRange.lowerBound < searchRange.upperBound else {
            return Array(repeating: 1.0, count: expectedFieldCount)
        }

        let nearbyOffsets = findKeyOffsets("SCAL", in: data)
            .filter { searchRange.contains($0) }
            .sorted(by: >) // closest first

        for offset in nearbyOffsets {
            guard offset + 8 <= data.count else { continue }
            let type = data[data.startIndex + offset + 4]
            let structSize = Int(data[data.startIndex + offset + 5])
            let repeatCount = Int(data[data.startIndex + offset + 6]) << 8 | Int(data[data.startIndex + offset + 7])
            let dataStart = offset + 8
            let dataLength = structSize * repeatCount
            let dataEnd = dataStart + dataLength
            guard repeatCount >= expectedFieldCount, dataStart < data.count, dataEnd <= gpsOffset else { continue }

            let payload = Data(data[data.startIndex + dataStart ..< data.startIndex + dataEnd])
            let parsed = parseScaleValuesFromPayload(payload: payload, type: type, structSize: structSize)
            if !parsed.isEmpty {
                if parsed.count >= expectedFieldCount {
                    return Array(parsed.prefix(expectedFieldCount))
                }
                return parsed + Array(repeating: 1.0, count: expectedFieldCount - parsed.count)
            }
        }

        return Array(repeating: 1.0, count: expectedFieldCount)
    }

    private func parseScaleValuesFromPayload(payload: Data, type: UInt8, structSize: Int) -> [Double] {
        var values: [Double] = []

        switch (type, structSize) {
        case (0x6C, 4), (0x4C, 4): // 'l' / 'L'
            for i in stride(from: 0, to: payload.count, by: 4) {
                guard i + 4 <= payload.count else { break }
                let value = Double(readInt32BE(payload, at: i))
                values.append(value == 0 ? 1.0 : value)
            }
        case (0x73, 2), (0x53, 2): // 's' / 'S'
            for i in stride(from: 0, to: payload.count, by: 2) {
                guard i + 2 <= payload.count else { break }
                let value = Double(readInt16BE(payload, at: i))
                values.append(value == 0 ? 1.0 : value)
            }
        default:
            break
        }

        return values
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

            let lat = scaledValue(rawValues[0], at: 0, scale: scale)
            let lon = scaledValue(rawValues[1], at: 1, scale: scale)
            let alt = scaledValue(rawValues[2], at: 2, scale: scale)
            let speed2d = scaledValue(rawValues[3], at: 3, scale: scale)
            let speed3d = scaledValue(rawValues[4], at: 4, scale: scale)

            points.append(RawGPSPoint(
                latitude: lat, longitude: lon, altitude: alt,
                speed2d: speed2d, speed3d: speed3d
            ))
        }

        return points
    }

    private func scaledValue(_ rawValue: Int32, at index: Int, scale: [Double]) -> Double {
        guard !scale.isEmpty else { return Double(rawValue) }

        let scaleIndex = min(index, scale.count - 1)
        let scaleValue = scale[scaleIndex]
        guard scaleValue != 0 else { return Double(rawValue) }

        return Double(rawValue) / scaleValue
    }

    private func sanitizeRawGPSPoints(_ points: [RawGPSPoint]) -> [RawGPSPoint] {
        points.filter { point in
            point.latitude.isFinite &&
            point.longitude.isFinite &&
            point.altitude.isFinite &&
            point.speed2d.isFinite &&
            point.speed3d.isFinite &&
            abs(point.speed2d) < 2000 &&
            abs(point.speed3d) < 2000
        }
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

            if abs(point.latitude) <= 90,
               abs(point.longitude) <= 180,
               !(point.latitude == 0 && point.longitude == 0) {
                gpsPoints.append(Telemetry.GPSPoint(
                    latitude: point.latitude,
                    longitude: point.longitude,
                    altitude: point.altitude,
                    timestamp: timestamp,
                    accuracy: nil
                ))
            }

            // Use max(speed_2d, speed_3d) as the speed (matches Python: max(speed_2d, speed_3d))
            let speedMs = max(0, max(point.speed2d, point.speed3d))

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
