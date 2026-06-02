import Foundation

/// All UserDefaults keys live here, so renaming one can't silently break others.
enum DefaultsKey {
    static let unitSystem = "RunBests.unitSystem"
    /// JSON blob holding the full PBSettings.
    static let preferences = "RunBests.preferences"
}

/// Length conversion constants used throughout the app.
enum DistanceConstant {
    static let metersPerMile: Double = 1_609.344
    static let metersPerKilometer: Double = 1_000.0
    static let metersPerFoot: Double = 0.3048

    /// Official race distances in meters.
    static let halfMarathonMeters: Double = 21_097.5
    static let marathonMeters: Double = 42_195
}

/// Tunable thresholds. Centralizing these so they're greppable and a maintainer can find them.
enum Tuning {
    /// A workout must be at least this long to be eligible for "fastest average pace".
    static let minWorkoutSecondsForAvgPace: TimeInterval = 240

    /// Cap on per-sample distance jumps when reconstructing GPS route. Longer is treated as
    /// signal loss and excluded from cumulative distance.
    static let maxGpsJumpMeters: Double = 200

    /// Maximum concurrent workouts hydrated in parallel during a sync.
    static let maxConcurrentWorkoutHydration: Int = 8

    /// Minimum lat/lon span when rendering the workout route map.
    static let minMapSpanDegrees: Double = 0.005

    /// Padding applied to the route map's bounding box.
    static let mapBoundingBoxPadFactor: Double = 1.4
}

// MARK: - User-defined race distances and segments

/// A user-entered race distance (e.g. "5 mile", "5K").
struct UserRaceDistance: Identifiable, Hashable, Codable {
    let id: UUID
    var value: Double
    var unit: UnitSystem

    init(id: UUID = UUID(), value: Double, unit: UnitSystem) {
        self.id = id
        self.value = value
        self.unit = unit
    }

    var distanceMeters: Double { value * unit.metersPerUnit }

    var displayName: String {
        switch unit {
        case .metric:
            if value == 5 { return "5K" }
            if value == 10 { return "10K" }
            return "\(formattedValue) km"
        case .imperial:
            return "\(formattedValue) mile"
        }
    }

    private var formattedValue: String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(value))"
            : String(format: "%g", value)
    }
}

/// A user-entered segment-pace distance ("Best 1 km segment", "Best 1 mile segment").
struct UserSegmentDistance: Identifiable, Hashable, Codable {
    let id: UUID
    var value: Double
    var unit: UnitSystem

    init(id: UUID = UUID(), value: Double, unit: UnitSystem) {
        self.id = id
        self.value = value
        self.unit = unit
    }

    var distanceMeters: Double { value * unit.metersPerUnit }

    var displayName: String {
        let unitWord = unit == .imperial ? "mile" : "km"
        let v = value.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(value))"
            : String(format: "%g", value)
        return "Best \(v) \(unitWord) segment"
    }
}

// MARK: - Margin of error

/// Margin of error, applied upward only. A 5 mi race with amount 0.25 accepts workouts in [5.0, 5.25] mi.
struct Margin: Hashable, Codable {
    /// Amount in the unit of each race (so 0.25 means 0.25 mi for a mile race, 0.25 km for a km race).
    var amount: Double

    static let `default` = Margin(amount: 0.25)
    static let allowedAmounts: [Double] = [0, 0.25, 0.50, 1.00]
}

// MARK: - Sort mode (race detail view)

enum RaceSortMode: String, CaseIterable, Identifiable {
    case raceTime = "Race time"
    case racePace = "Race pace"
    case workoutTime = "Workout time"
    case workoutPace = "Workout pace"
    var id: String { rawValue }
}
