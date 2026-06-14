# Sapiod — superapp transformation

**Context (PRD).** "Coach" (internal target `LifeCoach`) is being rebuilt as **Sapiod**, a
personal AI superapp. The life-coach becomes *one feature among many*. New features:
intelligent **Inbox** (Gmail triage), **News** (topic feed, web-grounded), **Factscroll**
(reels-style AI facts with a taste engine). Shell = **Home hub + 5 tabs**
(Home · Coach · Inbox · News · Factscroll); Settings via a gear on Home.

**Philosophy.** Features are as pluggable as AI providers: each feature is a self-contained
module (own state model, store, views, optional engine) over a shared platform —
`ChatProvider` (already built), a shared `GroundingService` (web search/fetch), Keychain,
notifications, model registry. Persistence splits per-feature (coach keeps
`lifecoach-state.json` untouched; new features get their own files + an `app.json` for
cross-cutting settings). Extend, never replace.

**Operating rule.** The app must stay runnable and installable on device after **every**
phase. Test gate at each phase boundary. Bundle id stays `com.laveesingh.LifeCoach`.

## Phase 0 — Sapiod shell (current)

- [x] Rename app display name to **Sapiod** (CFBundleDisplayName, both configs); bundle id unchanged
- [x] Feature-module foundation: `FeatureModule` protocol + feature registry; `AppSettings` store (`app.json`) + generic per-feature JSON store helper — with NO change to existing coach `AppState` / `lifecoach-state.json` shape or semantics
- [x] Sapiod shell: Home hub (coach glance widgets + "Coming soon" cards for the 3 new features + gear→Settings) + 5-tab `TabView` (Home · Coach · Inbox · News · Factscroll); Coach tab nests Chat/Today/Progress/Goals; Inbox/News/Factscroll = placeholder views
- [x] Verify: `xcodebuild` (iphoneos) succeeds, install on device, all coach functions reachable + existing data intact → **user test gate** (passed on iPhone 12 mini)

## Phase 1 — Inbox (Gmail) — needs Google OAuth client id from user

- [ ] (expand at phase start) Google Sign-In + Gmail API `gmail.readonly`; pull inbox last 2 days
- [ ] Importance classifier (Action/Human/Money/Security) via `ChatProvider`; reasons + badges
- [ ] Needs-attention rich cards (2–3 line AI summary) + everything-else compact rows (1 line); in-app reading drawer + `googlegmail://` deep link; cache + ~30-min stale background refresh

## Phase 2 — News — builds shared GroundingService

- [ ] (expand at phase start) Editable topics list; `GroundingService` over Ollama `web_search`/`web_fetch` + Anthropic native
- [ ] Timeline feed; summary1 (~30–50w) + drawer summary2 (~150–300w) + sources; auto story number + normalized interest label; dedup + freshness (no stale general knowledge)

## Phase 3 — Factscroll — needs Unsplash access key from user

- [ ] (expand at phase start) Vertical snap-scroll fact feed; 5-frontload + 3-slide buffer generation w/ shimmer; Unsplash cover images
- [ ] Like/dislike/note/share rail; AI taste engine; semantic fact dedup (claims ledger) — **brainstorm with user at phase start**

## Cross-cutting (as features land)

- [ ] Shared `GroundingService` extracted + reused (News, Factscroll, later Coach)
- [ ] Per-feature Settings + per-feature model/effort selection
- [ ] (later) Coach agent reads across feature stores for cross-feature actions
