# Coach — a Claude-powered life coach + personal assistant for iOS

A SwiftUI app that simulates a full-time life coach merged with a personal assistant:
it doesn't wait for you to message it. It interviews you, timeboxes your days around
your real calendar, pings you block by block, verifies your fitness claims against
HealthKit, critiques you with receipts, and reviews your week like it owns the
outcome — because you hired it to.

## The agent

The coach is a streaming, tool-using agent over real app and OS state. The LLM
backend is pluggable (a `ChatProvider` protocol — see `Providers/`): **Ollama
Cloud** (default, e.g. `kimi-k2.6:cloud` / `minimax-m3:cloud`) and **Claude**
(`claude-opus-4-8` / `sonnet-4-6` / `haiku-4-5`) ship today; switching is manual
in Settings with **no automatic fallback**. Adding another provider is one
conforming type. It holds an 11-tool belt:

| Tool | What it controls |
|---|---|
| `timebox_day` | Writes your actual schedule: timed blocks with lock-screen check-ins armed for each |
| `update_block` | Resolves a block's outcome (done / missed / negotiated skip) |
| `set_habits` | Your standing daily/weekly habits, with adherence tracked over 14 days |
| `update_goal` | Milestones with deadlines, weekly targets, % complete, progress notes |
| `log_metric` | Measurements (weight, 5K time, deep-work hours) → trend charts |
| `update_dossier` | Its private client file on you — schedule, baselines, failure patterns, wins |
| `schedule_nudge` | One-off push notifications in its own voice |
| `read_calendar` | Your real calendar (EventKit), so blocks never collide with meetings |
| `read_health` | Verified HealthKit data: workouts, steps, sleep — it fact-checks you |
| `save_weekly_report` | Written weekly report cards on your Progress screen |
| `mark_intake_complete` | Graduates you from intake to full coaching |

**Two-layer memory.** Recent chat is the working window; everything durable lives in
the dossier the coach maintains itself — and you can read every word of it on the
Progress screen ("What your coach knows about you").

**Session protocols.** Each ritual runs a different playbook at a different effort:

- **Intake interview** (high effort) — 8–12 questions, one at a time: schedule, baselines, injury history, past failures, what makes you quit. Builds the dossier, sets habits, breaks goals into deadlined milestones.
- **Morning brief** — reads your calendar and last night's sleep, judges yesterday in one line, timeboxes today, arms check-ins.
- **Midday correction** — when blocks go overdue unresolved, the Today screen flags it; the coach confronts the slip and replans the remaining hours.
- **Evening debrief** — plan vs. record, block by block, fitness claims checked against HealthKit; logs metrics, updates the dossier, names tomorrow's priority.
- **Weekly review** (high effort) — full 14-day audit, pattern analysis, milestone renegotiation (out loud, never silent), next week's targets, and a written report card.

**The proactive loop (no server required).** iOS won't run an LLM continuously in the
background, so the agent front-loads its presence: every `timebox_day` arms a
pre-start reminder and an interactive end-of-block check-in per block. You answer
**Done / Missed / Ask me in 15** straight from the lock screen; answers write into the
record without opening the app, and the next session starts from that ground truth.
Daily morning/evening pings and a Sunday weekly-review ping are standing.

## Local utility: Qubo bulbs

The **Bulbs** tab scans for powered Qubo HLB10 smart bulbs while the page is open. It reads
their advertised hardware identity and vendor state over Bluetooth, keeps custom names by MAC,
and stores an optional recovery Wi-Fi password in the device Keychain. The current state mapping
is deliberately narrow: observed `S_01` bulbs need setup, observed `S_06` bulbs report a
configured state, and other values remain unknown.

Wi-Fi reprovisioning, Qubo cloud binding, and light controls are not enabled. Qubo does not
publish those Bluetooth payloads, and an official-app pairing capture is required before the app
can send them safely. Use a real iPhone; the simulator cannot scan physical bulbs.

## Setup

1. Open `LifeCoach.xcodeproj` in **Xcode 16+**. Sources are folder-synced — new files
   in `LifeCoach/` are picked up automatically.
2. Target → Signing & Capabilities: pick your team, change the bundle id
   (`com.example.LifeCoach`). The HealthKit capability is already in the entitlements.
3. Run on a **real device** (HealthKit and lock-screen actions need hardware). iOS 17+.
4. Add an API key for your chosen provider during onboarding (or later in Settings):
   **Ollama Cloud** (default) from [ollama.com](https://ollama.com) keys, or
   **Anthropic** from [console.anthropic.com](https://console.anthropic.com). Keys are
   Keychain-only, edit-protected, and sent only to that provider's API. Switch
   provider/model anytime in Settings.
5. Finish onboarding → the coach starts your intake interview.

## Responsibilities & limits

The coach is explicitly charged with sustainable pace: it programs rest, watches
sleep data, and pushes back on overtraining even in Drill Sergeant mode. Pain or
injury → training stops and it refers you to a professional. It is told it is not a
doctor, therapist, or financial adviser, and to drop the coaching posture entirely
and point to professional help if you appear to be in crisis. Tough on behavior,
never on the person.

## Data & cost

All state (goals, schedule history, dossier, chat, reports) is a local JSON file on
device. API usage bills your own key — daily usage is typically cents; weekly reviews
run deeper reasoning and cost more than quick chats. "Reset everything" wipes state
and deletes the key.

## Roadmap (not yet built)

- Background refresh reconciliation (silent overdue-block detection between opens)
- Tier 2: server-side agent + push for true autonomy when the phone stays untouched
- Reminders/Screen Time integration, voice check-ins, multi-week training programs
