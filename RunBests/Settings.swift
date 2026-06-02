import Foundation
import Combine
import SwiftUI

// MARK: - PBSettings store

@MainActor
final class PBSettings: ObservableObject {

    @Published var raceDistances: [UserRaceDistance] { didSet { schedulePersist() } }
    @Published var segmentDistances: [UserSegmentDistance] { didSet { schedulePersist() } }
    @Published var margin: Margin { didSet { schedulePersist() } }
    @Published var halfMarathonEnabled: Bool { didSet { schedulePersist() } }
    @Published var marathonEnabled: Bool { didSet { schedulePersist() } }
    @Published var longestDistanceEnabled: Bool { didSet { schedulePersist() } }
    @Published var longestDurationEnabled: Bool { didSet { schedulePersist() } }
    @Published var fastestAvgPaceEnabled: Bool { didSet { schedulePersist() } }

    /// True while a multi-property mutation is in progress. Suppresses intermediate persists.
    private var isBatching = false

    private struct Payload: Codable {
        var raceDistances: [UserRaceDistance]
        var segmentDistances: [UserSegmentDistance]
        var margin: Margin
        // Optional fields default to true when missing (forward-compat with older payloads).
        var halfMarathonEnabled: Bool?
        var marathonEnabled: Bool?
        var longestDistanceEnabled: Bool?
        var longestDurationEnabled: Bool?
        var fastestAvgPaceEnabled: Bool?
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.preferences),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            raceDistances = payload.raceDistances
            segmentDistances = payload.segmentDistances
            margin = payload.margin
            halfMarathonEnabled = payload.halfMarathonEnabled ?? true
            marathonEnabled = payload.marathonEnabled ?? true
            longestDistanceEnabled = payload.longestDistanceEnabled ?? true
            longestDurationEnabled = payload.longestDurationEnabled ?? true
            fastestAvgPaceEnabled = payload.fastestAvgPaceEnabled ?? true
        } else {
            raceDistances = Self.defaultRaces
            segmentDistances = Self.defaultSegments
            margin = .default
            halfMarathonEnabled = true
            marathonEnabled = true
            longestDistanceEnabled = true
            longestDurationEnabled = true
            fastestAvgPaceEnabled = true
        }
    }

    // MARK: Derived categories

    /// All currently-active categories — user races, opt-in major races, segments, opt-in overall stats.
    var allCategories: [PBCategory] {
        var cats: [PBCategory] = raceDistances.map { PBCategory.userRace($0, margin: margin) }
        if halfMarathonEnabled { cats.append(PBCategory.halfMarathon(margin: margin)) }
        if marathonEnabled    { cats.append(PBCategory.marathon(margin: margin)) }
        cats.append(contentsOf: segmentDistances.map { PBCategory.userSegment($0) })
        if longestDistanceEnabled { cats.append(.longestDistance) }
        if longestDurationEnabled { cats.append(.longestDuration) }
        if fastestAvgPaceEnabled  { cats.append(.fastestAvgPace) }
        return cats.sorted { $0.sortKey < $1.sortKey }
    }

    // MARK: Mutation helpers

    static let maxRaceDistances = 20
    static let maxSegmentDistances = 5

    func addRace() {
        guard raceDistances.count < Self.maxRaceDistances else { return }
        raceDistances.append(UserRaceDistance(value: 1, unit: .imperial))
    }

    func addSegment() {
        guard segmentDistances.count < Self.maxSegmentDistances else { return }
        segmentDistances.append(UserSegmentDistance(value: 1, unit: .metric))
    }

    func resetToDefaults() {
        batchMutations {
            raceDistances = Self.defaultRaces
            segmentDistances = Self.defaultSegments
            margin = .default
            halfMarathonEnabled = true
            marathonEnabled = true
            longestDistanceEnabled = true
            longestDurationEnabled = true
            fastestAvgPaceEnabled = true
        }
    }

    /// Groups multiple property assignments into a single `persist` call.
    private func batchMutations(_ body: () -> Void) {
        isBatching = true
        body()
        isBatching = false
        persist()
    }

    private func schedulePersist() {
        guard !isBatching else { return }
        persist()
    }

    // MARK: Defaults

    static var defaultRaces: [UserRaceDistance] {
        [
            UserRaceDistance(value: 2, unit: .imperial),
            UserRaceDistance(value: 3, unit: .imperial),
            UserRaceDistance(value: 5, unit: .metric),
            UserRaceDistance(value: 5, unit: .imperial),
            UserRaceDistance(value: 10, unit: .metric),
        ]
    }

    static var defaultSegments: [UserSegmentDistance] {
        [
            UserSegmentDistance(value: 1, unit: .metric),
            UserSegmentDistance(value: 1, unit: .imperial),
        ]
    }

    private func persist() {
        let payload = Payload(
            raceDistances: raceDistances,
            segmentDistances: segmentDistances,
            margin: margin,
            halfMarathonEnabled: halfMarathonEnabled,
            marathonEnabled: marathonEnabled,
            longestDistanceEnabled: longestDistanceEnabled,
            longestDurationEnabled: longestDurationEnabled,
            fastestAvgPaceEnabled: fastestAvgPaceEnabled
        )
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.preferences)
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @EnvironmentObject var settings: PBSettings
    @EnvironmentObject var health: HealthKitManager
    @AppStorage(DefaultsKey.unitSystem) private var unitsRaw: String = UnitSystem.imperial.rawValue
    @Environment(\.dismiss) private var dismiss

    @State private var showingResetConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                displaySection
                marginSection
                raceDistancesSection
                majorRacesSection
                segmentDistancesSection
                overallSection
                healthDataSection
                resetSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Reset cached running data?",
                isPresented: $showingResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset and rebuild", role: .destructive) {
                    Task { await health.resync() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Wipes the local cache and re-downloads every running workout from Health. Your personal bests stay accurate; nothing in Health changes.")
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var displaySection: some View {
        Section("Display") {
            Picker("Units", selection: $unitsRaw) {
                ForEach(UnitSystem.allCases) { u in
                    Text(u.menuLabel).tag(u.rawValue)
                }
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var marginSection: some View {
        Section("Margin of error") {
            Picker("Margin", selection: $settings.margin.amount) {
                ForEach(Margin.allowedAmounts, id: \.self) { amount in
                    Text(marginLabel(amount)).tag(amount)
                }
            }
        }
    }

    @ViewBuilder
    private var raceDistancesSection: some View {
        Section("Race distances") {
            ForEach($settings.raceDistances) { $race in
                RaceDistanceRow(race: $race, margin: settings.margin)
            }
            .onDelete { settings.raceDistances.remove(atOffsets: $0) }

            if settings.raceDistances.count < PBSettings.maxRaceDistances {
                Button {
                    settings.addRace()
                } label: {
                    Label("Add race distance", systemImage: "plus.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var majorRacesSection: some View {
        Section("Major races") {
            Toggle("Half Marathon", isOn: $settings.halfMarathonEnabled)
            Toggle("Marathon", isOn: $settings.marathonEnabled)
        }
    }

    @ViewBuilder
    private var segmentDistancesSection: some View {
        Section("Best segment paces") {
            ForEach($settings.segmentDistances) { $segment in
                SegmentDistanceRow(segment: $segment)
            }
            .onDelete { settings.segmentDistances.remove(atOffsets: $0) }

            if settings.segmentDistances.count < PBSettings.maxSegmentDistances {
                Button {
                    settings.addSegment()
                } label: {
                    Label("Add segment pace", systemImage: "plus.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var overallSection: some View {
        Section("Overall records") {
            Toggle("Longest distance", isOn: $settings.longestDistanceEnabled)
            Toggle("Longest duration", isOn: $settings.longestDurationEnabled)
            Toggle("Fastest average pace", isOn: $settings.fastestAvgPaceEnabled)
        }
    }

    @ViewBuilder
    private var healthDataSection: some View {
        Section("Health data") {
            if health.state.isLoading {
                HStack {
                    ProgressView()
                    Text("Syncing…").foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await health.loadRuns() }
                } label: {
                    Label("Sync new runs from Health", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    showingResetConfirm = true
                } label: {
                    Label("Reset and rebuild cache", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
    }

    @ViewBuilder
    private var resetSection: some View {
        Section {
            Button("Reset to defaults", role: .destructive) {
                settings.resetToDefaults()
            }
        }
    }

    // MARK: Helpers

    private func formatted(_ amount: Double) -> String {
        amount.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(amount))"
            : String(format: "%g", amount)
    }

    private func marginLabel(_ amount: Double) -> String {
        amount == 0 ? "0 (exact)" : "+ \(formatted(amount))"
    }
}

// MARK: - Row subviews

private struct RaceDistanceRow: View {
    @Binding var race: UserRaceDistance
    let margin: Margin

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                NumericField(value: $race.value)
                    .frame(maxWidth: 100)

                Picker("Unit", selection: $race.unit) {
                    Text("mi").tag(UnitSystem.imperial)
                    Text("km").tag(UnitSystem.metric)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 120)

                Spacer()
                Text(race.displayName)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(bracketDescription)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var bracketDescription: String {
        let unitShort = race.unit.distanceUnitShort
        if margin.amount == 0 {
            return String(format: "Accepts workouts at exactly %g %@", race.value, unitShort)
        }
        return String(format: "Accepts workouts %g – %g %@", race.value, race.value + margin.amount, unitShort)
    }
}

private struct SegmentDistanceRow: View {
    @Binding var segment: UserSegmentDistance

    var body: some View {
        HStack(spacing: 12) {
            NumericField(value: $segment.value)
                .frame(maxWidth: 100)

            Picker("Unit", selection: $segment.unit) {
                Text("mi").tag(UnitSystem.imperial)
                Text("km").tag(UnitSystem.metric)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 120)

            Spacer()
            Text(segment.displayName)
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - NumericField

/// String-backed numeric field that allows arbitrary intermediate input (including empty), only committing
/// to the bound Double when the text parses as a positive number. Fixes the backspace-locked behavior of
/// `TextField(value:format:)` for required-positive-number inputs.
private struct NumericField: View {
    @Binding var value: Double
    @State private var text: String

    init(value: Binding<Double>) {
        self._value = value
        self._text = State(initialValue: NumericField.format(value.wrappedValue))
    }

    var body: some View {
        TextField("0", text: $text)
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
            .onChange(of: text) { _, newText in
                if let d = Double(newText), d > 0 {
                    value = d
                }
            }
            .onChange(of: value) { _, newValue in
                // External resets (e.g. resetToDefaults) should update the displayed text,
                // but ignore self-induced updates to avoid a feedback loop.
                if (Double(text) ?? -1) != newValue {
                    text = NumericField.format(newValue)
                }
            }
    }

    private static func format(_ d: Double) -> String {
        d.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(d))" : String(format: "%g", d)
    }
}
