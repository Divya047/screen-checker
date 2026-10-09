# ScreenChecker

A macOS menu-bar watchdog that watches the **frontmost window** during your
monitoring slots and **closes tabs it judges distracting** — while explicitly
exempting learning content (tutorials, lectures, docs, coding videos —
including on YouTube).

Built as a Swift package + app bundle (macOS 14+), with a hybrid classifier:
instant local rules first, and a vision LLM (via the local `opencode` CLI and
`mimo-v2.6-pro`) only for ambiguous screens.

## What it does

Every sample tick (default 30s), while the screen is unlocked and awake and the current
time is inside a monitoring slot (default **12:00–21:00** daily, editable):

1. **Sample** — frontmost app, focused window title, active browser tab URL,
   and a screenshot of just that window.
2. **Classify (tier 0 — instant, offline)**
   - learning allowlists / learning title keywords → *productive*
   - protected title keywords (meeting, invoice, bank…) → *productive, never enforced*
   - known distraction patterns (`youtube.com/shorts`, tiktok, reels, reddit,
     netflix, twitch, x.com…) → *distraction*
   - known productive apps/URLs (IDEs, terminal, GitHub, docs…) → *productive*
   - media/game apps (VLC, IINA, Steam…) → *distraction*
   - unknown browser content → **tier 1**
   - unknown non-browser apps → *productive* (fail-open)
3. **Classify (tier 1 — vision LLM, ambiguous cases only)** — the screenshot
   plus app/title/URL metadata goes to `opencode run --agent screen-classifier
   -m opencode-go/mimo-v2.6-pro`, which returns strict JSON
   `{"is_distraction", "confidence", "category", "reason"}`. The agent has
   **zero tools and deny-all permissions**, so an unattended background
   invocation can only look and answer. Any error/timeout/unparseable reply
   → *productive* (fail-open) with the error logged.
4. **Enforce** — distraction verdicts:
   - browsers → **close the active tab** (AppleScript)
   - other apps → **hide** (never force-quit)
   - guarded by: mode must be `enforce`, LLM confidence ≥ threshold,
     a **per-target cooldown** (same app+URL, default 120s) plus a short
     global safety cooldown, protected-title double-guard, and no active learning break.
   - you get a notification with **“This was productive”** (grows the
     allowlist) and **“Reopen tab”** (undoes a closed tab; also in the
     menu bar → *Reopen last closed tab*).
5. **Log** — daily JSONL events (auto-pruned after 90 days),
   viewable as “Report” (today + 7-day trend, config-issue warnings,
   one-click *was productive* / *reopen* buttons). **No screenshots are
   saved** — temp captures are always deleted.

Monitoring pauses while the screen is locked/asleep, **while idle**
(`idleSkipSeconds`, default 120s), outside slots, or during
a **learning break** (menu → “Start 30-min learning break”). Screenshots are
captured **lazily** — only when tier-0 returns ambiguous and the LLM is
enabled — so productive screens never pay the capture cost.

Monitoring pauses while the screen is locked/asleep, outside slots, or during
a **learning break** (menu → “Start 30-min learning break”).

## Quick start

```bash
./scripts/setup.sh          # checks opencode, builds, launches
```

or manually:

```bash
./app/build-app.sh          # -> build/ScreenChecker.app
open build/ScreenChecker.app
```

**First run:** the onboarding window walks you through the one-time
permissions:

| Permission | Why |
|---|---|
| **Screen Recording** | window titles + frontmost-window screenshots — click **Grant…**, toggle ScreenChecker **ON** in Settings, restart the app |
| **Notifications** | distraction alerts + “This was productive” action |
| **Automation** (per browser) | reading/closing the active tab — click **Trigger prompt…** with your browser open, then approve the system dialog (once per browser) |

> After granting Screen Recording, restart the app (macOS rule).
> macOS only prompts once: if you dismissed a prompt earlier, the button
> takes you straight to Settings for the manual toggle — that's the fix,
> not a bug.
> Note: rebuilds re-sign the app ad-hoc, which resets these permissions —
> grant them on the build you intend to keep running.

If the notification prompt never appeared, open the menu →
*Permissions & onboarding…* → **Enable…** next to Notifications. If it says
*denied*, allow it in System Settings → Notifications → ScreenChecker.
(The app deliberately asks only when you click the button — an accessory
menu-bar app that asks at launch often has its prompt swallowed.)

It **starts in warn-only mode** — nothing gets closed until you flip
menu → *Mode: Enforce (close tabs)*. Check **Today’s report** first.

### Trying it immediately (no need to wait for 12:00)

The menu bar has two test commands that bypass the time slots:

- **Check screen now (test)** — samples whatever is frontmost right now,
  classifies it, logs the event. Safe in warn-only mode.
- **Monitor continuously (10 min)** — runs the normal sampling loop for
  10 minutes regardless of slots, then stops by itself.

Flow: open a YouTube Shorts tab → *Check screen now* → **Today’s report**
should show a 🔴 distraction. Open a tutorial → check again → 🟢 productive.
Tap **“This was productive”** on any wrong call to grow the allowlist.

## Configuration

Everything lives in
`~/Library/Application Support/ScreenChecker/config.json`
(editable directly or via Settings…):

```jsonc
{
  "mode": "warnOnly",                  // warnOnly | enforce
  "slots": [ { "start": "12:00", "end": "21:00", "label": "Daytime" } ],
  "skipWeekends": true,
  "sampleInterval": 30,
  "confidenceThreshold": 0.8,          // minimum LLM confidence to enforce
  "enforcementCooldown": 120,          // per-target seconds between actions
  "verdictCacheTTL": 600,             // same app+URL -> reuse verdict
  "learningBreakMinutes": 30,
  "idleSkipSeconds": 120,             // skip ticks when idle (0 disables)
  "llmForAmbiguous": true,
  "keepScreenshots": false,           // always false: evidence disabled
  "screenshotRetentionDays": 0,
  "opencodeModel": "opencode-go/mimo-v2.6-pro",  // *-free models fail via CLI (403)
  "opencodeTimeout": 45,
  "learningChannelPatterns": [ "youtube.com/@freecodecamp", ... ],
  "learningTitleKeywords": [ "tutorial", "lecture", ... ],
  "distractionURLPatterns": [ "youtube.com/shorts", "tiktok.com", ... ],
  "productiveApps": [ "com.apple.dt.Xcode", ... ],
  "protectedTitleKeywords": [ "meeting", "invoice", ... ]
}
```

- Learning rules **always win** over distraction patterns.
- Tapping **“This was productive”** on a notification appends to
  `learningURLPatterns` (YouTube watch URLs pin to the specific video).
- Files: `events/*.jsonl` (90-day log),
  `.opencode/agents/screen-classifier.md` (auto-installed classifier agent).
  `evidence/` is purged on launch and never written.
- Model note (verified 2026-10-09): `*-free` models such as
  `opencode/muse-spark-1.3-contributor-free` return **403 FreeTierError**
  (“free tier can only be used from within OpenCode”) via `opencode run`,
  so the daemon keeps `opencode-go/mimo-v2.6-pro`. Settings warns if you
  pick a `-free` model.

## Privacy & safety design

- Screenshots never leave the machine **except** when tier 1 runs — then one
  frontmost-window PNG goes to *your* opencode model
  (`opencode-go/mimo-v2.6-pro` on your configured provider).
- The tier-1 agent is deny-all/zero-tool/`steps: 1` (see
  `config/screen-classifier.md`) — it can’t touch your filesystem.
- Fail-open everywhere: unknown apps, LLM errors, timeouts, and
  low-confidence verdicts are never enforced.
- Enforcement cooldown + protected keywords stop a bad day by the model from
  closing a stack of real work windows.
- Menu → *Start learning break* suspends sampling entirely for N minutes.

## Development

```bash
swift build && swift test    # 43 unit tests (slots, rules, LLM output parsing, improvements)
./app/build-app.sh           # release bundle + ad-hoc codesign
```

Layout:

```
Sources/ScreenCheckerCore/   # engine, sampler, classifiers, enforcer, stores
Sources/ScreenChecker/        # menu bar app (status item, settings, reports, onboarding)
Tests/ScreenCheckerCoreTests/
config/screen-classifier.md   # canonical LLM agent (auto-installed at runtime)
app/                         # Info.plist + bundle build script
scripts/setup.sh
```

### Notes & limitations

- Chrome/Edge/Brave/Chromium/Safari get tab-level enforcement (close tab);
  Arc and Firefox fall back to app-hide (no usable AppleScript tab API).
- The ad-hoc signature changes on rebuild, so macOS may re-ask for Screen
  Recording after a rebuild (sign with a real identity to avoid this).
- “Launch at login” appears in System Settings → Login Items → allow.
- Safari closes the *front document* (its AppleScript model of the active
  tab); verify during your warn-only trial.
