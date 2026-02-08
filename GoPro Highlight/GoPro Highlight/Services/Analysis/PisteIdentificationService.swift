//
//  PisteIdentificationService.swift
//  GoPro Highlight
//
//  Created on 2026-02-06.
//

import Foundation
import CoreLocation

/// Service for identifying ski pistes based on GPS coordinates
actor PisteIdentificationService {

    struct PisteInfo {
        let name: String
        let difficulty: String?  // "novice", "easy", "intermediate", "advanced", "expert"
        let resort: String?
        let confidence: Double   // 0.0 to 1.0
    }

    struct Metrics {
        let identifyRequests: Int
        let nearbyCacheHits: Int
        let nearbyInflightJoins: Int
        let resortCacheHits: Int
        let resortInflightJoins: Int
        let nearbyLogicalQueries: Int
        let resortLogicalQueries: Int
        let httpAttempts: Int
        let httpSuccesses: Int
    }

    private let osmService = OpenStreetMapService()
    private var pisteCache: [String: [OpenStreetMapService.PisteData]] = [:]
    private var resortCache: [String: String] = [:]
    private var pisteRequestsInFlight: [String: Task<[OpenStreetMapService.PisteData], Error>] = [:]
    private var resortRequestsInFlight: [String: Task<String?, Error>] = [:]
    private var identifyRequests = 0
    private var nearbyCacheHits = 0
    private var nearbyInflightJoins = 0
    private var resortCacheHits = 0
    private var resortInflightJoins = 0
    private var overpassUnavailableUntil: Date?
    private let overpassCooldownSeconds: TimeInterval = 30

    /// Identifies which ski piste a video was recorded on based on GPS telemetry
    func identifyPiste(from telemetry: Telemetry) async throws -> PisteInfo? {
        identifyRequests += 1
        guard !telemetry.gpsPoints.isEmpty else {
            return nil
        }

        if let unavailableUntil = overpassUnavailableUntil, unavailableUntil > Date() {
            return nil
        }

        // Calculate center point
        let centerPoint = calculateCenterPoint(from: telemetry.gpsPoints)
        let searchRadius = 5000.0
        let cacheKey = makeCacheKey(latitude: centerPoint.latitude, longitude: centerPoint.longitude, radiusMeters: searchRadius)

        let pistes: [OpenStreetMapService.PisteData]
        do {
            pistes = try await nearbyPistes(
                cacheKey: cacheKey,
                centerLat: centerPoint.latitude,
                centerLon: centerPoint.longitude,
                radiusMeters: searchRadius
            )
            overpassUnavailableUntil = nil
        } catch OSMError.networkUnavailable {
            overpassUnavailableUntil = Date().addingTimeInterval(overpassCooldownSeconds)
            return nil
        } catch {
            throw error
        }

        guard !pistes.isEmpty else {
            return nil // No pistes found nearby
        }

        // Find best matching piste
        let match = findBestMatch(
            gpsPoints: telemetry.gpsPoints,
            pistes: pistes
        )

        guard var match else {
            return nil
        }

        if match.resort == nil {
            if let dominantResort = dominantResortName(in: pistes) {
                match = PisteInfo(
                    name: match.name,
                    difficulty: match.difficulty,
                    resort: dominantResort,
                    confidence: match.confidence
                )
            } else if let cachedResort = resortCache[cacheKey] {
                match = PisteInfo(
                    name: match.name,
                    difficulty: match.difficulty,
                    resort: cachedResort,
                    confidence: match.confidence
                )
            } else if let nearestResort = try? await nearestResortName(
                cacheKey: cacheKey,
                centerLat: centerPoint.latitude,
                centerLon: centerPoint.longitude,
                radiusMeters: 25000
            ) {
                match = PisteInfo(
                    name: match.name,
                    difficulty: match.difficulty,
                    resort: nearestResort,
                    confidence: match.confidence
                )
            }
        }

        return match
    }

    /// Calculates the center point of GPS coordinates
    private func calculateCenterPoint(from points: [Telemetry.GPSPoint]) -> CLLocationCoordinate2D {
        let sumLat = points.reduce(0.0) { $0 + $1.latitude }
        let sumLon = points.reduce(0.0) { $0 + $1.longitude }

        return CLLocationCoordinate2D(
            latitude: sumLat / Double(points.count),
            longitude: sumLon / Double(points.count)
        )
    }

    /// Calculates bounding box for GPS points
    private func calculateBoundingBox(from points: [Telemetry.GPSPoint]) -> (min: CLLocationCoordinate2D, max: CLLocationCoordinate2D) {
        let minLat = points.map { $0.latitude }.min() ?? 0
        let maxLat = points.map { $0.latitude }.max() ?? 0
        let minLon = points.map { $0.longitude }.min() ?? 0
        let maxLon = points.map { $0.longitude }.max() ?? 0

        return (
            min: CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
            max: CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon)
        )
    }

    /// Finds the best matching piste based on GPS trajectory
    private func findBestMatch(
        gpsPoints: [Telemetry.GPSPoint],
        pistes: [OpenStreetMapService.PisteData]
    ) -> PisteInfo? {
        var bestMatch: (piste: OpenStreetMapService.PisteData, score: Double)?

        for piste in pistes {
            let score = calculateMatchScore(gpsPoints: gpsPoints, piste: piste)

            if score > 0.3 { // Minimum confidence threshold
                if let current = bestMatch {
                    if score > current.score {
                        bestMatch = (piste, score)
                    }
                } else {
                    bestMatch = (piste, score)
                }
            }
        }

        guard let match = bestMatch else {
            return nil
        }

        return PisteInfo(
            name: match.piste.name ?? "Piste \(match.piste.id)",
            difficulty: match.piste.difficulty,
            resort: match.piste.resort,
            confidence: match.score
        )
    }

    /// Calculates how well GPS points match a piste
    private func calculateMatchScore(
        gpsPoints: [Telemetry.GPSPoint],
        piste: OpenStreetMapService.PisteData
    ) -> Double {
        var pointsInside = 0

        for point in gpsPoints {
            let location = CLLocation(
                latitude: point.latitude,
                longitude: point.longitude
            )

            // Check if point is within piste boundaries
            if isPoint(location, insidePiste: piste) {
                pointsInside += 1
            }
        }

        // Calculate percentage of points inside piste
        let score = Double(pointsInside) / Double(gpsPoints.count)

        // Adjust score based on altitude if available
        let altitudeMatch = calculateAltitudeMatch(gpsPoints: gpsPoints, piste: piste)
        let adjustedScore = score * 0.8 + altitudeMatch * 0.2

        return adjustedScore
    }

    /// Checks if a point is inside piste boundaries
    private func isPoint(_ location: CLLocation, insidePiste piste: OpenStreetMapService.PisteData) -> Bool {
        // Calculate distance from center
        let pisteCenter = CLLocation(
            latitude: piste.centerLat,
            longitude: piste.centerLon
        )

        let distance = location.distance(from: pisteCenter)

        // Simple circular approximation (500m radius)
        // In a full implementation, this would use polygon containment
        return distance < 500
    }

    /// Calculates altitude match score
    private func calculateAltitudeMatch(
        gpsPoints: [Telemetry.GPSPoint],
        piste: OpenStreetMapService.PisteData
    ) -> Double {
        guard let pisteMinAlt = piste.minAltitude,
              let pisteMaxAlt = piste.maxAltitude else {
            return 0.5 // No altitude data, neutral score
        }

        let altitudes = gpsPoints.map { $0.altitude }
        let videoMinAlt = altitudes.min() ?? 0
        let videoMaxAlt = altitudes.max() ?? 0

        // Check if altitude ranges overlap
        let overlap = min(videoMaxAlt, pisteMaxAlt) - max(videoMinAlt, pisteMinAlt)

        if overlap > 0 {
            return 1.0
        } else {
            return 0.0
        }
    }

    private func makeCacheKey(latitude: Double, longitude: Double, radiusMeters: Double) -> String {
        // 0.01-degree buckets (~1.1km) are sufficient for a 5km search radius.
        let latBucket = (latitude * 100).rounded() / 100
        let lonBucket = (longitude * 100).rounded() / 100
        return "\(latBucket),\(lonBucket),r=\(Int(radiusMeters))"
    }

    private func nearbyPistes(
        cacheKey: String,
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Double
    ) async throws -> [OpenStreetMapService.PisteData] {
        if let cached = pisteCache[cacheKey] {
            nearbyCacheHits += 1
            return cached
        }

        if let task = pisteRequestsInFlight[cacheKey] {
            nearbyInflightJoins += 1
            return try await task.value
        }

        let osm = osmService
        let task = Task<[OpenStreetMapService.PisteData], Error> {
            try await osm.queryNearbyPistes(
                centerLat: centerLat,
                centerLon: centerLon,
                radiusMeters: radiusMeters
            )
        }

        pisteRequestsInFlight[cacheKey] = task
        do {
            let pistes = try await task.value
            pisteCache[cacheKey] = pistes
            pisteRequestsInFlight[cacheKey] = nil
            return pistes
        } catch {
            pisteRequestsInFlight[cacheKey] = nil
            throw error
        }
    }

    private func nearestResortName(
        cacheKey: String,
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Double
    ) async throws -> String? {
        if let cached = resortCache[cacheKey] {
            resortCacheHits += 1
            return cached
        }

        if let task = resortRequestsInFlight[cacheKey] {
            resortInflightJoins += 1
            return try await task.value
        }

        let osm = osmService
        let task = Task<String?, Error> {
            try await osm.queryNearestResortName(
                centerLat: centerLat,
                centerLon: centerLon,
                radiusMeters: radiusMeters
            )
        }

        resortRequestsInFlight[cacheKey] = task
        do {
            let resort = try await task.value
            if let resort {
                resortCache[cacheKey] = resort
            }
            resortRequestsInFlight[cacheKey] = nil
            return resort
        } catch {
            resortRequestsInFlight[cacheKey] = nil
            throw error
        }
    }

    func metricsSnapshot() async -> Metrics {
        let osmMetrics = await osmService.metricsSnapshot()
        return Metrics(
            identifyRequests: identifyRequests,
            nearbyCacheHits: nearbyCacheHits,
            nearbyInflightJoins: nearbyInflightJoins,
            resortCacheHits: resortCacheHits,
            resortInflightJoins: resortInflightJoins,
            nearbyLogicalQueries: osmMetrics.nearbyLogicalQueries,
            resortLogicalQueries: osmMetrics.resortLogicalQueries,
            httpAttempts: osmMetrics.httpAttempts,
            httpSuccesses: osmMetrics.httpSuccesses
        )
    }

    private func dominantResortName(in pistes: [OpenStreetMapService.PisteData]) -> String? {
        var counts: [String: Int] = [:]
        for piste in pistes {
            guard let resort = piste.resort?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !resort.isEmpty else {
                continue
            }
            counts[resort, default: 0] += 1
        }
        return counts.max { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key > rhs.key
            }
            return lhs.value < rhs.value
        }?.key
    }
}

/// Service for querying OpenStreetMap Overpass API
actor OpenStreetMapService {

    struct PisteData {
        let id: String
        let name: String?
        let difficulty: String?
        let resort: String?
        let centerLat: Double
        let centerLon: Double
        let minAltitude: Double?
        let maxAltitude: Double?
        let wayPoints: [CLLocationCoordinate2D]
    }

    private let overpassURLs = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass.openstreetmap.fr/api/interpreter"
    ]
    private let overpassQueryTimeoutSeconds = 8
    private let requestTimeoutSeconds: TimeInterval = 4
    private var nearbyLogicalQueries = 0
    private var resortLogicalQueries = 0
    private var httpAttempts = 0
    private var httpSuccesses = 0

    struct Metrics {
        let nearbyLogicalQueries: Int
        let resortLogicalQueries: Int
        let httpAttempts: Int
        let httpSuccesses: Int
    }

    /// Queries nearby ski pistes from OpenStreetMap
    func queryNearbyPistes(
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Double
    ) async throws -> [PisteData] {
        nearbyLogicalQueries += 1
        // Construct Overpass QL query
        let query = """
        [out:json][timeout:\(overpassQueryTimeoutSeconds)];
        (
          way["piste:type"="downhill"](around:\(radiusMeters),\(centerLat),\(centerLon));
          way["piste:type"="nordic"](around:\(radiusMeters),\(centerLat),\(centerLon));
          relation["piste:type"="downhill"](around:\(radiusMeters),\(centerLat),\(centerLon));
          relation["piste:type"="nordic"](around:\(radiusMeters),\(centerLat),\(centerLon));
        );
        out tags center;
        """

        let data = try await performOverpassQuery(query: query)
        return try parseOverpassResponse(data)
    }

    func queryNearestResortName(
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Double
    ) async throws -> String? {
        resortLogicalQueries += 1
        let query = """
        [out:json][timeout:\(overpassQueryTimeoutSeconds)];
        (
          relation["tourism"="ski_resort"]["name"](around:\(radiusMeters),\(centerLat),\(centerLon));
          way["landuse"="winter_sports"]["name"](around:\(radiusMeters),\(centerLat),\(centerLon));
          relation["landuse"="winter_sports"]["name"](around:\(radiusMeters),\(centerLat),\(centerLon));
          node["place"~"city|town|village|hamlet"]["name"](around:\(radiusMeters),\(centerLat),\(centerLon));
        );
        out body center;
        """

        let data = try await performOverpassQuery(query: query)
        return try parseNearestResortName(
            from: data,
            centerLat: centerLat,
            centerLon: centerLon
        )
    }

    private func performOverpassQuery(query: String) async throws -> Data {
        var errors: [String] = []
        let endpoints = overpassURLs
        let timeout = requestTimeoutSeconds
        let userAgent = "GoPro Highlight Processor"
        httpAttempts += endpoints.count

        return try await withThrowingTaskGroup(of: (endpoint: String, data: Data?, error: String?).self) { group in
            for endpoint in endpoints {
                group.addTask {
                    var components = URLComponents(string: endpoint)
                    components?.queryItems = [URLQueryItem(name: "data", value: query)]

                    guard let url = components?.url else {
                        return (endpoint, nil, "invalid URL")
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.timeoutInterval = timeout
                    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

                    do {
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard let httpResponse = response as? HTTPURLResponse else {
                            return (endpoint, nil, "non-HTTP response")
                        }
                        guard httpResponse.statusCode == 200 else {
                            return (endpoint, nil, "HTTP \(httpResponse.statusCode)")
                        }
                        return (endpoint, data, nil)
                    } catch {
                        return (endpoint, nil, error.localizedDescription)
                    }
                }
            }

            while let result = try await group.next() {
                if let data = result.data {
                    httpSuccesses += 1
                    group.cancelAll()
                    return data
                }
                errors.append("\(result.endpoint): \(result.error ?? "unknown error")")
            }

            throw OSMError.networkUnavailable(errors.joined(separator: " | "))
        }
    }

    func metricsSnapshot() -> Metrics {
        Metrics(
            nearbyLogicalQueries: nearbyLogicalQueries,
            resortLogicalQueries: resortLogicalQueries,
            httpAttempts: httpAttempts,
            httpSuccesses: httpSuccesses
        )
    }

    /// Parses Overpass API JSON response
    private func parseOverpassResponse(_ data: Data) throws -> [PisteData] {
        struct OverpassResponse: Codable {
            let elements: [Element]

            struct Element: Codable {
                let type: String
                let id: Int64
                let tags: [String: String]?
                let lat: Double?
                let lon: Double?
                let nodes: [Int64]?
                let center: Center?
            }

            struct Center: Codable {
                let lat: Double
                let lon: Double
            }
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(OverpassResponse.self, from: data)

        // Build node lookup
        var nodeLookup: [Int64: CLLocationCoordinate2D] = [:]
        for element in response.elements where element.type == "node" {
            if let lat = element.lat, let lon = element.lon {
                nodeLookup[element.id] = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }

        // Process ways (pistes)
        var pistes: [PisteData] = []

        for element in response.elements where element.type == "way" || element.type == "relation" {
            guard let tags = element.tags,
                  tags["piste:type"] != nil else {
                continue
            }

            // Get way points
            var wayPoints: [CLLocationCoordinate2D] = []
            if let nodes = element.nodes {
                wayPoints = nodes.compactMap { nodeLookup[$0] }
            }
            if wayPoints.isEmpty, let center = element.center {
                wayPoints = [CLLocationCoordinate2D(latitude: center.lat, longitude: center.lon)]
            }

            guard !wayPoints.isEmpty else { continue }

            let centerLat: Double
            let centerLon: Double
            if let center = element.center {
                centerLat = center.lat
                centerLon = center.lon
            } else {
                centerLat = wayPoints.map { $0.latitude }.reduce(0, +) / Double(wayPoints.count)
                centerLon = wayPoints.map { $0.longitude }.reduce(0, +) / Double(wayPoints.count)
            }

            let piste = PisteData(
                id: "\(element.id)",
                name: preferredPisteName(from: tags, fallbackID: element.id),
                difficulty: tags["piste:difficulty"],
                resort: preferredResortName(from: tags),
                centerLat: centerLat,
                centerLon: centerLon,
                minAltitude: nil, // OSM doesn't always have altitude
                maxAltitude: nil,
                wayPoints: wayPoints
            )

            pistes.append(piste)
        }

        return pistes
    }

    private func preferredPisteName(from tags: [String: String], fallbackID: Int64) -> String {
        let candidateKeys = [
            "name",
            "piste:name",
            "official_name",
            "ref",
            "destination"
        ]
        for key in candidateKeys {
            if let rawValue = tags[key] {
                let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    return normalized
                }
            }
        }
        return "Piste \(fallbackID)"
    }

    private func preferredResortName(from tags: [String: String]) -> String? {
        let candidateKeys = [
            "piste:site",
            "ski_area",
            "resort",
            "site"
        ]
        for key in candidateKeys {
            if let rawValue = tags[key] {
                let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    return normalized
                }
            }
        }
        return nil
    }

    private func parseNearestResortName(
        from data: Data,
        centerLat: Double,
        centerLon: Double
    ) throws -> String? {
        struct OverpassResponse: Codable {
            let elements: [Element]

            struct Element: Codable {
                let type: String
                let tags: [String: String]?
                let lat: Double?
                let lon: Double?
                let center: Center?
            }

            struct Center: Codable {
                let lat: Double
                let lon: Double
            }
        }

        let response = try JSONDecoder().decode(OverpassResponse.self, from: data)

        struct Candidate {
            let name: String
            let priority: Int
            let distance: CLLocationDistance
        }

        let centerLocation = CLLocation(latitude: centerLat, longitude: centerLon)
        var candidates: [Candidate] = []

        for element in response.elements {
            guard let tags = element.tags else { continue }
            guard let rawName = tags["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawName.isEmpty else {
                continue
            }

            let coordLat: Double
            let coordLon: Double
            if let lat = element.lat, let lon = element.lon {
                coordLat = lat
                coordLon = lon
            } else if let center = element.center {
                coordLat = center.lat
                coordLon = center.lon
            } else {
                continue
            }

            let location = CLLocation(latitude: coordLat, longitude: coordLon)
            let distance = centerLocation.distance(from: location)

            let priority: Int
            if tags["place"] != nil {
                priority = 0
            } else if tags["tourism"] == "ski_resort" || tags["landuse"] == "winter_sports" {
                priority = 1
            } else {
                priority = 2
            }

            candidates.append(Candidate(name: rawName, priority: priority, distance: distance))
        }

        let best = candidates.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            return lhs.name < rhs.name
        }.first

        return best?.name
    }
}

// MARK: - Errors
enum OSMError: LocalizedError {
    case invalidURL
    case requestFailed
    case parsingFailed
    case networkUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid OpenStreetMap API URL"
        case .requestFailed:
            return "Failed to query OpenStreetMap"
        case .parsingFailed:
            return "Failed to parse OpenStreetMap response"
        case .networkUnavailable(let details):
            return "OpenStreetMap network/DNS unavailable: \(details)"
        }
    }
}
