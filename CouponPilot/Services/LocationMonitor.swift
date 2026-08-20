import CoreLocation

@MainActor
final class LocationMonitor: NSObject, ObservableObject {
    private static let reentryDelay: TimeInterval = 5 * 60
    private static let lastExitTimesKey = "store-geofence-last-exit-times"
    private static let monitoringEnabledKey = "store-geofence-monitoring-enabled"
    enum MonitoringState: Equatable {
        case idle, requestingPermission, needsAlwaysAuthorization, active, denied

        var title: String {
            switch self {
            case .idle: "위치 감지 시작"
            case .requestingPermission: "권한 확인 중"
            case .needsAlwaysAuthorization: "항상 허용 필요"
            case .active: "위치 감지 중"
            case .denied: "위치 권한 필요"
            }
        }
    }

    private let manager = CLLocationManager()
    private var monitoredStores: [Store] = []
    // Core Location can deliver an already-queued entry just after a directory refresh stops
    // that region. Retain its store metadata long enough to handle the real entry instead of
    // silently discarding it because `monitoredStores` was replaced in the meantime.
    private var knownStoresByID: [String: Store] = [:]
    private var isMonitoringEnabled = UserDefaults.standard.bool(forKey: monitoringEnabledKey)
    /// An entry triggers once; leaving the region re-arms that specific store.
    private var storesCurrentlyInside = Set<String>()
    private var lastExitTimes: [String: TimeInterval] = UserDefaults.standard.dictionary(forKey: lastExitTimesKey) as? [String: TimeInterval] ?? [:]
    var onStoreEntry: ((Store) -> Void)?
    var onLocationUpdate: ((CLLocationCoordinate2D) -> Void)?
    @Published private(set) var monitoringState: MonitoringState = .idle
    @Published private(set) var availableStoreCount = 0
    @Published private(set) var monitoredStoreCount = 0

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestPermissionsAndMonitor(_ stores: [Store]) {
        isMonitoringEnabled = true
        UserDefaults.standard.set(true, forKey: Self.monitoringEnabledKey)
        replaceMonitoredStores(stores)
        resumeMonitoringIfEnabled()
    }

    /// iOS allows 20 regions at once. Keep the limit visible to the UI instead of silently
    /// pretending that every nearby store is monitored.
    var isAtRegionLimit: Bool { availableStoreCount > monitoredStoreCount }

    /// Restores a user's opt-in after relaunch. This is called only after the SwiftUI view
    /// installs its location callbacks, so the first position result is not dropped.
    func resumeMonitoringIfEnabled() {
        guard isMonitoringEnabled else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways:
            startMonitoring()
            manager.requestLocation()
        case .authorizedWhenInUse:
            monitoringState = .needsAlwaysAuthorization
        case .denied, .restricted:
            monitoringState = .denied
        case .notDetermined:
            monitoringState = .requestingPermission
            manager.requestWhenInUseAuthorization()
        @unknown default:
            monitoringState = .denied
        }
    }

    func requestCurrentLocation() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .notDetermined:
            monitoringState = .requestingPermission
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            monitoringState = .denied
        @unknown default:
            monitoringState = .denied
        }
    }

    /// Requested only after the user explicitly asks for background store-entry alerts.
    /// This avoids stacking the location and notification permission dialogs on first launch.
    func requestBackgroundAuthorization() {
        guard isMonitoringEnabled, manager.authorizationStatus == .authorizedWhenInUse else { return }
        monitoringState = .needsAlwaysAuthorization
        manager.requestAlwaysAuthorization()
    }

    private func startMonitoring() {
        guard isMonitoringEnabled else { return }
        // iOS supports a maximum of 20 simultaneously monitored regions per app.
        monitoredStores.prefix(20).forEach { store in
            let region = CLCircularRegion(center: store.coordinate, radius: store.radiusMeters, identifier: store.id)
            region.notifyOnEntry = true
            manager.startMonitoring(for: region)
            // An app can start while the user is already inside a store. Ask Core Location for
            // the initial state so that this real entry is not missed while waiting for an exit.
            manager.requestState(for: region)
        }
        monitoringState = .active
    }

    func replaceMonitoredStores(_ stores: [Store]) {
        let incomingIDs = Set(stores.map(\.id))
        manager.monitoredRegions
            .filter { !incomingIDs.contains($0.identifier) }
            .forEach(manager.stopMonitoring)
        availableStoreCount = stores.count
        monitoredStores = Array(stores.prefix(20))
        monitoredStoreCount = monitoredStores.count
        for store in monitoredStores { knownStoresByID[store.id] = store }
        if isMonitoringEnabled && manager.authorizationStatus == .authorizedAlways {
            startMonitoring()
        }
    }

    func stopMonitoring() {
        isMonitoringEnabled = false
        UserDefaults.standard.set(false, forKey: Self.monitoringEnabledKey)
        manager.monitoredRegions.forEach(manager.stopMonitoring)
        monitoredStores = []
        availableStoreCount = 0
        monitoredStoreCount = 0
        knownStoresByID.removeAll()
        storesCurrentlyInside.removeAll()
        monitoringState = .idle
    }
}

extension LocationMonitor: @preconcurrency CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let store = knownStoresByID[region.identifier] else { return }
        triggerStoreEntry(store)
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard state == .inside, let store = knownStoresByID[region.identifier] else { return }
        triggerStoreEntry(store)
    }

    private func triggerStoreEntry(_ store: Store) {
        guard storesCurrentlyInside.insert(store.id).inserted else { return }
        if let lastExit = lastExitTimes[store.id], Date.now.timeIntervalSince1970 - lastExit < Self.reentryDelay {
            return
        }
        onStoreEntry?(store)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        // A later re-entry into this store can now alert the user again.
        storesCurrentlyInside.remove(region.identifier)
        lastExitTimes[region.identifier] = Date.now.timeIntervalSince1970
        UserDefaults.standard.set(lastExitTimes, forKey: Self.lastExitTimesKey)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        onLocationUpdate?(coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location update failed: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            if isMonitoringEnabled {
                startMonitoring()
                manager.requestLocation()
            }
        case .authorizedWhenInUse:
            monitoringState = isMonitoringEnabled ? .needsAlwaysAuthorization : .idle
        case .denied, .restricted:
            monitoringState = .denied
        case .notDetermined:
            break
        @unknown default:
            monitoringState = .denied
        }
    }
}
