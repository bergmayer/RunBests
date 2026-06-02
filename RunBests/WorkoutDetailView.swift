import SwiftUI
import MapKit
import CoreLocation

struct WorkoutDetailView: View {
    let run: Run
    @EnvironmentObject var health: HealthKitManager
    @EnvironmentObject var settings: PBSettings
    @AppStorage(DefaultsKey.unitSystem) private var unitsRaw: String = UnitSystem.imperial.rawValue

    @State private var rankings: [Ranking] = []

    private var units: UnitSystem { UnitSystem(rawValue: unitsRaw) ?? .imperial }

    private var coordinates: [CLLocationCoordinate2D] {
        (run.route ?? []).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private var mapRegion: MKCoordinateRegion? {
        let coords = coordinates
        guard let first = coords.first else { return nil }
        var loLat = first.latitude, hiLat = first.latitude
        var loLon = first.longitude, hiLon = first.longitude
        for c in coords.dropFirst() {
            loLat = min(loLat, c.latitude); hiLat = max(hiLat, c.latitude)
            loLon = min(loLon, c.longitude); hiLon = max(hiLon, c.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (loLat + hiLat) / 2, longitude: (loLon + hiLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((hiLat - loLat) * Tuning.mapBoundingBoxPadFactor, Tuning.minMapSpanDegrees),
                longitudeDelta: max((hiLon - loLon) * Tuning.mapBoundingBoxPadFactor, Tuning.minMapSpanDegrees)
            )
        )
    }

    private struct RankingInputs: Equatable {
        let lastSync: Date?
        let runCount: Int
        let categoryIDs: [String]
    }

    var body: some View {
        List {
            header
            routeMap
            statsSection
            heartRateSection
            weatherSection
            rankingsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Workout")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: RankingInputs(
            lastSync: health.lastSync?.date,
            runCount: health.runs.count,
            categoryIDs: settings.allCategories.map(\.id)
        )) {
            rankings = PBCalculator.rankings(of: run, in: health.runs, categories: settings.allCategories, limit: 20)
                .map { Ranking(category: $0.category, rank: $0.rank, total: $0.total, pb: $0.pb) }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(Formatters.dateOnly(run.start))
                    .font(.title2.weight(.semibold))
                Text(timeRange)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if run.isIndoor {
                    Label("Indoor workout", systemImage: "house.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var routeMap: some View {
        if let region = mapRegion {
            Section {
                Map(initialPosition: .region(region), interactionModes: [.pan, .zoom]) {
                    MapPolyline(coordinates: coordinates)
                        .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    if let first = coordinates.first {
                        Annotation("Start", coordinate: first) {
                            Circle().fill(.green).frame(width: 14, height: 14)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                    if let last = coordinates.last {
                        Annotation("Finish", coordinate: last) {
                            Circle().fill(.red).frame(width: 14, height: 14)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
                .frame(height: 240)
                .listRowInsets(EdgeInsets())
            } header: {
                Text("Route")
            }
        } else if !run.isIndoor {
            Section("Route") {
                Text("No GPS data was recorded for this workout.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statsSection: some View {
        Section("Stats") {
            LabeledRow("Distance", Formatters.distance(run.distanceMeters, in: units))
            LabeledRow("Duration", Formatters.duration(run.duration))
            LabeledRow("Average pace", Formatters.pace(secondsPerMeter: run.averageSecondsPerMeter, in: units))
            if let kcal = run.energyBurnedKcal {
                LabeledRow("Active energy", Formatters.energy(kcal))
            }
            if let elev = run.elevationGainMeters {
                LabeledRow("Elevation gain", Formatters.smallDistance(elev, in: units))
            }
        }
    }

    @ViewBuilder
    private var heartRateSection: some View {
        if run.averageHeartRate != nil || run.maxHeartRate != nil {
            Section("Heart rate") {
                if let avg = run.averageHeartRate {
                    LabeledRow("Average", Formatters.heartRate(avg))
                }
                if let mx = run.maxHeartRate {
                    LabeledRow("Maximum", Formatters.heartRate(mx))
                }
            }
        }
    }

    @ViewBuilder
    private var weatherSection: some View {
        if run.temperatureCelsius != nil || run.humidityPercent != nil {
            Section("Weather") {
                if let t = run.temperatureCelsius {
                    LabeledRow("Temperature", Formatters.temperature(celsius: t))
                }
                if let h = run.humidityPercent {
                    LabeledRow("Humidity", Formatters.humidity(h))
                }
            }
        }
    }

    @ViewBuilder
    private var rankingsSection: some View {
        if !rankings.isEmpty {
            Section("Personal best rankings") {
                ForEach(rankings) { item in
                    RankingRow(item: item, units: units)
                }
            }
        }
    }

    private var timeRange: String {
        let cal = Calendar.current
        let startStr = DateFormatter.localizedString(from: run.start, dateStyle: .none, timeStyle: .short)
        if cal.isDate(run.start, inSameDayAs: run.end) {
            let endStr = DateFormatter.localizedString(from: run.end, dateStyle: .none, timeStyle: .short)
            return "\(startStr) – \(endStr)"
        }
        return startStr
    }
}

private struct Ranking: Identifiable, Hashable {
    let category: PBCategory
    let rank: Int
    let total: Int
    let pb: PersonalBest
    var id: String { category.id }
}

private struct RankingRow: View {
    let item: Ranking
    let units: UnitSystem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: item.category.systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                Text(item.category.name)
                    .font(.body)
                Spacer()
                Text("#\(item.rank) of \(item.total)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            metricsContent
                .padding(.leading, 34)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var metricsContent: some View {
        if item.category.isRace {
            VStack(alignment: .leading, spacing: 2) {
                metricLine(label: "Race",    time: item.pb.raceTime,    pace: item.pb.racePace)
                metricLine(label: "Workout", time: item.pb.workoutTime, pace: item.pb.workoutPace)
            }
        } else {
            singleMetricLine
        }
    }

    @ViewBuilder
    private var singleMetricLine: some View {
        HStack(spacing: 10) {
            Text(item.pb.display(in: units))
                .font(.subheadline.monospacedDigit())
            if let secondary = secondaryDetail {
                Text(secondary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var secondaryDetail: String? {
        switch item.category.kind {
        case .longestDistance:
            return Formatters.duration(item.pb.run.duration)
        case .longestDuration:
            return Formatters.distance(item.pb.run.distanceMeters, in: units)
        case .fastestAveragePace:
            return Formatters.distance(item.pb.run.distanceMeters, in: units)
        case .fastestSplit:
            return item.pb.fastestSplitSegmentSeconds.map { Formatters.duration($0) }
        case .race:
            return nil
        }
    }

    private func metricLine(label: String, time: TimeInterval?, pace: Double?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)
            if let time {
                Text(Formatters.duration(time))
                    .font(.caption.monospacedDigit())
            } else {
                Text("—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let pace {
                Text(Formatters.pace(secondsPerMeter: pace, in: units))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
