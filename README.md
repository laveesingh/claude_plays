# Coach — a Claude-powered life coach for iOS

A SwiftUI app that simulates a full-time personal life coach. You give it your fitness and
professional goals; it runs your days — because letting things drift is exactly what you
hired it to stop.

The coach is powered by Claude (`claude-opus-4-8` via the Anthropic API), and it doesn't
just chat — it takes real actions in the app through tool use:

| Tool | What the coach actually does |
|---|---|
| `set_daily_plan` | Writes the task list you see on the Today screen |
| `schedule_nudge` | Sends you real push notifications at specific times ("It's 6 PM. Gym. Now.") |
| `record_goal_progress` | Updates your goal tracker with progress notes and % complete |

## Features

- **Onboarding** — name, fitness + professional goals (and *why* they matter), and coach
  intensity: Supportive, Balanced, or **Drill Sergeant** (no excuses mode).
- **Today** — the coach's plan for your day, streak counter, weekly completion stats,
  morning check-in and evening review.
- **Coach** — streaming chat with your coach. It knows your goals, today's plan, your
  streak, and your last 7 days of results — and it will bring them up.
- **Goals** — progress bars and a log of every progress note the coach records.
- **Notifications** — daily morning/evening check-in reminders, plus ad-hoc nudges the
  coach schedules when it doesn't trust you to follow through.

## Setup

1. Open `LifeCoach.xcodeproj` in **Xcode 16 or later** (the project uses folder-synced
   groups; new Swift files dropped into `LifeCoach/` are picked up automatically).
2. Select the LifeCoach target → Signing & Capabilities → choose your team, and change
   the bundle identifier (`com.example.LifeCoach`) to something unique.
3. Build and run on a device (notifications work best on real hardware) or simulator.
   Requires iOS 17+.
4. Get an Anthropic API key at [console.anthropic.com](https://console.anthropic.com) →
   API Keys, and paste it during onboarding (or later in Settings). The key is stored
   only in the device Keychain and is sent only to `api.anthropic.com`.

## How a day works

1. **Morning** — notification fires → tap "Morning check-in". The coach sets your plan
   with 3–6 concrete tasks and schedules a nudge for the hardest one.
2. **During the day** — check tasks off as you do them. The coach's nudges land as push
   notifications.
3. **Evening** — notification fires → "Evening review". The app sends the coach exactly
   what you completed and what you missed (plus your honest reflection). It responds in
   your chosen intensity, logs progress against your goals, and your streak only counts
   days where you finished *everything*.

## Notes

- API usage is billed to your own Anthropic key; coach replies are short, so typical
  usage is a few cents a day.
- The coach is told it is not a doctor, therapist, or financial adviser, and to refer
  you to professionals for anything medical.
- All data (goals, plans, chat history) lives on-device in a local JSON file. "Reset
  everything" in Settings wipes it and deletes the API key.
