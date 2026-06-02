# Run Bests

A small iOS app that surfaces your personal best running times from the workouts already in Apple Health.

Apple Fitness records every run but never tells you your fastest 5-mile, 10K, or marathon — and your "5-mile run" is almost never *exactly* 5.0 miles. Run Bests fixes that with **smart distance bracketing**: set a target distance and a margin of error (0, 0.25, 0.5, or 1), and every qualifying workout from your history shows up in one sortable leaderboard.

## Features

- **Race time + workout time** (and pace for each) for every qualifying run, sortable four ways
- **Best segment paces** — your fastest mile or km found anywhere inside any run
- **Half marathon, marathon**, longest distance / duration, fastest average pace
- **Date filters** — all-time, recent windows, single year, custom range
- **Workout detail** — route map, heart rate, active energy, temperature
- **Local-first** — no account, no servers, no tracking. Reads from Apple Health, caches on-device

## Build

Open `RunBests.xcodeproj` in Xcode 15+. Requires iOS 17. Set your development team under Signing & Capabilities, then run on a real iPhone — HealthKit doesn't return any workouts on the simulator unless you seed data manually.

App Store marketing copy variants live in [`info/app-store-copy.txt`](info/app-store-copy.txt).
