import Foundation

// MARK: - Unit system

enum UnitSystem: String, CaseIterable, Identifiable, Codable {
    case imperial
    case metric

    var id: String { rawValue }

    var distanceUnitShort: String { self == .imperial ? "mi" : "km" }
    var paceUnit: String { self == .imperial ? "mi" : "km" }
    var metersPerUnit: Double {
        self == .imperial ? DistanceConstant.metersPerMile : DistanceConstant.metersPerKilometer
    }
    var menuLabel: String { self == .imperial ? "Miles" : "Kilometers" }
    var toolbarShort: String { self == .imperial ? "mi" : "km" }
}

// MARK: - Category

struct PBCategory: Hashable, Identifiable {

    enum Kind: Hashable {
        /// User race or major race. Workouts with total distance in `[distanceMeters, distanceMeters + marginMeters]`
        /// qualify. The category supports four sort modes via `RaceSortMode`.
        case race(distanceMeters: Double, marginMeters: Double)

        /// Fastest contiguous segment of `distanceMeters` anywhere within a run (GPS sliding window).
        case fastestSplit(distanceMeters: Double)

        case longestDistance
        case longestDuration
        case fastestAveragePace
    }

    enum ValueKind {
        case duration       // seconds
        case distance       // meters
        case pace           // seconds per meter
    }

    let id: String
    let name: String
    let kind: Kind

    var isRace: Bool {
        if case .race = kind { return true }
        return false
    }

    var supportsSortToggle: Bool { isRace }

    /// Sort order in the main list. Three disjoint zones:
    /// - Races: their distance in meters ([0, 999_999])
    /// - Best segments: 1_000_000 + distance — always after races
    /// - Overall stats: 2_000_000+ — always last
    var sortKey: Double {
        switch kind {
        case .race(let d, _): return d
        case .fastestSplit(let d): return 1_000_000 + d
        case .longestDistance: return 2_000_000
        case .longestDuration: return 2_000_001
        case .fastestAveragePace: return 2_000_002
        }
    }

    var systemImage: String {
        switch kind {
        case .longestDistance: return "ruler"
        case .longestDuration: return "clock"
        case .fastestAveragePace: return "speedometer"
        case .fastestSplit: return "bolt"
        case .race: return "medal"
        }
    }

    // MARK: Factories

    static func userRace(_ race: UserRaceDistance, margin: Margin) -> PBCategory {
        PBCategory(
            id: "race-\(race.id.uuidString)",
            name: race.displayName,
            kind: .race(
                distanceMeters: race.distanceMeters,
                marginMeters: margin.amount * race.unit.metersPerUnit
            )
        )
    }

    static func halfMarathon(margin: Margin) -> PBCategory {
        PBCategory(
            id: "halfMarathon",
            name: "Half Marathon",
            kind: .race(
                distanceMeters: DistanceConstant.halfMarathonMeters,
                marginMeters: margin.amount * DistanceConstant.metersPerKilometer
            )
        )
    }

    static func marathon(margin: Margin) -> PBCategory {
        PBCategory(
            id: "marathon",
            name: "Marathon",
            kind: .race(
                distanceMeters: DistanceConstant.marathonMeters,
                marginMeters: margin.amount * DistanceConstant.metersPerKilometer
            )
        )
    }

    static func userSegment(_ segment: UserSegmentDistance) -> PBCategory {
        PBCategory(
            id: "segment-\(segment.id.uuidString)",
            name: segment.displayName,
            kind: .fastestSplit(distanceMeters: segment.distanceMeters)
        )
    }

    static let longestDistance = PBCategory(id: "longestDistance", name: "Longest distance", kind: .longestDistance)
    static let longestDuration = PBCategory(id: "longestDuration", name: "Longest duration", kind: .longestDuration)
    static let fastestAvgPace = PBCategory(id: "fastestAvgPace", name: "Fastest average pace", kind: .fastestAveragePace)
}

// MARK: - Personal best

struct PersonalBest: Identifiable, Hashable {
    let category: PBCategory
    let run: Run
    /// Sorted-by value for this entry. Interpreted via `valueKind`.
    let value: Double
    let valueKind: PBCategory.ValueKind

    /// GPS-derived time at the exact race distance. Nil for non-race categories or runs without route data.
    let raceTime: TimeInterval?
    /// The target distance for race categories (cached for display + pace math).
    let raceTargetMeters: Double?

    /// Stable identity for SwiftUI diffing.
    var id: String { "\(category.id)-\(run.id.uuidString)" }

    func display(in units: UnitSystem) -> String {
        switch valueKind {
        case .duration: return Formatters.duration(value)
        case .distance: return Formatters.distance(value, in: units)
        case .pace:     return Formatters.pace(secondsPerMeter: value, in: units)
        }
    }

    // MARK: Race-specific accessors

    var workoutTime: TimeInterval { run.duration }
    var workoutPace: Double {
        run.distanceMeters > 0 ? run.duration / run.distanceMeters : 0
    }
    /// Pace at the exact race distance (seconds per meter). Nil if no GPS-derived race time.
    var racePace: Double? {
        guard let raceTime, let target = raceTargetMeters, target > 0 else { return nil }
        return raceTime / target
    }

    /// Secondary line shown beneath the primary value in the **main list** row (`PBRow`).
    /// Intentionally different from the secondary metric shown in the **detail list** row
    /// (`LeaderboardRow.nonRaceContent`), which has more vertical space and shows the run's
    /// duration / distance / segment time instead of pace.
    func secondaryDisplay(in units: UnitSystem) -> String? {
        switch category.kind {
        case .race:
            return racePace.map { Formatters.pace(secondsPerMeter: $0, in: units) }
        case .longestDistance, .longestDuration:
            guard run.distanceMeters > 0 else { return nil }
            return Formatters.pace(secondsPerMeter: run.duration / run.distanceMeters, in: units)
        case .fastestAveragePace, .fastestSplit:
            return nil
        }
    }

    /// Elapsed seconds for a fastest-split PB.
    var fastestSplitSegmentSeconds: TimeInterval? {
        if case .fastestSplit(let target) = category.kind {
            return value * target
        }
        return nil
    }
}

struct PBLeaderboardSummary: Identifiable, Hashable {
    let category: PBCategory
    let topEntry: PersonalBest
    var id: String { category.id }
}

// MARK: - Calculator

enum PBCalculator {

    /// Best entry per category for the main list. Race categories use `.raceTime` for the primary metric.
    static func topEntries(from runs: [Run], categories: [PBCategory]) -> [PBLeaderboardSummary] {
        categories.compactMap { cat in
            leaderboard(category: cat, runs: runs, sortMode: .raceTime, limit: 1).first
                .map { PBLeaderboardSummary(category: cat, topEntry: $0) }
        }
    }

    /// Up to `limit` entries for a category, sorted by `sortMode`. For non-race categories the sort mode is ignored.
    static func leaderboard(category: PBCategory, runs: [Run], sortMode: RaceSortMode = .raceTime, limit: Int = 20) -> [PersonalBest] {
        switch category.kind {
        case .longestDistance:
            return runs.sorted { $0.distanceMeters > $1.distanceMeters }
                .prefix(limit)
                .map { PersonalBest(category: category, run: $0, value: $0.distanceMeters, valueKind: .distance, raceTime: nil, raceTargetMeters: nil) }

        case .longestDuration:
            return runs.sorted { $0.duration > $1.duration }
                .prefix(limit)
                .map { PersonalBest(category: category, run: $0, value: $0.duration, valueKind: .duration, raceTime: nil, raceTargetMeters: nil) }

        case .fastestAveragePace:
            return runs
                .filter { $0.distanceMeters >= DistanceConstant.metersPerMile && $0.duration >= Tuning.minWorkoutSecondsForAvgPace }
                .map { ($0, $0.duration / $0.distanceMeters) }
                .sorted { $0.1 < $1.1 }
                .prefix(limit)
                .map { PersonalBest(category: category, run: $0.0, value: $0.1, valueKind: .pace, raceTime: nil, raceTargetMeters: nil) }

        case .fastestSplit(let target):
            var results: [(run: Run, pace: Double)] = []
            for run in runs where run.distanceMeters >= target {
                if let s = fastestSplit(in: run, distance: target) {
                    results.append((run, s / target))
                }
            }
            return results
                .sorted { $0.pace < $1.pace }
                .prefix(limit)
                .map { PersonalBest(category: category, run: $0.run, value: $0.pace, valueKind: .pace, raceTime: nil, raceTargetMeters: nil) }

        case .race(let target, let marginMeters):
            let upper = target + marginMeters
            let qualifying = runs.filter { $0.distanceMeters >= target && $0.distanceMeters <= upper }

            let entries: [(run: Run, raceTime: TimeInterval?)] = qualifying.map { run in
                (run, timeToReach(distance: target, in: run))
            }

            let sorted: [(run: Run, raceTime: TimeInterval?)]
            switch sortMode {
            case .raceTime, .racePace:
                // Both depend on raceTime; workouts without GPS are skipped from race-based sorts.
                sorted = entries
                    .filter { $0.raceTime != nil }
                    .sorted { ($0.raceTime ?? .infinity) < ($1.raceTime ?? .infinity) }
            case .workoutTime:
                sorted = entries.sorted { $0.run.duration < $1.run.duration }
            case .workoutPace:
                sorted = entries.sorted {
                    ($0.run.duration / $0.run.distanceMeters) < ($1.run.duration / $1.run.distanceMeters)
                }
            }

            return sorted.prefix(limit).map { entry in
                let (value, valueKind): (Double, PBCategory.ValueKind)
                switch sortMode {
                case .raceTime:    value = entry.raceTime ?? 0;                                              valueKind = .duration
                case .racePace:    value = (entry.raceTime ?? 0) / target;                                   valueKind = .pace
                case .workoutTime: value = entry.run.duration;                                               valueKind = .duration
                case .workoutPace: value = entry.run.duration / max(entry.run.distanceMeters, 1);            valueKind = .pace
                }
                return PersonalBest(
                    category: category,
                    run: entry.run,
                    value: value,
                    valueKind: valueKind,
                    raceTime: entry.raceTime,
                    raceTargetMeters: target
                )
            }
        }
    }

    /// Time from workout start to the moment cumulative GPS distance reaches `target`.
    private static func timeToReach(distance target: Double, in run: Run) -> TimeInterval? {
        guard let pts = run.route, pts.count >= 2 else { return nil }
        guard let first = pts.first, let last = pts.last, last.cumulativeDistance >= target else { return nil }

        for i in 1..<pts.count {
            let a = pts[i - 1]
            let b = pts[i]
            if b.cumulativeDistance >= target {
                let segDist = b.cumulativeDistance - a.cumulativeDistance
                let segTime = b.timestamp.timeIntervalSince(a.timestamp)
                let frac: Double = segDist > 0 ? (target - a.cumulativeDistance) / segDist : 0
                let endTime = a.timestamp.addingTimeInterval(segTime * frac)
                return endTime.timeIntervalSince(first.timestamp)
            }
        }
        return nil
    }

    /// Duration of the fastest contiguous `target`-meter segment anywhere in `run`.
    private static func fastestSplit(in run: Run, distance target: Double) -> Double? {
        guard let pts = run.route, pts.count >= 2 else { return nil }
        guard let totalDist = pts.last?.cumulativeDistance, totalDist >= target else { return nil }

        var best: Double = .infinity
        var j = 0
        for i in 0..<pts.count {
            let startDist = pts[i].cumulativeDistance
            if j < i { j = i }
            while j < pts.count && pts[j].cumulativeDistance - startDist < target {
                j += 1
            }
            guard j < pts.count else { break }
            let needed = startDist + target
            let a = pts[j - 1]
            let b = pts[j]
            let segDist = b.cumulativeDistance - a.cumulativeDistance
            let segTime = b.timestamp.timeIntervalSince(a.timestamp)
            let frac: Double = segDist > 0 ? (needed - a.cumulativeDistance) / segDist : 0
            let endTime = a.timestamp.addingTimeInterval(segTime * frac)
            let elapsed = endTime.timeIntervalSince(pts[i].timestamp)
            if elapsed > 0 {
                best = min(best, elapsed)
            }
        }
        return best.isFinite ? best : nil
    }

    /// Categories in which a specific workout currently places, with its rank and the PB entry.
    /// Race categories use `.workoutTime` ordering so workouts without GPS still appear (their bracket
    /// membership is determined by total distance, independent of route data). The PB entry carries
    /// both race and workout metrics for display, regardless of which one was used for ordering.
    static func rankings(of run: Run, in runs: [Run], categories: [PBCategory], limit: Int = 20)
        -> [(category: PBCategory, rank: Int, total: Int, pb: PersonalBest)]
    {
        categories.compactMap { cat in
            let mode: RaceSortMode = cat.isRace ? .workoutTime : .raceTime
            let entries = leaderboard(category: cat, runs: runs, sortMode: mode, limit: limit)
            return entries.firstIndex(where: { $0.run.id == run.id }).map { idx in
                (cat, idx + 1, entries.count, entries[idx])
            }
        }
    }
}

// MARK: - Formatters

enum Formatters {
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    static func pace(secondsPerMeter: Double, in units: UnitSystem) -> String {
        let perUnit = secondsPerMeter * units.metersPerUnit
        let total = Int(perUnit.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d /%@", m, s, units.paceUnit)
    }

    static func distance(_ meters: Double, in units: UnitSystem) -> String {
        let value = meters / units.metersPerUnit
        return String(format: "%.2f %@", value, units.distanceUnitShort)
    }

    static func energy(_ kcal: Double) -> String {
        String(format: "%.0f kcal", kcal)
    }

    static func heartRate(_ bpm: Double) -> String {
        String(format: "%.0f bpm", bpm)
    }

    static func smallDistance(_ meters: Double, in units: UnitSystem) -> String {
        switch units {
        case .imperial: return String(format: "%.0f ft", meters / DistanceConstant.metersPerFoot)
        case .metric:   return String(format: "%.0f m", meters)
        }
    }

    static func temperature(celsius: Double) -> String {
        let m = Measurement(value: celsius, unit: UnitTemperature.celsius)
        let f = MeasurementFormatter()
        f.unitOptions = .temperatureWithoutUnit
        f.numberFormatter.maximumFractionDigits = 0
        f.locale = .current
        return f.string(from: m)
    }

    /// HKMetadataKeyWeatherHumidity uses HKUnit.percent() — always 0–100.
    static func humidity(_ percent: Double) -> String {
        String(format: "%.0f%%", percent)
    }

    /// Locale-respecting date formatter. Uses `Date.FormatStyle` so locale changes (e.g. user switches
    /// language mid-session) are picked up automatically, unlike a long-lived `DateFormatter` singleton.
    static func dateOnly(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
