import CoreLocation
import Combine
import MapKit

/// Public-data directory refresh can be slow on a cold request. MapKit gives iPhone a fast,
/// keyless first pass for only the franchises the user actually has coupons for.
@MainActor
final class NearbyFranchiseFinder: ObservableObject {
    func findStores(near coordinate: CLLocationCoordinate2D, franchises: [SupportedFranchise]) async -> [Store] {
        guard !franchises.isEmpty else { return [] }
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 3_000, longitudinalMeters: 3_000)
        var found: [Store] = []

        for franchise in franchises {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = franchise.displayName
            request.region = region
            request.resultTypes = .pointOfInterest

            guard let response = try? await MKLocalSearch(request: request).start() else { continue }
            for item in response.mapItems {
                guard let name = item.name, franchise.matches(name) else { continue }
                let location = item.placemark.coordinate
                guard SuwonScope.minimumLatitude...SuwonScope.maximumLatitude ~= location.latitude,
                      SuwonScope.minimumLongitude...SuwonScope.maximumLongitude ~= location.longitude else { continue }
                let distance = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    .distance(from: CLLocation(latitude: location.latitude, longitude: location.longitude))
                guard distance <= 1_600 else { continue }
                let stableID = "mapkit-\(franchise.rawValue)-\(String(format: "%.5f-%.5f", location.latitude, location.longitude))"
                found.append(Store(id: stableID, name: name, category: "카페", latitude: location.latitude, longitude: location.longitude, radiusMeters: 120))
            }
        }

        var seenCoordinates = Set<String>()
        return found.sorted {
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
            < CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude))
        }.filter {
            let key = String(format: "%.5f-%.5f", $0.latitude, $0.longitude)
            return seenCoordinates.insert(key).inserted
        }
    }
}
