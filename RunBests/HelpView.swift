import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Text("If you use Apple Fitness to track your runs, you might have noticed that there is no way to pull up your various personal best times. This app does exactly that.")
            }

            Section("Margins") {
                Text("It's rare that you'll run exactly the same distance each time. Your \"5-mile run\" may be 5.1 miles today and 5.05 miles tomorrow. Run Bests lets you bracket together workouts that are within a certain distance range, and then shows you both the \"race\" time and pace (how long it took you to complete just the named distance) and your time and pace for the run as a whole.")
                bullet(
                    title: "Upward only",
                    body: "This margin is only applied upwards. Therefore, your 4.99-mile workout would not count towards the 5-mile category since you did not reach the mark."
                )
                bullet(
                    title: "Available options",
                    body: "You can set the margin to 0, 0.25, 0.5, or 1. Each row shows the actual bracket that it accepts (for example: \"5 mile\" with a margin of 0.25 will accept 5.00–5.25 miles)."
                )
            }

            Section("Setting distances") {
                Text("In the settings view, select the number that you want to modify and then use the mi/km switcher to determine what units you want to use.")
                bullet(
                    title: "Customization",
                    body: "You can save up to ten different distances. Swipe left to remove a saved distance."
                )
                bullet(
                    title: "Defaults",
                    body: "There are five default distances included with this app: 2 miles, 3 miles, 5K, 5 miles, and 10K. But feel free to enter any distance you run at to customize your experience."
                )
            }

            Section("Race time versus workout time") {
                Text("For each qualifying workout, Run Bests will show two things:")
                bullet(
                    title: "Race time",
                    body: "The elapsed time when your GPS odometer crossed the exact target distance. This treats your workout as if it stopped right at the finish line."
                )
                bullet(
                    title: "Workout time",
                    body: "The full elapsed time of the workout, including any extra distance you ran past the target."
                )
                Text("Note: Both metrics will have their own corresponding pace.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Pace for specific segments of your workouts") {
                Text("Best segment paces finds the fastest contiguous stretch of a given distance that was found anywhere inside any of your runs. It will show you your fastest mile whether it came in the middle of a marathon or during the first mile of a casual 3-mile run.")
            }

            Section("Major races & overall records") {
                bullet(
                    title: "Half-marathon & Marathon",
                    body: "These have individual toggles and use the same margin bracket settings."
                )
                bullet(
                    title: "Overall records",
                    body: "You can toggle on/off overall records for longest distance, longest duration, and fastest average pace (calculated for all running workouts of at least 1K)."
                )
            }

            Section("Filters by dates") {
                Text("Tap the calendar icon to filter by all-time, recent windows (last 30 days, last year, custom), a specific year, or a custom date range.")
            }

            Section("Syncing with Health") {
                Text("Run Bests stores a local cache of your running workouts so it can recompute your leaderboard instantly upon launch.")
                bullet(
                    title: "Smart Sync",
                    body: "On launch, it only retrieves workouts added since the last sync."
                )
                bullet(
                    title: "Reset",
                    body: "You can always force a clean reset and rebuild if needed."
                )
            }
        }
        .navigationTitle("How it works")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func bullet(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(body)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack { HelpView() }
}
