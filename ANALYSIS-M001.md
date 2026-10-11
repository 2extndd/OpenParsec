# OpenParsec — M001 Repository Analysis & Remediation Milestone

> Consolidated from a 7-agent parallel audit (6 subsystem code reviews + 1 web best-practices
> researcher) cross-checked against `HANDOFF.md` at commit `fc6776c`, branch `fix/trackpad-input`.
> Every finding is `file:line`, root-caused, with a concrete fix. This document IS the milestone plan.
> Analysis only — no code was changed producing this document.

---

## 0. How to read this

The user's lived complaints map to findings as follows:

| User complaint | Primary cause(s) | Slice |
|---|---|---|
| "Interface disappears after screen auto-return" | Render loop left paused + EAGLContext not re-currented on foreground | **S01** |
| "App crashes during scroll / in general" | `mouseInfo` CGImage retain/release data race; unsafe signal handler; poll-loop teardown race | **S02** |
| "Scroll still choppy/bad" | Native iPadOS momentum + client CADisplayLink inertia double-applied (2× on 120 Hz iPad); Windows wheel-unit mismatch | **S03** |
| "Language won't switch by any keys" | Hidden detector field loses first responder → notification never fires (client-side, not just host config) | **S05** |
| "Let Ctrl+Shift = Cmd+Space on Mac host" + "do we even detect host OS?" | No host-OS detection exists; `hostOS` is decoded then discarded | **S04 → S05** |
| "Make it fly even on bad internet — strip stream latency to the minimum" | `lowLatencyMode` umbrella exists but ignores bitrate, compatibility, and the hardcoded `netProtocol`/`mediaContainer`; no poor-link bitrate cap | **S08** |
| "Trackpad dead-zone, only inside Parsec" | Pointer-lock without `preferredScreenEdgesDeferringSystemGestures` → system owns the bottom-edge strip | **S09** |
| "Bug when switching the host monitor" | `changeDisplay` is a soft push: no `isReconfiguring` guard (false disconnect alert), no GL resume (black), `output` outside the S06 confirmation gate (needs multiple taps) | **S10** |

Severity legend: **HIGH** = crash / feature-broken, **MED** = wrong behavior, **LOW** = cleanup/latent.

---

## S01 — Render resume / black screen on return  `risk:high` `depends:[]`

**Why it happens.** The Parsec SDK renders directly into the GLKView's framebuffer inside
`glkView(_:drawIn:)` — there is no app-side framebuffer. The only thing keeping the surface live is
`GLKViewController.isPaused == false` *and* a valid `EAGLContext`/drawable. Two independent breakages:

- **R1 [HIGH]** `isPaused` is set `true` in `changeResolution` (`ParsecView.swift:557`) and reset `false`
  only inside a `+0.6 s` timer (`ParsecView.swift:572`). `viewDidAppear` (`ParsecViewController.swift:408-419`)
  does **not** reset it. Any transition (PiP, scene background, SwiftUI re-render, interrupted res-change)
  that returns to the Parsec screen leaves the loop possibly paused → frozen/black.
- **R2/R3 [HIGH]** On background→foreground iOS invalidates the GL drawable / context currency.
  `SceneDelegate.sceneWillEnterForeground` is empty; nothing calls `EAGLContext.setCurrentContext` or
  forces drawable re-creation. `ParsecClientGLRenderFrame` then renders into a stale framebuffer → black.
- **R4 [MED]** GLKView added to hierarchy twice (`ParsecGLKViewController.swift:46` then re-added at `:66`,
  then moved at `ParsecViewController.swift:252-254`); frame is `UIScreen.main.bounds` at create time and
  only updated on rotation, not on return — can desync/zero-size on re-entry.
- **R5 [MED]** `cleanUp()` is an empty stub (`ParsecGLKViewController.swift:74-76`) — no defined stop/resume
  contract, so paused state leaks across connect/disconnect.
- **R6 [LOW]** Metal renderer files are 100% commented dead code; only GLK is live. Delete to remove ambiguity.

**Best-practice (researched).** Apple's rule: pause the CADisplayLink + dispose framebuffer on background;
on foreground make context current, re-create the drawable, **set `isPaused = false` LAST**, then force one
`setNeedsDisplay`. Metal equivalent: never call `nextDrawable()` backgrounded; wrap frames in `@autoreleasepool`.

**Fix.** Make resume idempotent and self-healing:
1. In `viewDidAppear`/`viewWillAppear`: `EAGLContext.setCurrentContext(glkView.context)` then `isPaused = false`.
2. Register `ParsecViewController` for `UIApplication.willEnterForegroundNotification` to do the same
   (scene plumbing doesn't reach this VC today).
3. Implement `cleanUp()` = `isPaused = true` and a symmetric `resume()`; pin GLKView to `contentView.bounds`
   via autoresizing mask; call sizing in `viewDidLayoutSubviews`.

**Verify.** Stream → background app / change resolution / enter+exit PiP → return: interface must repaint
every time (currently goes black on at least one path).

---

## S02 — Concurrency & crash hardening  `risk:high` `depends:[]`

**Why it happens.** Shared mutable state crosses threads without synchronization.

- **C1 [HIGH] `mouseInfo` data race / use-after-free.** `ParsecSDKBridge.mouseInfo` (struct holding a
  `CGImage?`) is written on the **poll thread** (`handleCursorEvent`, `ParsecSDKBridge.swift:316-348`,
  esp. `cursorImg` at `:348`) and on the **GC handler queue** (`sendMousePosition` writes `mouseX/Y`
  at `:449-450`), and read on **main** (`updateImage`, `ParsecViewController.swift:111-152`). `updateImage`
  even re-reads `CParsec.mouseInfo` mid-frame (`:149-152`). Concurrent ARC retain/release on `cursorImg`
  is non-atomic → over-release → **use-after-free**. This is the most likely "random crash" and it fires
  whenever the cursor image churns (i.e. constantly during pointer motion). **Fix first.**
  *Fix:* guard all `mouseInfo` access behind `os_unfair_lock` (or a serial queue) exposing one atomic
  `snapshot()`; `updateImage` consumes only the snapshot.
- **C2 [HIGH] Signal handler is async-signal-unsafe.** `AppDelegate.swift:17-41` calls
  `ISO8601DateFormatter`, Swift `String` interpolation, `Thread.callStackSymbols` (`backtrace_symbols`→malloc),
  and `write(to:atomically:)` *inside* the `signal()` trampoline. If the crashing thread holds the malloc
  lock (typical for SIGSEGV) this **deadlocks** → no log, hung app. So the crash reporter you're relying on
  to diagnose the other crashes is itself unreliable.
  *Fix:* in the signal handler use only `write(2)` to a **pre-opened fd** with pre-allocated buffers, then
  `signal(s, SIG_DFL); raise(s)`. Keep the `NSException` handler (runs in normal context). Or adopt
  MetricKit `MXCrashDiagnostic` (iOS 14+) / PLCrashReporter / KSCrash.
- **C3 [MED] Poll-loop teardown race.** `disconnect()` drains via `Thread.sleep(0.02)` not a join
  (`ParsecSDKBridge.swift:165-185`); a fast reconnect (`connect()` at `:125`) can spawn new loops while old
  ones still run → up to 4 loops on one client, stale `ParsecGetBuffer`/`ParsecFree`.
  *Fix:* monotonic `pollGeneration` captured per loop; loop exits when generation advances.
- **C4 [LOW] CADisplayLink retain cycle** is self-breaking (momentum decays + deinit invalidates) but a
  `WeakProxy` target would make `deinit` reachable mid-glide.
- **C5 [LOW] `audio_destroy` use-after-free** (`audio.c`): `free(ctx)` then `AudioQueueFreeBuffer(ctx->q,…)`.
  Pre-existing, teardown-only.

**⚠ Cross-agent contradiction to resolve on-device.** Web research says `GCController.handlerQueue`
defaults to **main** (so GC handlers would be UIKit-safe); the code sets no `handlerQueue`. But the shipped
`fc6776c` fix proves a real off-main UIKit crash occurred via GCMouse. Confirm empirically which queue
`GCMouse.mouseInput` handlers actually fire on before deciding whether C1's GC-thread write path is live.
Either way the **poll-thread** write of `mouseInfo` is off-main, so C1 stands.

**Verify.** Stress cursor motion + external mouse for minutes (TSan build if feasible); force a crash and
confirm `last_crash.log` is written without hanging.

---

## S03 — Scroll rework (the recurring complaint)  `risk:med` `depends:[S04]`

**Why it happens.** iPadOS does **not** expose a momentum phase on `UIPanGestureRecognizer`; it synthesizes
deceleration as continued `.changed` events. The code forwards those *and* runs its own CADisplayLink
inertia on top → **double-applied momentum**, with a visible velocity discontinuity at the handoff.

- **SC1 [HIGH]** Double inertia (`ParsecViewController.swift:747-869`). At default strength the client tail
  adds ~1.07 s of glide *after* the native tail.
- **SC2 [HIGH/feeds SC1]** Momentum seed hardcodes 60 Hz (`peak/60`, `:809-810`); on the user's 120 Hz M4
  iPad the tick fires 2× as often → **inertia distance doubles**. This is why it feels worst for them.
- **SC3 [MED]** No host-OS wheel-unit scaling. Parsec wheel = pixels on macOS but **line/notch on Windows**;
  forwarding raw points makes Windows scroll wildly over-sensitive/steppy (`ParsecSDKBridge.swift:608`).
  Needs the host-OS signal from **S04**.
- **SC4 [MED]** `naturalScrolling`/`scrollSensitivity` ignored on the touchscreen 2-finger path
  (`ParsecViewController.swift:657` still uses `velocity/20` + `mouseSensitivity`).
- **SC5 [MED]** Zoom early-return leaks stale `lastScrollTranslation` (`:751-753`) → host jump after zoom.
- **SC6 [MED]** No `coalescedTouches` on the cursor path (`:463-497`) → polygonal/juddery fast cursor.
- **SC7 [LOW]** GCMouse scroll/move truncate with no accumulator (`GameController.swift:114,130,135`).

**Best-practice (researched).** Moonlight-iOS deleted GCMouse scroll and client inertia entirely; it forwards
raw pan deltas on `.changed` with two recognizers (`UIScrollTypeMaskContinuous` + `Discrete`,
`allowedTouchTypes = .indirectPointer`). Momentum rides in as native continued events.

**Fix (recommended, canonical).** Remove `startScrollMomentum`/`scrollMomentumTick`/peak tracking and the
`scrollMomentum*` settings; forward native deltas only. Add `coalescedTouches` iteration on the cursor path.
Unify all three scroll paths through one accumulator honoring `naturalScrolling`/`scrollSensitivity`. Scale
wheel output to host units (per S04 host-OS). Keep cursor acceleration linear (let host curve).

**Verify.** One smooth decelerating glide on flick (no speed "kick"); identical natural-scroll direction across
trackpad / external mouse / 2-finger touch; Windows-host scroll no longer steppy.

---

## S04 — Host-OS detection  `risk:med` `depends:[]`

**Why it matters.** Enables the Ctrl+Shift→Cmd+Space gate (S05), Windows wheel units (S03), and auto-mode for
the Windows key remap.

- **HO1 [enabling gap]** `ParsecUserDataVideo.hostOS` (`ParsecUserData.swift:7`) **is decoded** in case 11
  (`ParsecSDKBridge.swift:255-256`) but the `main.async` block (`:258-269`) never reads it — discarded.
- **HO2 [empirical unknown]** The Int→OS mapping is undocumented (no framework headers vendored). Public
  Parsec `parsec.h` has **no dedicated OS field** (`ParsecHostMode` HOST_DESKTOP/HOST_GAME is a weak proxy).
  So the value must be discovered, not guessed.

**Fix.**
1. **Discovery first:** log case-11 `hostOS` + REST `HostInfo.build`/`mode` (`NetworkHandler.swift:37,45` —
   `build` is OS-tagged and available *before* connect) against the M3 Mac and the Windows host. Stash to the
   existing crash-log/clipboard channel since there's no local console.
2. Add `@Published var hostOS: Int = -1` to `SharedModel` (`Shared.swift`) + a plain `Int` mirror on the
   bridge (lock-free read from input threads). Write it in the case-11 main block. **Reset to -1 in both
   `connect()` and `disconnect()`** or a stale value bleeds across a host switch.
3. Wrap the mapping in one `enum HostOS` so the empirical values live in a single place.

**Verify.** Connect to each host; logged value is stable and distinguishes Mac vs Windows.

---

## S05 — Keyboard: language-sync fix + Ctrl+Shift→Cmd+Space  `risk:med` `depends:[S04]`

**Why language sync looks broken (client-side, not just host config).**

- **K1 [HIGH]** The hidden `LanguageSyncTextField` must hold first responder for
  `currentInputModeDidChangeNotification` to fire. `viewDidAppear` makes the *VC* FR (`:414-416`) right before
  starting the hidden field (`:418`) → FR contention; and on Magic Keyboard the user switches layout with no
  visible field. If the field isn't the steady-state FR, **the chord never fires** — matching "won't switch
  by any keys." (`ParsecViewController.swift:1505-1539`, `:408-419`.)
- **K2 [MED]** FR not reclaimed after OS-route keyboard dismissal. `keyboardWillHide` (`:595-614`) never calls
  `languageSync?.reclaimFirstResponder()`; swipe-to-dismiss / Esc / Globe silently kills sync.
- **K3 [LOW]** Spurious hotkey at session start is a seed-vs-first-notification race (`:1524` async seed vs
  `:1563-1580` handler), not a layout-count issue. *Fix:* treat first observed change as the seed.
- **K7 [LOW]** No `pressesCancelled`/`pressesChanged` on the VC (`:555-569`) → cancelled key events drop
  key-up → stuck modifier on host.

**New feature: physical Ctrl+Shift → Cmd+Space (Mac host only).** Feasible in `pressesBegan/Ended`. Add a
modifier-only chord state machine (researched macOS technique): arm when Ctrl+Shift both held; set
`sawOtherKey` if any non-modifier is pressed during the chord; on clean release with `!sawOtherKey` fire
`tapKey(modifierKey:"LGUI", normalKey:"SPACE")`. Keep forwarding raw scancodes unchanged so Ctrl+Shift+X
host shortcuts still work. Gate behind a new `@AppStorage("ctrlShiftEmulatesCmdSpace")` toggle **and**
`hostOS == .macos` (from S04). Note: this is a *chord rewrite*, so it must live at `tapKey`/chord level,
**not** the per-scancode `remapKeyForHostIfNeeded`. This feature also doubles as a clean diagnostic to
separate "client never fired" (K1) from "host shortcut unbound."

- **K5 [LOW-MED]** Captured-key modifier holds release on timers (`:1320-1325`); rapid Cmd+letters can drop
  Cmd mid-combo. Reference-count modifier holds.
- **K6 [OK]** Windows scancode swap (`ParsecSDKBridge.swift:435-444`) is correct; add a comment that Shift
  must stay unmapped for the auto-shift logic.

**Verify.** With host shortcut bound: Caps-Lock layout toggle switches host; Ctrl+Shift alone fires Cmd+Space
on Mac host; Ctrl+Shift+arrow still selects on host; sync survives a soft-keyboard dismiss.

---

## S06 — Video-config debounce & send-gate  `risk:low` `depends:[]`

- **V1 [MED]** `updateHostVideoConfig` (`ParsecSDKBridge.swift:655-681`) schedules 2 resends + a getVideoConfig
  echo per call; the case-11 echo writes `DataManager.model.bitrate` back (`:261`). Rapid menu taps stack
  timers and the echo clobbers the user's in-flight selection (checkmark jumps). *Correction to HANDOFF:*
  bitrate is a discrete `Menu`, not a slider — so "snap mid-drag" can't happen literally, but rapid-tap
  value-clobber is real. *Fix:* `configRevision` token; skip superseded resends; treat echo as
  confirmation-only for user-owned fields (`bitrate`/`constantFps`/`output`), still accept host-authoritative
  `resolutionX/Y`.
- **V2 [LOW-MED]** `sendUserData` (`:646-653`) is the **only** send method missing
  `guard backgroundTaskRunning`. Add it for consistency (NULL-deref protection during reconnect gap).

**Verify.** Rapid bitrate/display taps don't bounce the checkmark; no sends during the reconnect gap.

---

## S07 — Correctness cleanup  `risk:low` `depends:[]`

- **Q1 [HIGH]** `cursorScale`/`hideStatusBar` share UserDefaults key `"cursorScale"`
  (`SettingsHandler.swift:10` & `:45`; `SettingsView.swift:12` & `:23`). Confirmed runtime corruption: a
  `Double` cursor scale coerces `hideStatusBar` to `true`; a `false` toggle zeroes cursor size (invisible
  cursor). *Fix:* give `hideStatusBar` its own key in both files + one-time migration clamping stored
  `cursorScale` to `0.1…4`.
- **Q2 [MED]** `cancelConnection` force-unwraps `pollTimer!` (`MainView.swift:631`) → crash if Cancel tapped
  before the timer schedules. Use `pollTimer?.invalidate(); pollTimer = nil`.
- **Q3 [MED]** Pervasive `try!`/`as! HTTPURLResponse`/ignored `error` in network paths (`MainView.swift:438,
  443,467,504,509,514,553,557,577`; `LoginView.swift:197,202,219`) → malformed response crashes app.
  Guard-let + graceful alerts; drop debug `print(...!)`.
- **Q4 [MED]** Verify `ViewContainerPatch` static `[UIViewController:UIViewController]` dicts
  (`ViewContainerPatch.swift:32,47`) don't strongly retain the ParsecVC across reconnects (leak of GLKView +
  recognizers). Clear with `nil` on disconnect or use `NSMapTable.weakToWeakObjects()`.
- **Q5 [LOW]** Dead `.test`/`TestView` route shipping a debug view; large commented blocks; `infoDictionary!`;
  "Unknown versino" typo; `URLImage` refetch-on-every-onAppear. Cleanup pass.

---

## S08 — Low-latency / poor-network stream profile  `risk:med` `depends:[S06]`

**What the user asked for.** "Make everything fly even on bad internet — drop stream latency to the
absolute minimum, then run a separate test." There's already a `lowLatencyMode` umbrella
(`SettingsHandler.swift:53`) but it only flips three knobs (`preferredFramesPerSecond = 0`,
`decoder = .h265`, `noOverlay = true`, `SettingsView.swift:233-241`) plus strips the ~80 ms key-hold delays
(`ParsecViewController.swift:1338-1348`). It never touches the levers that actually decide whether a
**weak link** stays smooth.

**Honest tension to resolve in the design (not gloss over).** "Reduce everything to minimum" and "works on
bad internet" pull in opposite directions on exactly one axis — **bitrate**:
- *Minimum glass-to-glass latency on a good link* wants high fps + enough bitrate + no buffering.
- *Resilience on a bad link* wants a **capped, lower** bitrate so the encoder can't outrun the uplink and
  induce bufferbloat/queuing latency — which is the dominant cause of "laggy on bad WiFi."

So this is not one slider to "minimum." It's a coherent **Poor-Network profile** that minimizes the
latency-adding knobs while *capping* bitrate to fit a constrained link. The design must state this tradeoff
in the UI copy so the toggle isn't misread as "max quality + min lag."

**Levers that exist in code (all real, all currently un-wired to low-latency):**
- **N1 — bitrate ceiling.** `DataManager.model.bitrate → encoderMaxBitrate` (`ParsecSDKBridge.swift:659`),
  sent host-side via `updateHostVideoConfig` (`:655-681`). Today `lowLatencyMode` leaves it untouched. A
  poor-network profile should clamp it to a low ceiling (e.g. ~5–10 Mbps) so the encoder targets the link,
  not the ceiling.
- **N2 — `decoderCompatibility` adds latency.** When on it forces a more conservative decode path
  (`ParsecSDKBridge.swift:140/146/369/375`); the profile must force it **off** (`SettingsHandler.swift:48`),
  which `lowLatencyMode` does not do today.
- **N3 — `netProtocol` is hardcoded `1`** (`ParsecSDKBridge.swift:68`, applied at `:379`) and never surfaced.
  This is the Parsec transport selector and is the single most network-relevant SDK knob. **Semantics are
  unverified** — the framework headers aren't vendored (same constraint as `hostOS` in S04 and the SDK gaps
  in HANDOFF §1), so the meaning of `0` vs `1` must be confirmed empirically before exposing it. Do **not**
  guess-flip it blind.
- **N4 — `mediaContainer` hardcoded `0`** (`ParsecSDKBridge.swift:69`, applied at `:378`). Same unverified-
  semantics caveat as N3; touch only after empirical confirmation.
- **N5 — poll timeout already fps-scaled** (`ParsecSDKBridge.swift:618-624`): `max(1000/fps, 8)`. With
  `preferredFramesPerSecond = 0` (device max, 120 Hz on the M4 iPad) this is already near-minimal — verify it
  isn't re-clamped elsewhere; otherwise leave it.
- **N6 — `constantFps`/`fullFPS`** (`ParsecSDKBridge.swift:660`): on a weak link, leaving full-FPS **off**
  lets the host drop frames instead of queuing them, which lowers latency under loss. Fold into the profile.

**Fix (recommended).**
1. **Upgrade `lowLatencyMode` into a real profile** (keep the same `@AppStorage` key so saved prefs survive):
   on enable, additionally set `decoderCompatibility = false`, cap `bitrate` to a poor-network ceiling, and
   leave `constantFps` off. Keep "users can still override individually after" (the existing comment promise).
2. **Surface `netProtocol`/`mediaContainer`** as advanced pickers **only after** an empirical discovery pass
   confirms their values (reuse the S04 discovery-logging channel — crash-log/clipboard, since there's no
   local console). Until confirmed, they stay hardcoded; do not ship a blind toggle.
3. **Route the bitrate change through S06's `configRevision` token** — this is why `depends:[S06]`: the
   profile mutates `DataManager.model.bitrate`, and without S06's send-gate/echo-as-confirmation fix the
   case-11 echo (`ParsecSDKBridge.swift:261`) will clobber the profile's value back. Land S06 first or together.
4. Copy must name the tradeoff: e.g. "Poor Network — caps bitrate and strips buffering for responsiveness over
   sharpness." Not "maximum quality."

**Separate test (the user explicitly asked for this).** Constrained-link verification, on-device:
- Use **Network Link Conditioner** (iOS Developer settings) or a host-side `tc`/router shaper to emulate a
  bad link: ~5 Mbps down, 80–150 ms RTT, 1–3% loss. Compare profile **off vs on**.
- Measure glass-to-glass responsiveness (cursor-move → on-screen reaction) and visible stall/freeze frequency
  over a 2-minute session under the shaped link. Profile-on should show fewer stalls and lower input-to-photon
  lag; record the bitrate the host actually negotiates (case-11 echo) to confirm the cap took effect.
- Negative check: on a **good** link the profile must not look obviously worse than baseline beyond the
  expected sharpness drop — i.e. no new stutter introduced by the knobs.
- This is a dedicated UAT separate from S01/S02 device tests; gate the slice on its pass.

**Verify.** Profile toggles all six knobs in one shot; bitrate cap is reflected in the host echo; constrained-
link session is measurably smoother with the profile on; no regression on a good link; saved-prefs key
unchanged so existing users keep their setting.

---

## S09 — Trackpad dead-zone (defer system edge gestures)  `risk:low` `depends:[]`

**What the user reported.** A trackpad dead-zone on the iPad Magic Keyboard that appears **only inside
Parsec**, not system-wide.

**Discarded hypothesis.** A subagent flagged "double-added `glkView`" (added to `view` at
`ParsecViewController.swift:46/71`, then to `contentView` at `:246-247`). Rejected: a view has exactly one
superview, so the second `addSubview` *reparents*, it does not duplicate. Full-screen frame +
flexible `autoresizingMask` means it fills `contentView` correctly. Not the cause.

**Root cause.** Pointer-lock without deferring system edge gestures:
- `prefersPointerLocked = true` (`ParsecViewController.swift:73`) — the pointer is captured in-app. This is
  unique to Parsec, which is exactly why the dead-zone shows up nowhere else.
- `prefersHomeIndicatorAutoHidden` is overridden (`:77`), but
  `preferredScreenEdgesDeferringSystemGestures` is **defined nowhere in the project** (grepped whole repo —
  0 hits). So the bottom edge — where the Magic Keyboard sits and where the locked pointer travels when
  moving "down toward the keys" — stays owned by the system swipe-up / Control-Center recognizer. iPadOS
  keeps an interceptor strip there; with the pointer locked, trackpad motion landing in that strip is partly
  eaten by the system gesture and never reaches the app's pointer handling → felt as a dead-zone.

**Fix (small, isolated).**
```swift
override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { return .all } // or [.bottom]
```
plus call `setNeedsUpdateOfScreenEdgesDeferringSystemGestures()` next to the existing
`setNeedsUpdateOfPrefersPointerLocked()` (`ParsecViewController.swift:291`). Canonical fix for
streaming/game apps with a locked pointer.

**Open question (verify on-device).** If the dead-zone tracks the keyboard inset rather than the screen
edge, the secondary suspect is the direct-mode coordinate convert (`contentView.convert(pos, from: view)`,
`ParsecViewController.swift:467`): when the keyboard shows, `scrollView.contentInset.bottom` changes but
`contentView.frame` does not, desyncing the visible region from the coordinate space. Different fix — must
first observe whether the zone is pinned to the screen edge or to the inset.

**Verify.** On M4 iPad + Magic Keyboard: locked-pointer motion reaches the bottom edge with no dead strip;
no regression to home-indicator hide or Control-Center access on a deliberate second swipe.

---

## S10 — Monitor-switch hardening  `risk:med` `depends:[S06]`

**What the user reported.** A bug when switching the host monitor (the "Switch Display" picker).

**Path.** `changeDisplay(displayId:)` (`ParsecView.swift:626-645`) sets `DataManager.model.output`, persists
the choice, and pushes it host-side via `updateHostVideoConfig()` (`ParsecSDKBridge.swift:760`). Unlike
`changeResolution`, it is a **soft** video-config push — no disconnect/reconnect, no GL pause/resume, no
`isReconfiguring` guard. That asymmetry is the source of the problems below.

**Three concrete defects (all code-grounded).**

- **D1 — false "Disconnected" alert on switch.** Switching the streamed monitor makes the host re-init its
  encoder for the new display (usually a different resolution), which forces a client-side decoder reset.
  During that window `getStatusEx` briefly returns non-OK. The 0.2 s poll loop treats any non-OK as a real
  drop and pops `"Disconnected (code …)"` (`ParsecView.swift:90-116`) — suppressed **only** when
  `isReconfiguring` is true. `changeResolution` raises that flag (`ParsecView.swift:552`); `changeDisplay`
  **never does**. So a normal monitor switch can flash a spurious disconnect alert.
- **D2 — possible black/stale surface after switch.** The decoder reset for the new monitor's resolution can
  leave the GL drawable stale. `changeResolution` brackets its gap with `isPaused = true` then
  `isPaused = false` (`ParsecView.swift:556-557,571-572`); `changeDisplay` touches neither, so there is no
  resume guarantee on the switch — same failure class as S01 but on a path S01's `viewDidAppear`/foreground
  hooks don't cover (no screen transition happens here).
- **D3 — `output` is outside the S06 confirmation gate.** `pendingUserConfig` tracks only bitrate +
  constantFps (`ParsecSDKBridge.swift:775`); the case-11 echo adopts/confirms those and resolution but
  **never reads `output`** (`:318-350`). The 250 ms resend + getVideoConfig poke (`:786-794`) is the only
  "did it land" mechanism, and case-12 re-restore is one-shot via `didRestoreSavedDisplay` (`:366`). If the
  host drops both sends, the UI shows the new display selected while the stream never switched — this is the
  "needed two or three taps" symptom, only partially mitigated today. `depends:[S06]` because the fix rides
  the same `configRevision`/echo machinery.

**Secondary (minor).** A switch to a different-resolution monitor updates `DataManager.model.resolutionX/Y`
from the host echo but does **not** update `SettingsHandler.resolution`. A later reconnect (`connect()` reads
`SettingsHandler.resolution`, `ParsecSDKBridge.swift:200-201`) would then snap back to the pre-switch
resolution. Worth aligning so the switched monitor survives a reconnect.

**Fix (recommended).**
1. Bracket `changeDisplay` with a short `isReconfiguring = true` window (or a dedicated `isSwitchingDisplay`
   flag honored by `poll()`) so the transient non-OK during the host's encoder reset doesn't pop the
   disconnect alert. Clear it after the echo confirms or a timeout.
2. Call `glkView?.resume()` (the S09… S01 idempotent resume) once the switch lands, to guarantee the surface
   repaints if the decoder reset blanked it.
3. Fold `output` into the S06 confirmation path: track the pending output, treat the case-11 echo (or a
   decoder-resolution change consistent with the target display) as confirmation, and stop the resend once
   confirmed instead of relying on a fixed 250 ms double-send.
4. Keep `SettingsHandler.resolution` in sync when the host reports the switched monitor's resolution, so a
   reconnect doesn't revert it.

**Verify (on-device, M4 iPad).** Switch between two host monitors of *different* resolutions repeatedly:
no spurious "Disconnected" alert, surface repaints every time (no black), switch takes on the first tap, and
a manual reconnect after a switch keeps the switched monitor's resolution.

---

## Dependency graph & suggested order

```
S01 (black screen)  ─┐  highest user impact, independent
S02 (crashes)       ─┤  highest stability impact, independent
S04 (host-OS)       ─┼─► S03 (scroll, needs wheel units)
                     └─► S05 (keyboard, needs Mac gate)
S06 (video debounce) ─┬► S08 (low-latency profile, mutates bitrate through S06's send-gate)
                      └► S10 (monitor switch, folds `output` into the send-gate/echo)
S07 (cleanup)        ── independent (Q1/Q4 worth pulling early)
S09 (trackpad dead-zone) ── independent (tiny, screen-edge gesture deferral)
```

Recommended execution: **S01 → S02 → S04 → S03 → S05 → S06 → S08 → S10 → S07**, with **S09** droppable
anywhere (independent, tiny). S01 and S02 are the two the user feels most (black screen, crashes) and have
no dependencies. S08 and S10 both land after S06 because all three edit the video-config send path —
S08's bitrate cap and S10's `output` confirmation both ride S06's `configRevision` token.

## Hard constraints (cannot be fixed client-side — confirmed)

1. macOS host resolution downscale (no virtual display) — bitrate/H.265 are the real levers.
2. Hiding the host's own physical cursor — needs a host-side helper.
3. System shortcuts (Cmd+Space/H/Tab, Globe) — SpringBoard-level.
4. Layout sync requires the host shortcut bound (independent of K1/K2).

## Open verification items (not assumptions)

- GCMouse handler queue (main vs background) — resolve the cross-agent contradiction on-device.
- `hostOS` Int→OS mapping — empirical discovery session required.
- All builds are CI-only (no local Xcode); plan changes to compile clean in one CI pass.
