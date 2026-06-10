import SwiftUI

// MARK: - Date filter

enum DateFilter: Hashable {
    case allTime
    case year(Int)
    case dateRange(Date, Date)
    case recent(RecentWindow)

    struct RecentWindow: Hashable, Identifiable {
        let value: Int
        /// Use `.day`, `.month`, or `.year`.
        let unit: Calendar.Component

        var id: String {
            let unitKey: String
            switch unit {
            case .day:   unitKey = "d"
            case .month: unitKey = "mo"
            case .year:  unitKey = "y"
            default:     unitKey = "?"
            }
            return "\(value)\(unitKey)"
        }

        var label: String {
            let noun: String
            switch unit {
            case .day:   noun = value == 1 ? "day" : "days"
            case .month: noun = value == 1 ? "month" : "months"
            case .year:  noun = value == 1 ? "year" : "years"
            default:     noun = ""
            }
            return "Last \(value) \(noun)"
        }

        func lowerBound(from now: Date = Date()) -> Date {
            Calendar.current.date(byAdding: unit, value: -value, to: now) ?? now
        }

        static let presets: [RecentWindow] = [
            .init(value: 7,  unit: .day),
            .init(value: 30, unit: .day),
            .init(value: 90, unit: .day),
            .init(value: 6,  unit: .month),
            .init(value: 12, unit: .month),
            .init(value: 2,  unit: .year),
            .init(value: 5,  unit: .year),
        ]
    }

    func contains(_ date: Date) -> Bool {
        switch self {
        case .allTime: return true
        case .year(let y): return Calendar.current.component(.year, from: date) == y
        case .dateRange(let a, let b):
            return date >= min(a, b) && date <= max(a, b)
        case .recent(let w):
            return date >= w.lowerBound()
        }
    }

    var label: String {
        switch self {
        case .allTime: return "All time"
        case .year(let y): return String(y)
        case .dateRange(let a, let b):
            let lo = min(a, b), hi = max(a, b)
            return "\(Formatters.dateOnly(lo)) – \(Formatters.dateOnly(hi))"
        case .recent(let w): return w.label
        }
    }
}

// MARK: - Content view

struct ContentView: View {
    @EnvironmentObject var health: HealthKitManager
    @EnvironmentObject var settings: PBSettings
    @AppStorage(DefaultsKey.unitSystem) private var unitsRaw: String = UnitSystem.imperial.rawValue

    @State private var showingFilter = false
    @State private var showingSettings = false
    @State private var showingHelp = false
    @State private var filter: DateFilter = .allTime

    @State private var summaries: [PBLeaderboardSummary] = []
    @State private var filteredRuns: [Run] = []
    @State private var availableYears: [Int] = []

    private var units: UnitSystem { UnitSystem(rawValue: unitsRaw) ?? .imperial }

    /// Cache key for `.task(id:)`. Uses `lastSync` (a sentinel that changes on every cache update)
    /// and `runCount` instead of `[Run]`, so SwiftUI doesn't deep-compare thousands of `Run` structs
    /// on every render. `lastSync` covers the in-place-update case where count stays the same.
    private struct DerivedInputs: Equatable {
        let lastSync: Date?
        let runCount: Int
        let categories: [PBCategory]
        let filter: DateFilter
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Personal Bests")
                .toolbar { toolbarContent }
                .sheet(isPresented: $showingFilter) {
                    DateFilterSheet(filter: $filter, availableYears: availableYears)
                        .presentationDetents([.large])
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView()
                        .environmentObject(settings)
                        .environmentObject(health)
                }
                .sheet(isPresented: $showingHelp) {
                    NavigationStack { HelpView() }
                }
                .task(id: DerivedInputs(
                    lastSync: health.lastSync?.date,
                    runCount: health.runs.count,
                    categories: settings.allCategories,
                    filter: filter
                )) {
                    recompute()
                }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingHelp = true
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .accessibilityLabel("How it works")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingFilter = true
            } label: {
                Label(filter.label, systemImage: "calendar")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("Settings")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let err = health.state.errorMessage {
            ContentUnavailableView {
                Label("Couldn't load Health data", systemImage: "heart.text.square")
            } description: {
                Text(err)
            } actions: {
                Button("Try again") {
                    Task {
                        await health.requestAuthorizationIfNeeded()
                        await health.loadRuns()
                    }
                }
            }
        } else if health.state.isLoading && health.runs.isEmpty {
            LoadingView(state: health.state, progress: health.syncProgress)
        } else if health.runs.isEmpty {
            ContentUnavailableView(
                "No runs yet",
                systemImage: "figure.run",
                description: Text("Once you log a running workout, your personal bests will appear here.")
            )
        } else {
            List {
                SummarySection(
                    filter: filter,
                    filteredRuns: filteredRuns,
                    units: units,
                    lastSync: health.lastSync,
                    isSyncing: health.state.isLoading,
                    openFilter: { showingFilter = true }
                )

                Section("Records") {
                    if summaries.isEmpty {
                        Text("No qualifying runs for the configured categories in this range.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(summaries) { summary in
                            NavigationLink {
                                PBDetailView(category: summary.category, runs: filteredRuns, units: units)
                            } label: {
                                PBRow(pb: summary.topEntry, units: units)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable {
                await health.loadRuns()
            }
        }
    }

    private func recompute() {
        let runs = health.runs
        let filtered = runs.filter { filter.contains($0.start) }
        filteredRuns = filtered
        availableYears = Array(Set(runs.map(\.year))).sorted(by: >)
        summaries = PBCalculator.topEntries(from: filtered, categories: settings.allCategories)
    }
}

// MARK: - Summary

private struct SummarySection: View {
    let filter: DateFilter
    let filteredRuns: [Run]
    let units: UnitSystem
    let lastSync: SyncSummary?
    let isSyncing: Bool
    let openFilter: () -> Void

    var body: some View {
        Section {
            HStack {
                Label("Runs in range", systemImage: "figure.run.circle")
                Spacer()
                Text("\(filteredRuns.count)")
                    .foregroundStyle(.secondary)
            }
            if let total = totalDistance {
                HStack {
                    Label("Total distance", systemImage: "map")
                    Spacer()
                    Text(Formatters.distance(total, in: units))
                        .foregroundStyle(.secondary)
                }
            }
            if let range = dateRangeText {
                Button(action: openFilter) {
                    HStack {
                        Label("Date range", systemImage: "calendar")
                        Spacer()
                        Text(range)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
            HStack {
                Label(isSyncing ? "Syncing" : "Last synced",
                      systemImage: isSyncing ? "icloud" : "icloud.and.arrow.down")
                Spacer()
                if isSyncing {
                    ProgressView().controlSize(.small)
                } else if let sync = lastSync {
                    Text(syncedText(sync))
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text(filter.label)
        }
    }

    private var totalDistance: Double? {
        guard !filteredRuns.isEmpty else { return nil }
        return filteredRuns.reduce(0) { $0 + $1.distanceMeters }
    }

    private var dateRangeText: String? {
        guard let newest = filteredRuns.first?.start,
              let oldest = filteredRuns.last?.start else { return nil }
        if Calendar.current.isDate(newest, inSameDayAs: oldest) {
            return Formatters.dateOnly(newest)
        }
        return "\(Formatters.dateOnly(oldest)) – \(Formatters.dateOnly(newest))"
    }

    private func syncedText(_ sync: SyncSummary) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let rel = formatter.localizedString(for: sync.date, relativeTo: Date())
        return sync.addedCount > 0 ? "\(rel) (+\(sync.addedCount))" : rel
    }
}

// MARK: - Main-list row

struct PBRow: View {
    let pb: PersonalBest
    let units: UnitSystem

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: pb.category.systemImage)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(pb.category.name)
                    .font(.headline)
                Text(Formatters.dateOnly(pb.run.start))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(pb.display(in: units))
                    .font(.title3.monospacedDigit())
                    .fontWeight(.semibold)
                if let sec = pb.secondaryDisplay(in: units) {
                    Text(sec)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail view

struct PBDetailView: View {
    let category: PBCategory
    let runs: [Run]
    let units: UnitSystem

    @State private var sortMode: RaceSortMode = .raceTime
    @State private var entries: [PersonalBest] = []

    private struct DetailInputs: Equatable {
        let runCount: Int
        let categoryID: String
        let sortMode: RaceSortMode
    }

    var body: some View {
        List {
            if category.supportsSortToggle {
                Section {
                    Picker("Sort by", selection: $sortMode) {
                        ForEach(RaceSortMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }
            Section {
                ForEach(Array(entries.enumerated()), id: \.element.id) { idx, pb in
                    NavigationLink {
                        WorkoutDetailView(run: pb.run)
                    } label: {
                        LeaderboardRow(rank: idx + 1, pb: pb, units: units, sortMode: sortMode)
                    }
                }
            } header: {
                Text("Top \(entries.count)")
            } footer: {
                Text(footerText)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: DetailInputs(runCount: runs.count, categoryID: category.id, sortMode: sortMode)) {
            entries = PBCalculator.leaderboard(category: category, runs: runs, sortMode: sortMode, limit: 20)
        }
    }

    private var footerText: String {
        switch category.kind {
        case .longestDistance:
            return "Single-workout distance, longest first."
        case .longestDuration:
            return "Single-workout duration, longest first."
        case .fastestAveragePace:
            return "Average pace over the whole workout. Walks (<1 mi or <4 min) are excluded."
        case .fastestSplit:
            return "Fastest contiguous segment of this distance found anywhere inside any run (GPS sliding window). Runs without route data are skipped."
        case .race(let target, let marginMeters):
            let upper = target + marginMeters
            return String(
                format: "Workouts in [%@, %@]. \"Race\" times measure the exact distance via GPS; \"workout\" times are the full elapsed time. Tap the sort picker to change ranking.",
                Formatters.distance(target, in: units),
                Formatters.distance(upper, in: units)
            )
        }
    }
}

// MARK: - Leaderboard row

struct LeaderboardRow: View {
    let rank: Int
    let pb: PersonalBest
    let units: UnitSystem
    let sortMode: RaceSortMode

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("#\(rank)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
                .padding(.top, 2)

            if pb.category.isRace {
                raceContent
            } else {
                nonRaceContent
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // MARK: Race row layout — race + workout, time + pace, with sorted-by metric bolded.

    private var raceContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            metricLine(
                label: "Race",
                time: pb.raceTime,
                pace: pb.racePace,
                boldTime: sortMode == .raceTime,
                boldPace: sortMode == .racePace
            )
            metricLine(
                label: "Workout",
                time: pb.workoutTime,
                pace: pb.workoutPace,
                boldTime: sortMode == .workoutTime,
                boldPace: sortMode == .workoutPace
            )
            HStack(spacing: 6) {
                Text(Formatters.distance(pb.run.distanceMeters, in: units))
                Text("·")
                Text(Formatters.dateOnly(pb.run.start))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func metricLine(
        label: String,
        time: TimeInterval?,
        pace: Double?,
        boldTime: Bool,
        boldPace: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)

            if let time {
                Text(Formatters.duration(time))
                    .font(.subheadline.monospacedDigit())
                    .fontWeight(boldTime ? .bold : .regular)
                    .foregroundStyle(boldTime ? .primary : .secondary)
            } else {
                Text("—")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if let pace {
                Text(Formatters.pace(secondsPerMeter: pace, in: units))
                    .font(.subheadline.monospacedDigit())
                    .fontWeight(boldPace ? .bold : .regular)
                    .foregroundStyle(boldPace ? .primary : .secondary)
            } else {
                Text("—")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Non-race row layout — single primary value + context detail (duration / distance / segment time).
    //
    // The detail row deliberately shows a *different* secondary metric than `PersonalBest.secondaryDisplay`
    // (used by the main-list row). The main list is cramped and shows pace, while the detail row has
    // the space to surface run duration, total distance, or segment elapsed time — context the user
    // already loses from pace alone.
    private var nonRaceContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pb.display(in: units))
                .font(.headline.monospacedDigit())
            Text(Formatters.dateOnly(pb.run.start))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let segment = pb.fastestSplitSegmentSeconds {
                Text("Segment: \(Formatters.duration(segment))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if case .longestDistance = pb.category.kind {
                Text(Formatters.duration(pb.run.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .longestDuration = pb.category.kind {
                Text(Formatters.distance(pb.run.distanceMeters, in: units))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .fastestAveragePace = pb.category.kind {
                Text(Formatters.distance(pb.run.distanceMeters, in: units))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Date filter sheet

struct DateFilterSheet: View {
    @Binding var filter: DateFilter
    let availableYears: [Int]
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case allTime = "All time"
        case recent = "Recent"
        case singleYear = "Single year"
        case dateRange = "Date range"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .allTime
    @State private var startYear: Int = Calendar.current.component(.year, from: Date())
    @State private var startDate: Date = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @State private var endDate: Date = Date()
    @State private var recent: DateFilter.RecentWindow = DateFilter.RecentWindow.presets[1]
    @State private var customRecentValue: Int = 30
    @State private var customRecentUnit: Calendar.Component = .day
    @State private var useCustomRecent = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }

                switch mode {
                case .allTime:
                    Section { Text("Includes every run in the cache.").foregroundStyle(.secondary) }

                case .recent:
                    Section("Preset") {
                        Picker("Window", selection: $recent) {
                            ForEach(DateFilter.RecentWindow.presets) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        .disabled(useCustomRecent)
                    }
                    Section("Custom") {
                        Toggle("Use custom window", isOn: $useCustomRecent)
                        if useCustomRecent {
                            Stepper("Last \(customRecentValue) \(unitLabel(customRecentUnit, value: customRecentValue))",
                                    value: $customRecentValue, in: 1...365)
                            Picker("Unit", selection: $customRecentUnit) {
                                Text("Days").tag(Calendar.Component.day)
                                Text("Months").tag(Calendar.Component.month)
                                Text("Years").tag(Calendar.Component.year)
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                case .singleYear:
                    if availableYears.isEmpty {
                        Text("No runs available yet.").foregroundStyle(.secondary)
                    } else {
                        Picker("Year", selection: $startYear) {
                            ForEach(availableYears, id: \.self) { Text(String($0)).tag($0) }
                        }
                    }

                case .dateRange:
                    DatePicker("From", selection: $startDate, displayedComponents: .date)
                    DatePicker("To", selection: $endDate, in: startDate..., displayedComponents: .date)
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply(); dismiss() }
                }
            }
            .onAppear { hydrate() }
        }
    }

    private func unitLabel(_ unit: Calendar.Component, value: Int) -> String {
        switch unit {
        case .day:   return value == 1 ? "day" : "days"
        case .month: return value == 1 ? "month" : "months"
        case .year:  return value == 1 ? "year" : "years"
        default:     return ""
        }
    }

    private func apply() {
        switch mode {
        case .allTime:
            filter = .allTime
        case .recent:
            let win = useCustomRecent
                ? DateFilter.RecentWindow(value: customRecentValue, unit: customRecentUnit)
                : recent
            filter = .recent(win)
        case .singleYear:
            filter = .year(startYear)
        case .dateRange:
            filter = .dateRange(startDate, endDate)
        }
    }

    private func hydrate() {
        switch filter {
        case .allTime:
            mode = .allTime
        case .year(let y):
            mode = .singleYear
            startYear = y
        case .dateRange(let a, let b):
            mode = .dateRange
            startDate = min(a, b)
            endDate = max(a, b)
        case .recent(let w):
            mode = .recent
            if DateFilter.RecentWindow.presets.contains(w) {
                recent = w
                useCustomRecent = false
            } else {
                customRecentValue = w.value
                customRecentUnit = w.unit
                useCustomRecent = true
            }
        }
        if !availableYears.contains(startYear) {
            startYear = availableYears.first ?? startYear
        }
    }
}

// MARK: - Loading view (first-launch + permission)

private struct LoadingView: View {
    let state: SyncState
    let progress: SyncProgress?

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "figure.run")
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(.tint)

            VStack(spacing: 10) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 32)

            if let progress, progress.total > 0 {
                VStack(spacing: 8) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 260)
                    Text("\(progress.processed) of \(progress.total) workouts")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                    .controlSize(.large)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var title: String {
        switch state {
        case .authorizing: return "Connecting to Apple Health"
        case .syncing: return "Syncing Health data"
        case .failed: return "Something went wrong"
        case .idle: return "Loading"
        }
    }

    private var subtitle: String? {
        switch state {
        case .authorizing:
            return "When asked, allow Run Bests to read your running workouts."
        case .syncing:
            return "This can take a moment the first time — we're pulling your full running history from Apple Health."
        case .failed(let message):
            return message
        case .idle:
            return nil
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(HealthKitManager())
        .environmentObject(PBSettings())
}
