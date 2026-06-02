import SwiftUI

@main
struct RunBestsApp: App {
    @StateObject private var health = HealthKitManager()
    @StateObject private var settings = PBSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(health)
                .environmentObject(settings)
                .task {
                    await health.requestAuthorizationIfNeeded()
                    await health.loadRuns()
                }
        }
    }
}
