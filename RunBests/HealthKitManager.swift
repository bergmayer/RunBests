import Foundation
import Combine
import HealthKit
import CoreLocation

// MARK: - Data model

struct Run: Identifiable, Hashable, Codable {
    let id: UUID
    let start: Date
    let end: Date
    let distanceMeters: Double
    let duration: TimeInterval

    // Workout properties / metadata.
    let energyBurnedKcal: Double?
    let elevationGainMeters: Double?
    let averageHeartRate: Double?   // bpm
    let maxHeartRate: Double?       // bpm
    let temperatureCelsius: Double?
    let humidityPercent: Double?
    let isIndoor: Bool

    /// Sampled GPS positions with cumulative distance, lat/lon and altitude. Nil if no route attached.
    let route: [RoutePoint]?

    var year: Int { Calendar.current.component(.year, from: start) }
    var averageSecondsPerMeter: Double { distanceMeters > 0 ? duration / distanceMeters : 0 }
}

// Runs are identified by HealthKit UUID. Two `Run`s with the same id are equal even if their
// fields differ (e.g. updated heart-rate after a later sync). This keeps `==` and `hash` O(1)
// instead of comparing/hashing the full GPS route, and matches the cache's identity-keyed merge.
extension Run {
    static func == (lhs: Run, rhs: Run) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct RoutePoint: Hashable, Codable {
    let timestamp: Date
    let cumulativeDistance: Double  // meters from start
    let latitude: Double
    let longitude: Double
    let altitude: Double
}

// MARK: - Sync state

enum SyncState: Equatable {
    case idle
    case syncing
    case failed(String)

    var isLoading: Bool { self == .syncing }
    var errorMessage: String? { if case .failed(let m) = self { return m } else { return nil } }
}

struct SyncSummary: Equatable {
    let date: Date
    let addedCount: Int
}

// MARK: - On-disk cache

private struct CachePayload: Codable {
    var runs: [Run]
    var anchorData: Data?
    var version: Int

    static let currentVersion = 4
}

@MainActor
final class RunCache {
    private let fileURL: URL
    private(set) var runs: [Run] = []
    private(set) var anchor: HKQueryAnchor?

    init(filename: String = "RunBestsCache.json") {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = dir.appendingPathComponent(filename)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data) else {
            return
        }
        guard payload.version == CachePayload.currentVersion else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        runs = payload.runs
        if let archived = payload.anchorData,
           let unarchived = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: archived) {
            anchor = unarchived
        }
    }

    func merge(added: [Run], deletedIDs: Set<UUID>, newAnchor: HKQueryAnchor?) {
        if !deletedIDs.isEmpty {
            runs.removeAll { deletedIDs.contains($0.id) }
        }
        if !added.isEmpty {
            var byID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
            for r in added { byID[r.id] = r }
            runs = Array(byID.values)
        }
        runs.sort { $0.start > $1.start }
        if let newAnchor { self.anchor = newAnchor }
        persist()
    }

    func reset() {
        runs = []
        anchor = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Synchronous encode + atomic write on the main actor. Project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
    /// makes Codable conformances MainActor-isolated, which forces this work to stay on main. For typical cache
    /// sizes this is comfortably under one frame; revisit with profiling if a power-user cache shows hitches.
    private func persist() {
        let payload = CachePayload(
            runs: runs,
            anchorData: archivedAnchor(),
            version: CachePayload.currentVersion
        )
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func archivedAnchor() -> Data? {
        guard let anchor else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }
}

// MARK: - HealthKit manager

@MainActor
final class HealthKitManager: ObservableObject {
    @Published private(set) var runs: [Run] = []
    @Published private(set) var state: SyncState = .idle
    @Published private(set) var lastSync: SyncSummary?

    private let store = HKHealthStore()
    private let cache = RunCache()

    init() {
        runs = cache.runs
    }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
        ]
        for id: HKQuantityTypeIdentifier in [.distanceWalkingRunning, .heartRate, .activeEnergyBurned] {
            if let t = HKQuantityType.quantityType(forIdentifier: id) {
                types.insert(t)
            }
        }
        return types
    }

    func requestAuthorizationIfNeeded() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            state = .failed("Health data is not available on this device.")
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
        } catch {
            state = .failed("Health authorization failed: \(error.localizedDescription)")
        }
    }

    /// Incremental sync — only fetches workouts and supporting samples added or deleted since the last sync.
    func loadRuns() async {
        state = .syncing
        defer { if case .syncing = state { state = .idle } }

        do {
            let (newWorkouts, deletedIDs, newAnchor) = try await fetchIncrementalRunningWorkouts(anchor: cache.anchor)
            let added = await buildRuns(from: newWorkouts)

            cache.merge(added: added, deletedIDs: deletedIDs, newAnchor: newAnchor)
            runs = cache.runs
            lastSync = SyncSummary(date: Date(), addedCount: added.count)
        } catch {
            state = .failed("Workout query failed: \(error.localizedDescription)")
        }
    }

    /// Wipes cache + anchor and does a fresh full sync.
    func resync() async {
        cache.reset()
        runs = []
        await loadRuns()
    }

    func run(withID id: UUID) -> Run? {
        runs.first(where: { $0.id == id })
    }

    /// Hydrate `Run`s from incoming workouts. Each workout's route + heart-rate queries run in parallel,
    /// and multiple workouts are processed concurrently up to `Tuning.maxConcurrentWorkoutHydration`
    /// — important for first-time sync where serial processing of hundreds of workouts can take minutes.
    private func buildRuns(from workouts: [HKWorkout]) async -> [Run] {
        guard !workouts.isEmpty else { return [] }
        let maxConcurrent = Tuning.maxConcurrentWorkoutHydration

        return await withTaskGroup(of: Run?.self, returning: [Run].self) { group in
            var nextIndex = 0
            var built: [Run] = []
            built.reserveCapacity(workouts.count)

            let initial = min(maxConcurrent, workouts.count)
            for _ in 0..<initial {
                let workout = workouts[nextIndex]
                nextIndex += 1
                group.addTask { await self.makeRun(from: workout) }
            }

            for await maybeRun in group {
                if let run = maybeRun { built.append(run) }
                if nextIndex < workouts.count {
                    let workout = workouts[nextIndex]
                    nextIndex += 1
                    group.addTask { await self.makeRun(from: workout) }
                }
            }
            return built
        }
    }

    /// Build a single `Run` from a workout, fetching route + heart-rate stats in parallel.
    private func makeRun(from w: HKWorkout) async -> Run? {
        let distance = w.totalRunningDistance()
        guard distance > 0, w.duration > 0 else { return nil }

        async let route = fetchRoutePoints(for: w)
        async let heartRate = fetchHeartRateStats(for: w)
        let routeResult = await route
        let hr = await heartRate

        let meta = w.metadata ?? [:]
        let elevation = (meta[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter())
        let tempC = (meta[HKMetadataKeyWeatherTemperature] as? HKQuantity)?.doubleValue(for: .degreeCelsius())
        let humidity = (meta[HKMetadataKeyWeatherHumidity] as? HKQuantity)?.doubleValue(for: .percent())
        let indoor = (meta[HKMetadataKeyIndoorWorkout] as? Bool) ?? false

        return Run(
            id: w.uuid,
            start: w.startDate,
            end: w.endDate,
            distanceMeters: distance,
            duration: w.duration,
            energyBurnedKcal: w.totalActiveEnergyBurnedKcal(),
            elevationGainMeters: elevation,
            averageHeartRate: hr.average,
            maxHeartRate: hr.max,
            temperatureCelsius: tempC,
            humidityPercent: humidity,
            isIndoor: indoor,
            route: routeResult
        )
    }

    // MARK: HealthKit queries (descriptor-based async APIs)

    private func fetchIncrementalRunningWorkouts(
        anchor: HKQueryAnchor?
    ) async throws -> (added: [HKWorkout], deletedIDs: Set<UUID>, newAnchor: HKQueryAnchor?) {
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForWorkouts(with: .running))],
            anchor: anchor
        )
        let result = try await descriptor.result(for: store)
        let deletedIDs = Set(result.deletedObjects.map(\.uuid))
        return (result.addedSamples, deletedIDs, result.newAnchor)
    }

    private func fetchHeartRateStats(for workout: HKWorkout) async -> (average: Double?, max: Double?) {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            return (nil, nil)
        }
        let predicate = HKSamplePredicate.quantitySample(
            type: hrType,
            predicate: HKQuery.predicateForObjects(from: workout)
        )
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: predicate,
            options: [.discreteAverage, .discreteMax]
        )
        do {
            let stats = try await descriptor.result(for: store)
            let unit = HKUnit.count().unitDivided(by: .minute())
            return (
                stats?.averageQuantity()?.doubleValue(for: unit),
                stats?.maximumQuantity()?.doubleValue(for: unit)
            )
        } catch {
            return (nil, nil)
        }
    }

    private func fetchRoutePoints(for workout: HKWorkout) async -> [RoutePoint]? {
        let routes = await fetchRoutes(for: workout)
        guard !routes.isEmpty else { return nil }

        var allLocations: [CLLocation] = []
        for route in routes {
            allLocations.append(contentsOf: await streamLocations(in: route))
        }
        allLocations.sort { $0.timestamp < $1.timestamp }
        guard allLocations.count >= 2 else { return nil }

        return makeRoutePoints(from: allLocations)
    }

    private func fetchRoutes(for workout: HKWorkout) async -> [HKWorkoutRoute] {
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))],
            anchor: nil
        )
        do {
            let result = try await descriptor.result(for: store)
            return result.addedSamples
        } catch {
            return []
        }
    }

    /// Streams a `HKWorkoutRoute`'s locations via the legacy `HKWorkoutRouteQuery` callback API.
    /// `HKWorkoutRouteQuery` invokes its handler serially per query (Apple's documented contract),
    /// so the reference-typed collector mutated below is safe despite the `@unchecked Sendable`.
    private func streamLocations(in route: HKWorkoutRoute) async -> [CLLocation] {
        let collector = LocationCollector()
        return await withCheckedContinuation { continuation in
            let query = HKWorkoutRouteQuery(route: route) { _, batch, done, _ in
                if let batch { collector.values.append(contentsOf: batch) }
                if done { continuation.resume(returning: collector.values) }
            }
            store.execute(query)
        }
    }

    private func makeRoutePoints(from locations: [CLLocation]) -> [RoutePoint] {
        var points: [RoutePoint] = []
        points.reserveCapacity(locations.count)
        points.append(RoutePoint(
            timestamp: locations[0].timestamp,
            cumulativeDistance: 0,
            latitude: locations[0].coordinate.latitude,
            longitude: locations[0].coordinate.longitude,
            altitude: locations[0].altitude
        ))
        var cumulative = 0.0
        for i in 1..<locations.count {
            let d = locations[i].distance(from: locations[i - 1])
            // Filter unrealistic jumps from brief GPS signal loss.
            if d.isFinite, d >= 0, d < Tuning.maxGpsJumpMeters {
                cumulative += d
            }
            points.append(RoutePoint(
                timestamp: locations[i].timestamp,
                cumulativeDistance: cumulative,
                latitude: locations[i].coordinate.latitude,
                longitude: locations[i].coordinate.longitude,
                altitude: locations[i].altitude
            ))
        }
        return points
    }
}

/// Single-query location accumulator. `HKWorkoutRouteQuery` invokes its handler serially,
/// so unsynchronized mutation is safe — hence `@unchecked Sendable`.
private final class LocationCollector: @unchecked Sendable {
    var values: [CLLocation] = []
}

// MARK: - HKWorkout helpers

private extension HKWorkout {
    func totalRunningDistance() -> Double {
        if let type = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning),
           let stats = statistics(for: type),
           let sum = stats.sumQuantity() {
            return sum.doubleValue(for: .meter())
        }
        return totalDistance?.doubleValue(for: .meter()) ?? 0
    }

    func totalActiveEnergyBurnedKcal() -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
              let stats = statistics(for: type),
              let sum = stats.sumQuantity() else { return nil }
        return sum.doubleValue(for: .kilocalorie())
    }
}
