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

    private let osmService = OpenStreetMapService()
    private var pisteCache: [String: [OpenStreetMapService.PisteData]] = [:]

    /// Identifies which ski piste a video was recorded on based on GPS telemetry
    func identifyPiste(from telemetry: Telemetry) async throws -> PisteInfo? {
        guard !telemetry.gpsPoints.isEmpty else {
            return nil
        }

        // Calculate center point
        let centerPoint = calculateCenterPoint(from: telemetry.gpsPoints)

        // Query nearby pistes from OpenStreetMap
        let pistes = try await osmService.queryNearbyPistes(
            centerLat: centerPoint.latitude,
            centerLon: centerPoint.longitude,
            radiusMeters: 5000 // 5km search radius
        )

        guard !pistes.isEmpty else {
            return nil // No pistes found nearby
        }

        // Find best matching piste
        let match = findBestMatch(
            gpsPoints: telemetry.gpsPoints,
            pistes: pistes
        )

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
            name: match.piste.name ?? "Unknown Piste",
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

    /// Queries nearby ski pistes from OpenStreetMap
    func queryNearbyPistes(
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Double
    ) async throws -> [PisteData] {
        // Construct Overpass QL query
        let query = """
        [out:json][timeout:25];
        (
          way["piste:type"="downhill"](around:\(radiusMeters),\(centerLat),\(centerLon));
          way["piste:type"="nordic"](around:\(radiusMeters),\(centerLat),\(centerLon));
        );
        out body;
        >;
        out skel qt;
        """

        var errors: [String] = []
        for endpoint in overpassURLs {
            var components = URLComponents(string: endpoint)
            components?.queryItems = [URLQueryItem(name: "data", value: query)]

            guard let url = components?.url else {
                errors.append("\(endpoint): invalid URL")
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            request.setValue("GoPro Highlight Processor", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    errors.append("\(endpoint): non-HTTP response")
                    continue
                }
                guard httpResponse.statusCode == 200 else {
                    errors.append("\(endpoint): HTTP \(httpResponse.statusCode)")
                    continue
                }
                return try parseOverpassResponse(data)
            } catch {
                errors.append("\(endpoint): \(error.localizedDescription)")
            }
        }

        throw OSMError.networkUnavailable(errors.joined(separator: " | "))
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

        for element in response.elements where element.type == "way" {
            guard let tags = element.tags,
                  tags["piste:type"] != nil else {
                continue
            }

            // Get way points
            var wayPoints: [CLLocationCoordinate2D] = []
            if let nodes = element.nodes {
                wayPoints = nodes.compactMap { nodeLookup[$0] }
            }

            guard !wayPoints.isEmpty else { continue }

            // Calculate center
            let centerLat = wayPoints.map { $0.latitude }.reduce(0, +) / Double(wayPoints.count)
            let centerLon = wayPoints.map { $0.longitude }.reduce(0, +) / Double(wayPoints.count)

            let piste = PisteData(
                id: "\(element.id)",
                name: tags["name"],
                difficulty: tags["piste:difficulty"],
                resort: tags["piste:site"] ?? tags["operator"],
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
