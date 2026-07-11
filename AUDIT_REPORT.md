# Random Incident Generator — Commit 7.1 Audit

Audit date: 2026-07-11. Scope: unpacked source archive `beamng_random_incident_agent_audit_commit7_1.zip`, active mod, supplied runtime log, local Steam BeamNG.drive source, and official BeamNG documentation. No game or mod source was changed for this audit.

## 1. Executive Summary

- **[VERIFIED_IN_CURRENT_CODE]** The supplied archive's `current_mod` and both local copies of the active extension have the same SHA-256 for `randomIncidents.lua` (`A7B05E...B7DA8`). The active mod is `C:\Users\danyp\AppData\Local\BeamNG\BeamNG.drive\current\mods\unpacked\random_incident_generator`.
- **[VERIFIED_IN_CURRENT_CODE]** Commit 7.1 is a working, constrained single-family runtime: declarative trigger definitions, seeded ambient sampling, road planning, repeat/spawn cleanup, controller states, transient brake release, and separate same/opposite-flow ambient roles are already present.
- **[VERIFIED_IN_RUNTIME_LOG]** The supplied run spawned 6 scripted + 6 ambient vehicles, selected a direct opposite one-way carriageway, completed the TTC trigger chain, and repeated the scene twice without a recorded spawn failure.
- **[VERIFIED_IN_CURRENT_CODE]** It is not yet a procedural generator: only `sudden_obstacle_pileup` is registered; vehicle choices, actor counts, speeds, gaps, and road profile are mostly template constants. There is no collision telemetry, outcome report, obstacle support, lifecycle hook handling, or public `generateRandomScenario`.
- **[VERIFIED_IN_BEAMNG_SOURCE]** GE Lua is the correct owner for orchestration, map access, spawning, lifecycle hooks, and telemetry. Vehicle AI commands must continue to cross into Vehicle Lua via `vehicle:queueLuaCommand`.
- **[VERIFIED_IN_RUNTIME_LOG]** A new P0 is confirmed: Car A repeatedly re-entered `FOLLOWING`, the runtime resent a full AI command, and `driveUsingPath` was eventually called with the one-node path `{"Bridge30_2"}`. BeamNG then raised `lua/common/mathlib.lua:274` through `lua/vehicle/ai.lua:newManualPath` and logged `DISABLING VEHICLE DUE TO EXCEPTION`.
- **[INFERENCE_REQUIRES_GAME_TEST]** One-week MVP remains realistic only if Commit 7.2 first makes FOLLOWING path-safe/idempotent, Commit 7.3 makes long-run diagnostics exportable, and only then starts Commit 8. Physics remains reproducible *configuration*, not bit-identical outcome.

## 2. Current Architecture Map

```text
scenarioRegistry + scenarios/suddenObstaclePileup
       │ definition (actors, triggers, ambient configuration)
       ▼
randomIncidents.lua
  harvest navgraph → road/lane plan → actor specs → spawn → generatedScene
       │                                      │
       │                                      ├─ ambientTraffic.lua (seeded ambient specs)
       │                                      └─ queueLuaCommand → Vehicle Lua AI
       ▼
onUpdate → controller state machine → triggerEngine.update → action executor
       │
       └─ runtime trigger events / repeat/reset/clear
```

- **[VERIFIED_IN_CURRENT_CODE]** `randomIncidents.lua` (3,163 lines) owns harvesting, road/lane planning, opposite-carriageway discovery, spawning, actor controller state, action execution, lifecycle, diagnostics, and the public surface. It is now the practical monolith.
- **[VERIFIED_IN_CURRENT_CODE]** `triggerEngine.lua` (609 lines) is generic: it validates trigger definitions and owns delayed actions, groups, dependencies, fallbacks, reset, and event records; it deliberately does not know BeamNG objects.
- **[VERIFIED_IN_CURRENT_CODE]** `ambientTraffic.lua` produces deterministic same-flow specs from its local LCG and contains no BeamNG spawn calls. Opposite flow is planned in the main extension and then fed through the same sampler.
- **[VERIFIED_IN_CURRENT_CODE]** `scenarioRegistry.lua` validates scenario declarations and registers one definition. The scenario declaration presently mixes a reusable template with sampled values (specific models, five fixed gaps and fixed speeds).
- **[VERIFIED_IN_CURRENT_CODE]** `generatedScene` currently combines sampled scene data, live object references indirectly via `generatedVehicles`, trigger runtime, controller state, diagnostics, and timeline. This is the main boundary to split incrementally.

## 3. Verified BeamNG APIs and Source Paths

Official documentation deliberately does not offer complete API reference and directs modders to source; this agrees with the local source audit. The extension documentation confirms GE/Vehicle VM placement, explicit load/unload, dependency ordering, and `onUpdate` hooks. [Programming overview](https://documentation.beamng.com/modding/programming/), [Extensions](https://documentation.beamng.com/modding/programming/extensions/)

| API / concept | Local source and verified use | Applicability and risk |
|---|---|---|
| Extension hooks and update | **[VERIFIED_IN_BEAMNG_SOURCE]** `lua/ge/main.lua:update` calls `extensions.hook('onUpdate', dtReal, dtSim, dtRaw)` before physics. `lua/ge/main.lua:703,743` emits `onVehicleSpawned(vid,v)` and `onVehicleDestroyed(vid)`. | Use these hooks for session lifecycle and stale-ID cleanup. Hook names are source-established but not a versioned public contract. |
| GE ↔ Vehicle Lua | **[VERIFIED_IN_BEAMNG_SOURCE]** `queueLuaCommand` is used throughout `lua/ge/extensions/scenario/scenariohelper.lua:50-180`, traffic, race, and flowgraph code. | Correct bridge for actor AI and Vehicle Lua probes. Commands are asynchronous; no return value proves execution. Keep generated strings narrow and data-only. |
| AI routing | **[VERIFIED_IN_BEAMNG_SOURCE]** `lua/vehicle/ai.lua:6970-7002` exports `setMode`, `setSpeed`, `setSpeedMode`, `setAvoidCars`, `driveUsingPath`, `laneChange`, `setStopPoint`. `scenariohelper.lua:setAiPath` demonstrates `driveUsingPath{wpTargetList, routeSpeed, routeSpeedMode, driveInLane, avoidCars}`. | Current use is valid. `driveInLane` documentation says it is correct only on bidirectional one-lane-each-direction roads; do not treat it as a lane reservation API. `setAvoidCars(false)` intentionally makes scripted actors unsafe. |
| AI lane change | **[VERIFIED_IN_BEAMNG_SOURCE]** `ai.laneChange` is exported; `gameplay/traffic/baseRole.lua:38-48` queues `ai.laneChange(nil, dist, sideDist)` after a 0.25 s plan-rebuild delay and comments that it needs improvement. | API exists but is internal/unstable-quality for this purpose. Commit 12 requires a map/model proof matrix and fallback-to-brake; no public guarantee of a controlled collision trajectory. |
| Map and navgraph | **[VERIFIED_IN_BEAMNG_SOURCE]** `lua/ge/map.lua:getMap`, `getGraphpath`, `getRoadRules`, `getNodeLinkCount`, and path functions are local GE exports. `map.getMap().nodes` plus `map.getGraphpath().graph` are the current mod's source. Nav links provide `oneWay`, `inNode`, `drivability`, `type`. | Useful, but node/link field layout is an internal data contract. Sort IDs/candidates before any seed choice. `drivability` is route cost/availability, not a safety/geometry certificate. |
| Vehicle spawn | **[VERIFIED_IN_BEAMNG_SOURCE]** `lua/ge/spawn.lua:747-802` implements `spawn.spawnVehicle(model, partConfig, pos, rot, options)`; it configures a `BeamNGVehicle`. Its preceding code contains bbox/safe-placement helpers. `randomIncidents.lua:1590` directly creates/spawns vehicles and logs successful local runs. | Prefer the official `spawn.spawnVehicle` wrapper for new work and keep explicit config allowlists. Current direct routine has worked, but does not call the wrapper's safe-placement checks. |
| Vehicle lifecycle / registry | **[VERIFIED_IN_BEAMNG_SOURCE]** `lua/ge/extensions/core/vehicles.lua:onVehicleDestroyed`; `onVehicleSpawned`/`Destroyed` are global GE hook dispatches. | Add own handlers; current extension exports neither lifecycle hook nor an unload/mission cleanup hook. IDs can become stale after destruction/map change. |
| Position, velocity, damage | **[VERIFIED_IN_BEAMNG_SOURCE]** `map.lua:3624-3674` stores `map.objects[id].pos`, `.vel`, `.damage`, `.objectCollisions`; direct object methods are used by current code (`getPosition`, `getVelocity`). `gameplay_util_damageAssessment` reads `getSectionDamageSum`, `getSectionBeamDamage`, and `getSectionCollisionDamage`. | `map.objects` is a good GE cache; direct calls should be kept to a bounded sample cadence. Damage is an evidence signal, not a complete collision detector. |
| Contact/collision | **[VERIFIED_IN_BEAMNG_SOURCE]** Vehicle `lua/vehicle/mapmgr.lua:105-140` calls native `obj:getObjectCollisionIds` and forwards IDs to `map.objectData`; `map.lua` stores them. Official `scenario/scenarios.lua:1681-1703` emits `onObjectCollision` only inside an active scenario's tracking loop. | Direct polling of `map.objects[id].objectCollisions` is available in a normal GE extension. Do not rely on `onObjectCollision` unless this mod owns an actual BeamNG Scenario. |
| Crash detector | **[VERIFIED_IN_BEAMNG_SOURCE]** `lua/ge/extensions/gameplay/util/crashDetection.lua` exports `addTrackedVehicleById`, `removeTrackedVehicleById`, and emits `onVehicleCrashStarted`, `onNewImpactStarted`, `onVehicleCrashEnded`. It tracks damage/acceleration and collision IDs. | Valuable severity/impact augmentation, but it is a gameplay utility with thresholds and delayed crash completion, not a stable public telemetry API. It must be loaded and tested in the target game version. |
| Traffic system | **[VERIFIED_IN_BEAMNG_SOURCE]** `lua/ge/extensions/gameplay/traffic.lua` owns normal traffic pools/respawn; `gameplay/traffic/vehicle.lua` reads contact state. | Do not enrol scripted actors in global traffic: its respawn/pooling can fight scenario ownership. Current isolated ambient actors are safer; exclude all session IDs from any optional global traffic integration. |
| Static props | **[VERIFIED_IN_BEAMNG_SOURCE]** `flowgraph/nodes/scene/spawnTSStatic.lua` creates `TSStatic`, assigns `shapeName`, position/rotation/scale, registers it, and deletes it on reset/mission end. | A viable static-obstacle route after an allowlist validates collision behavior. Register names/IDs and delete them with session cleanup; props may not appear as `map.objects` vehicle contacts identically on all assets. |

### Diagnostic export APIs

- **[VERIFIED_IN_BEAMNG_SOURCE]** `lua/common/utils.lua:349-466` provides global `jsonEncode`, `jsonEncodePretty`, `jsonDecode`, and `jsonWriteFile`; `jsonWriteFile(..., atomicWrite=true)` writes a temporary file and renames it. `lua/common/utils.lua:950-958` provides `writeFile(filename, data)`. These are suitable for a report JSON and append-style JSONL via `io.open(path, 'a')`; JSONL itself is a file convention, not a BeamNG API.
- **[VERIFIED_IN_BEAMNG_SOURCE]** `FS:getUserPath()`, `FS:expandFilename`, `FS:directoryCreate`, `FS:fileExists`, and `FS:getFileRealPath` are used in `lua/ge/main.lua:657-660`, `lua/ge/screenshot.lua:64-78`, and `lua/ge/ge_utils.lua`. Write only below the resolved user path (for example a mod-specific `settings/randomIncidents/` directory), create the directory first, and use atomic JSON writes for the final report.
- **[VERIFIED_IN_BEAMNG_SOURCE]** `lua/ge/screenshot.lua:105-108` uses `Engine.Platform.exploreFolder('/screenshots/')` to open a folder. This is the verified route for an optional “open export folder” action; there is no verified generic `openFolder` function.
- **[VERIFIED_IN_BEAMNG_SOURCE]** `lua/ge/extensions/editor/resourceChecker.lua:408-411` uses `im.SetClipboardText(path)` from ImGui. This proves clipboard support in an editor/UI context, not a stable headless/freeroam GE extension API. Commit 7.3 should make clipboard optional and never require it for export success.
- **[INFERENCE_REQUIRES_GAME_TEST]** `FS:getUserPath()` plus `FS:expandFilename` should be tested on the user's build for the exact real path and write permissions. Do not use an absolute Windows path or the mod VFS path as the primary destination.

### Stability classification

- **[VERIFIED_IN_BEAMNG_SOURCE]** Extension location/return-table, explicit loading, `onUpdate`, and GE object methods are the closest things here to public/mod-facing interfaces.
- **[VERIFIED_IN_BEAMNG_SOURCE]** AI functions are exported from Vehicle Lua and used by official content, but their detailed behaviour and argument semantics are source-defined, not documented as stable API.
- **[VERIFIED_IN_BEAMNG_SOURCE]** `map.getMap` data layout, navgraph fields, `map.objects.objectCollisions`, `gameplay_util_crashDetection`, and traffic internals are implementation APIs. Wrap them in thin adapters and feature-detect them.

## 4. Runtime and Log Findings

- **[VERIFIED_IN_RUNTIME_LOG]** At 134.449 s the tested run accepted an opposite carriageway with lateral separation 33.33 m, vertical delta 0.57 m, direction dot -1.000, one-way=true and 479.17 m corridor span.
- **[VERIFIED_IN_RUNTIME_LOG]** At 141.472 s the v9 scenario spawned 12 vehicles (6 scripted/6 ambient), chose spot 2183 of length 460.13 m, and armed the trigger engine.
- **[VERIFIED_IN_RUNTIME_LOG]** The v9 run reached normal lead reactions at ~14.009 s and ~18.211 s, queued B's 0.75 s delayed action at 20.082 s, and fired B's emergency stage at 26.208 s.
- **[VERIFIED_IN_RUNTIME_LOG]** Two repeats respawned all 12 actors with new IDs and rearmed the trigger engine. The final Commit 7.1 segment reaches the first four expected trigger events around 14.043/18.214/20.869/20.943 s.
- **[VERIFIED_IN_RUNTIME_LOG]** The supplied log contains no normalized contact, damage, or outcome record. It cannot prove collision outcome or the claimed post-pulse FOLLOWING state.
- **[INFERENCE_REQUIRES_GAME_TEST]** Commit 7.1 should be smoke-tested once for its new release/FOLLOWING behavior, but should not be retuned further unless that check shows a critical regression.

## 5. Critical Issues — P0

1. **FOLLOWING repeatedly resends an unsafe one-node path and disables Car A.** **[VERIFIED_IN_RUNTIME_LOG]** In the new runtime evidence, Car A was already in `FOLLOWING`, but the update path repeatedly issued the full AI setup, producing `FOLLOWING -> FOLLOWING` logs. The eventual `driveUsingPath` payload contained only `{"Bridge30_2"}`. BeamNG failed in `lua/common/mathlib.lua:274` via `lua/vehicle/ai.lua:newManualPath` and disabled the vehicle (`DISABLING VEHICLE DUE TO EXCEPTION`). This is a runtime safety defect, not a tuning issue.
   - Required fix: Commit 7.2 must make state transitions idempotent; call `driveUsingPath` only on entry to FOLLOWING and only with at least two nodes; subsequent FOLLOWING refreshes may update speed only, at a bounded rate and only after a meaningful delta. A short path must be rejected or replaced by a safe non-path AI command.
   - **[INFERENCE_REQUIRES_GAME_TEST]** The exact minimum acceptable path length beyond “two nodes” and the best speed-change threshold require a 60–90 s in-game run.
2. **Commit 8 is blocked until 7.2 passes a long-run test.** **[VERIFIED_IN_RUNTIME_LOG]** A Vehicle Lua exception can terminate a scripted actor before telemetry or scoring can be trusted. No new scenario family or factory work should proceed while this P0 exists.

## 6. Important Issues — P1

1. **Seed is not a complete deterministic scene key.** **[VERIFIED_IN_CURRENT_CODE]** `harvestSpots` iterates `pairs(graph)`/`pairs(connections)` then sorts only by `score` (`randomIncidents.lua:254-278`). Equal-score ordering is unspecified; forward continuation also iterates `pairs` (`:772`). Seeded selection therefore depends on navgraph traversal/tie order. Ambient sampling itself uses a local seeded LCG. Fix before exposing `generateRandomScenario`: impose total, ID-based ordering for harvest candidates, neighbors, opposite candidates, and all tie breakers; store a generation manifest.
2. **Lifecycle ownership is incomplete.** **[VERIFIED_IN_CURRENT_CODE]** `clearGeneratedVehicles`, partial-spawn cleanup, reset and repeat exist, but no `onVehicleDestroyed`, `onClientEndMission`, `onMissionChanged`, or unload cleanup is exported. A destroyed actor leaves an entry and delayed action that can target a stale object. Add idempotent `endSession(reason)` and hook cleanup in Commit 8.
3. **No actual outcome evidence.** **[VERIFIED_IN_CURRENT_CODE]** Current `timeline` records trigger decisions, not contacts/damage/outcome. A trigger firing is not a collision. Commit 8/8.1 must precede any new family.
4. **Road geometry is heuristic, not lane topology.** **[VERIFIED_IN_CURRENT_CODE]** `estimateLaneGeometry` derives lane count from node radii and assumes nominal width; `buildRoadRulePlan` uses it for offsets. This is acceptable MVP planning only with conservative validation. It can fail at merges, lane-count changes, curves, grades, ramps, bridges and multi-level near-parallel roads.
5. **No pre-spawn overlap check for the generated layout.** **[VERIFIED_IN_CURRENT_CODE]** Actor positions are calculated and immediately spawned. Different models have no registered length/width; no generated actor/ambient box check is performed. Current 12-vehicle result is evidence for one seed only.
6. **Per-frame work will not scale cleanly.** **[VERIFIED_IN_CURRENT_CODE]** `onUpdate` loops controllers and evaluates every trigger, each needing object position/velocity. This is fine at 12 actors, but telemetry plus 20 actors needs a shared snapshot once per sample tick; never do pairwise checks over all ambient actors.
7. **Action ownership needs a generic precedence rule.** **[VERIFIED_IN_CURRENT_CODE]** Brake releases are cancelled for `set_speed`, `brake`, `stop`, and `resume`, but trigger groups are logical mutexes, not per-actor action priorities. A second family could schedule steering/brake/follow commands without a unified lease/version. Add action tokens in `actionExecutor`, not more scenario-specific cancellation branches.

## 7. Later Improvements — P2

- **[VERIFIED_IN_CURRENT_CODE]** Move road planning, vehicle spawning, session runtime, and action execution out of the main file once Commit 8 structures exist; do not split stable working code merely by line count.
- **[VERIFIED_IN_CURRENT_CODE]** `scenarioRegistry` validates labels/models but has no model/config existence check, dimensions, roles, or obstacle metadata. A small allowlist is the correct solution, not discovery/random selection of all content.
- **[INFERENCE_REQUIRES_GAME_TEST]** Add road-profile rejection for local curvature, gradient, junction distance, vertical separation, and parallel-corridor continuity. Cache it per map/road edge after it is validated.
- **[INFERENCE_REQUIRES_GAME_TEST]** Instrument optional ambient spawn/retry and reduce diagnostic logs to summary level outside debug runs.

## 8. Collision Telemetry Recommendation

### Recommended hybrid: GE contact edges + cached kinematics + crash utility augmentation

- **[VERIFIED_IN_BEAMNG_SOURCE]** On a fixed 20 Hz session telemetry tick, read only registered actor IDs from `map.objects`. Detect a new contact when `objectCollisions[otherId] == 1` changes from absent to present; the underlying list is supplied by Vehicle Lua through native `getObjectCollisionIds`.
- **[VERIFIED_IN_BEAMNG_SOURCE]** Keep a 0.5–1.0 s circular snapshot cache per tracked actor (`pos`, `vel`, `damage`, road projection). On rising contact, use the immediately preceding snapshots for pre-impact speeds and relative speed, then start a pair debounce window (for example 0.35 s) while retaining later re-impacts as separate events.
- **[VERIFIED_IN_BEAMNG_SOURCE]** Register scenario actor IDs with `gameplay_util_crashDetection.addTrackedVehicleById`; consume `onVehicleCrashStarted`/`onVehicleCrashEnded` as delayed damage/severity enrichment. Its impact records include touched IDs, average position, per-frame damage, and speed, but crash end is intentionally delayed.
- **[INFERENCE_REQUIRES_GAME_TEST]** Treat collision utility availability as optional. Direct contact edges are the MVP primary; crash utility calibration determines severity confidence. Validate contact edge behavior for vehicle-to-vehicle and each chosen obstacle.

| Approach | Exact available evidence | Accuracy / cost / risks |
|---|---|---|
| Event-driven crash utility | **[VERIFIED_IN_BEAMNG_SOURCE]** Hooks `onVehicleCrashStarted`, `onNewImpactStarted`, `onVehicleCrashEnded`; tracks damage, acceleration and `touchedVehIds`. | Good severity and grouped impacts, medium cost for only actors. Not an instantaneous pair event; thresholding can omit weak contacts and two tracked vehicles can duplicate a crash. Deduplicate by canonical pair + time window. |
| GE contact polling (fallback and contact-primary) | **[VERIFIED_IN_BEAMNG_SOURCE]** `map.objects[id].objectCollisions`, `pos`, `vel`, `damage` are GE-visible. | Best first-contact/pair availability without Vehicle extension. At 20 Hz and <=10 scripted actors this is cheap. Contact can persist multiple frames and might report prop IDs without vehicle metadata; edge detection and known-object registry solve double counting. |
| Vehicle Lua event/probe | **[UNKNOWN]** No direct per-contact extension hook with the required normalized payload was found in local Vehicle Lua. | Do not invent one. A later vehicle-side probe may be useful only after a source-proven requirement appears. |
| Geometry/damage heuristic only | **[VERIFIED_IN_BEAMNG_SOURCE]** positions, velocities and damage can be sampled. | Keep only as fallback confidence signal. It cannot reliably identify physical contact or pair; O(n²) should be limited to scripted actors and broad-phase gated. |

Proposed normalized event (one logical pair impact, not one frame):

```lua
{
  time = number,                 -- session simulation time
  actorA = string, actorB = string,
  objectIdA = number, objectIdB = number,
  position = {x = number, y = number, z = number},
  speedA = number, speedB = number,       -- m/s, pre-impact snapshots
  relativeSpeed = number,                  -- |velA - velB| or projected closing speed
  severity = number,                       -- documented normalized score/confidence
  source = string,                         -- "contact_edge", "crash_detection", "hybrid"
  contactStartedAt = number,
  damageDeltaA = number, damageDeltaB = number,
  ordinalForPair = number,
}
```

- **[INFERENCE_REQUIRES_GAME_TEST]** Lane departure should be a road-projection deviation sustained for a duration, not a contact event. Final distances, unexplained stop, and damage are terminal outcome features collected from the same snapshots.

## 9. Recommended Minimal Architecture

Keep `randomIncidents.lua` as the public facade and transition coordinator. Add modules only when their data has a real owner:

```text
Scenario Template        = immutable declaration in scenarios/*.lua
Sampled Scenario Instance= seed + selected road + resolved actor/asset/parameter specs
Runtime State            = sessionId, IDs, controller/action leases, timers, cleanup state
Telemetry                = samples, trigger/spawn/despawn/contact records
Outcome Report           = immutable classification, score, evidence and reroll decision
```

Recommended minimum split for four families:

- **[VERIFIED_IN_CURRENT_CODE]** Retain `scenarioRegistry.lua`, `triggerEngine.lua`, `ambientTraffic.lua`, `scenarios/*.lua`.
- **[INFERENCE_REQUIRES_GAME_TEST]** Add `runtime.lua` (session lifecycle/registry), `roadPlanner.lua` (extract existing plan/discovery code), `vehicleRegistry.lua`, `obstacleRegistry.lua`, `scenarioFactory.lua` plus `parameterSampler.lua`/`scenarioValidator.lua`, `actionExecutor.lua`, `collisionTelemetry.lua`, and `outcomeScorer.lua`.
- **[INFERENCE_REQUIRES_GAME_TEST]** Do not create a separate `lanePlanner.lua` or `vehicleSpawner.lua` initially: keep those as focused functions in `roadPlanner` and `runtime` until more than one consumer needs independently testable APIs.

## 10. Corrected Commit Roadmap

### Commit 7.2 — `fix: make following updates path-safe and idempotent`

- Goal: remove the confirmed P0 without changing the validated pileup design. Separate FOLLOWING entry from FOLLOWING maintenance.
- Files: `randomIncidents.lua` (controller transition/update and path command boundary); no official BeamNG files.
- Rules: `driveUsingPath` is called only when entering FOLLOWING; later FOLLOWING updates change speed only. A `targetPath` shorter than two nodes is never passed to Vehicle AI. FOLLOWING→FOLLOWING is a no-op and does not log a transition. Speed synchronization is rate-limited and sent only after a meaningful change; pending brake releases remain cancellable by stronger actions.
- Acceptance: (1) path call only on FOLLOWING entry; (2) later updates speed-only; (3) one-node/empty paths rejected; (4) no FOLLOWING→FOLLOWING logs; (5) bounded, delta-gated speed sync; (6) Car A runs 60–90 s without Vehicle Lua exception or `DISABLING VEHICLE DUE TO EXCEPTION`; (7) `repeatScene` still works after the long run.
- Test: fresh load → seed 123 → start; capture `printVehicleControllerStates`, last AI commands and console log for 90 s; repeat twice after the run. Search log for `newManualPath`, `mathlib.lua:274`, `DISABLING VEHICLE`, and `FOLLOWING -> FOLLOWING`.
- Risks: a short path may require falling back to `ai.setMode('traffic')`/speed-only control; do not silently invent a replacement path. Out: telemetry, new scenarios, collision scoring.

### Commit 7.3 — `feat: add one-command diagnostic session export`

- Goal: make long-run failures self-contained and exportable before telemetry refactoring.
- Files: preferably new `randomIncidents/diagnosticExport.lua` plus narrow facade wiring; no core-file changes.
- Public API: `exportLastSessionLog()`, `printLastSessionSummary()`, `setConsoleLogLevel(level)`, `getLastSessionReport()`.
- Report data: game/mod version, session ID, map, seed, deterministic manifest, actor IDs, trigger events, controller transitions, last Vehicle Lua command per actor, warnings/errors, targetPath, and a bounded tail of events immediately before an exception.
- **[VERIFIED_IN_BEAMNG_SOURCE]** Write under `FS:getUserPath()` using `FS:directoryCreate`, `FS:expandFilename`, `jsonWriteFile` (atomic final JSON), and `writeFile`/`io.open(...,'a')` for JSONL. Use `Engine.Platform.exploreFolder` only as an optional folder-open action. **[VERIFIED_IN_BEAMNG_SOURCE]** `im.SetClipboardText` exists in editor ImGui code, but clipboard is optional and must not be required for a successful export.
- Acceptance: one console command writes a valid JSON report and JSONL event stream; repeated export is atomic; unavailable clipboard/folder APIs degrade to a logged warning; `getLastSessionReport()` returns the same in-memory data; export includes the pre-exception tail and last command.
- Test: run the 90 s 7.2 test, export after normal completion and after forced actor exception, decode the files, verify required keys and last 50–200 events, then call `printLastSessionSummary()`.
- Risks: exact user-path resolution and console log level API need in-game verification. `setConsoleLogLevel(level)` must control this extension's structured logging if no verified global console-filter API exists; do not claim it changes the engine-wide console without source proof. Out: collision classification and Commit 8 runtime telemetry.

### Commit 8 — `feat: add structured scenario runtime telemetry`

- Goal: establish an idempotent session runtime and evidence ledger; include deterministic ordering/manifest and lifecycle guardrails because later telemetry cannot be trusted without them.
- Files: `randomIncidents.lua`; new `runtime.lua`, `telemetry.lua`; narrow tests/console diagnostics.
- Data/API: `RuntimeSession`, `ActorRecord`, `TelemetrySample`, `getCurrentSession()`, `getTelemetry()`. Keep current `generateScenario`/`start` unchanged.
- Acceptance: unique session ID; 10 Hz samples for six scripted actors; spawn/despawn/trigger records; `onVehicleDestroyed` makes actions safe; map/unload cleanup is idempotent; same seed produces same manifest/spot on the same map after canonical sorting; **only after 7.2 long-run acceptance and 7.3 export acceptance**.
- Test: `extensions.load('randomIncidents'); randomIncidents.harvestSpots(); randomIncidents.generateScenario('sudden_obstacle_pileup',123); randomIncidents.start();` then inspect telemetry after 30 s and repeat once.
- Risks: hook timing and map cache availability. Out: collision classification, new family, registries.

### Commit 8.1 — `feat: record normalized collision events`

- Goal: add contact-edge detector plus optional crashDetection enrichment and pair dedupe.
- Files: new `collisionTelemetry.lua`, `telemetry.lua`, `runtime.lua`; facade wiring only.
- Data/API: normalized `CollisionEvent`, `telemetry.collisions`, `getCollisionEvents()`.
- Acceptance: contact pair recorded once for sustained contact; separate re-impact can be recorded; object IDs map to actor labels when known; obstacle and unknown object are retained; no duplicate when both actors report one contact.
- Test: controlled rear-end seed, no-contact seed, selected prop contact; inspect event order, 0.35 s dedupe, damage delta.
- Risks: crash utility hook/load compatibility, contact data cadence. Out: scoring/reroll.

### Commit 8.2 — `feat: classify and score scenario outcomes`

- Goal: explainable outcome report from telemetry only.
- Files: new `outcomeScorer.lua`; telemetry/facade output.
- Data/API: `OutcomeReport`, `getOutcomeReport()`, classes `PILEUP`, `REAR_END`, `SIDE_IMPACT`, `NEAR_MISS`, `WEAK_COLLISION`, `NO_COLLISION`, `EARLY_COLLISION`, `UNNATURAL_STOP`, `SPAWN_FAILURE`.
- Acceptance: a report names evidence/event IDs and score components; classification never claims a collision without contact evidence.
- Test: three saved logs/runs per known outcome class; manually verify earliest contact classification.
- Risks: thresholds need map/model calibration. Out: automatic reroll.

### Commit 9 — `feat: add validated vehicle and obstacle registries`

- Goal: allowlist 6–10 models/configurations and 3–4 obstacles with known fallbacks, role tags and conservative dimensions.
- Files: `vehicleRegistry.lua`, `obstacleRegistry.lua`, validation and spawn facade.
- Data/API: `resolveVehicle(role, seed)`, `resolveObstacle(role, seed)`, immutable registry entry IDs.
- Acceptance: missing asset/config falls back deterministically or fails pre-spawn; model dimensions feed spacing validation; all listed assets spawn and clean up.
- Test: registry smoke command for every entry on target map.
- Risks: config availability differs by installed version. Out: random all-content catalog.

### Commit 9.1 — `feat: add deterministic constrained parameter sampling`

- Goal: formalize template → instance; sample coupled speed/gap/reaction/road values.
- Files: `parameterSampler.lua`, `scenarioValidator.lua`, `roadPlanner.lua` extraction, scenario schema updates.
- Data/API: `SampledScenarioInstance`, manifest with RNG stream/version and rejection reasons.
- Acceptance: no `pairs`-dependent choice; all constraints validate before spawn; identical seed/map/template yields same instance manifest.
- Test: console seed manifest for 20 seeds plus static Lua validation.
- Risks: exact physical result remains nondeterministic. Out: family selection/public factory.

### Commit 9.2 — `feat: add deterministic random scenario factory`

- Goal: introduce `extensions.randomIncidents.generateRandomScenario(seed, options)` selecting stable variants of slow traffic first.
- Files: `scenarioFactory.lua`, facade, registry/schema wiring.
- Data/API: public `generateRandomScenario(seed, options)` returns instance/session-ready summary; `start()` stays separate.
- Acceptance: options constrain family/map/actor count without bypassing validation; seed manifest logged; invalid choice returns structured reason, no partial scene.
- Test: 20 fixed seeds on one supported map.
- Risks: API needs documented defaults. Out: new family.

### Commit 10 — `feat: add sudden congestion incident family`

- Goal: second no-lane-change family reusing action/telemetry/scoring.
- Files: scenario template and factory constraints only, minimal action additions if proven necessary.
- Acceptance: valid sampled instance, telemetry and outcome report across seed set.
- Test: 10 seeds on two road profiles. Out: obstacles/lane change.

### Commit 11 — `feat: add validated obstacle incident family`

- Goal: parked-vehicle/static-prop obstacle using registry and contact telemetry.
- Files: obstacle spawner in runtime, template, validator.
- Acceptance: obstacle cleanup and vehicle/obstacle contact evidence work; no spawn overlap.
- Test: every approved obstacle on target map. Out: arbitrary TSStatic random assets.

### Commit 12 — `feat: add controlled lane-change incidents`

- Goal: only after an explicit source/game proof, use `ai.laneChange` with abort/fallback.
- Files: action executor, lane-change template/validator.
- Acceptance: lane change succeeds/aborts deterministically enough on selected profiles; no uncontrolled global traffic interaction; braking fallback produces report.
- Test: model/map matrix with at least 20 runs. Risk: Vehicle AI plan rebuild and lane topology. Out: universal lane changing.

### Commit 13 — `feat: reroll weak or invalid incident outcomes`

- Goal: bounded sequential attempts based on validation and outcome score.
- Files: factory/runtime/orchestrator and diagnostics.
- Data/API: `generateUntilInteresting{seed, attempts, minimumScore}` with attempt reports.
- Acceptance: cleanup completes before next attempt; base seed plus attempt index controls RNG; retains best/accepted report.
- Test: 10-attempt bounded run with zero leaked actor IDs. Out: parallel scenes.

### Commit 14 — `chore: add seed matrix, diagnostics and release checklist`

- Goal: harden supported scope and package reproducibility evidence.
- Files: test commands, seed matrix, supported asset/map documentation, release checklist.
- Acceptance: 50-seed result table, known-failure taxonomy, clean unload/map-change test, release ZIP validation.
- Test: documented console matrix and in-game monitoring. Out: UI/camera/video.

## 11. Test Matrix

| Test | Command / procedure | Pass criterion |
|---|---|---|
| Load / generated scene | `extensions.unload('randomIncidents'); extensions.load('randomIncidents'); extensions.randomIncidents.harvestSpots(); extensions.randomIncidents.generateScenario('sudden_obstacle_pileup',123); extensions.randomIncidents.start()` | 6 scripted actors spawn; optional ambient failure does not invalidate scripted scene. |
| Commit 7.1 regression | Run 35 s; call `printVehicleControllerStates()` and `printTriggerEvents()` | A returns to `FOLLOWING` after pulse, no stale pulse release; trigger chain is ordered. **[INFERENCE_REQUIRES_GAME_TEST]** |
| Commit 7.2 long run | Fresh load, seed 123, start, run 60–90 s; grep log for `newManualPath`, `mathlib.lua:274`, `DISABLING VEHICLE`, `FOLLOWING -> FOLLOWING` | Zero Vehicle Lua exceptions, zero disable messages, zero repeated FOLLOWING transitions; Car A remains controllable. |
| Commit 7.2 repeat | After the long run call `repeatScene()` twice | Same scene respawns, AI restarts, and no stale delayed command targets an old ID. |
| Commit 7.3 export | Call `exportLastSessionLog()` after normal and exception runs | Valid JSON + JSONL under user path; required manifest/IDs/commands/events/warnings and pre-exception tail are present; export is repeatable/atomic. |
| Commit 7.3 summary | Call `getLastSessionReport()`, `printLastSessionSummary()`, optional clipboard/folder action | In-memory report matches exported report; optional UI integrations fail soft and do not block export. |
| Repeat/reset | `extensions.randomIncidents.repeatScene()` twice; then reset/start | Every old ID is removed, 12 new entries exist, trigger runtime/events reset. |
| Determinism manifest | Generate seed 0–19 twice after fresh `harvestSpots()` | Same sorted manifest, selected spot/paths/specs/asset IDs per seed; physics outcome may differ. |
| Lifecycle | Destroy one scripted actor; change level; unload extension | No queued command targets stale ID; all session props/vehicles removed. |
| Telemetry | Commit 8/8.1 controlled rear-end, near-miss, prop hit | Samples bounded; exactly one first-contact pair edge; no sustained-contact duplicates. |
| Road profiles | One-way divided highway, two-way road, curve, grade, bridge/ramp, junction-adjacent | Validator accepts only supported profile or returns explicit rejection. |
| Scale | 4/8 scripted plus 0/6/12 ambient | 20 Hz telemetry/contacts bounded to registered actors; no per-frame full O(n²) ambient scan. |
| Lane-change proof | Commit 12 only: 20 runs for each approved model/map lane profile | Measured success/abort/fallback rates and no unclassified failure. |

## 12. Open Questions

1. **[UNKNOWN]** Which exact BeamNG build/version and target maps are release-supported? The local game source is authoritative for this audit, but a version lock should be recorded in Commit 14.
2. **[INFERENCE_REQUIRES_GAME_TEST]** Does `gameplay_util_crashDetection` load and publish its hooks in the user's normal freeroam session without conflicts? Commit 8.1 must verify this; direct contact polling remains viable if not.
3. **[INFERENCE_REQUIRES_GAME_TEST]** Which 6–10 vehicle configurations and 3–4 static shapes produce reliable contact IDs/damage on the target build? This is registry acceptance work, not something to assume from model names.
4. **[INFERENCE_REQUIRES_GAME_TEST]** What outcome rate is acceptable for a seed matrix (for example, accepted scenario percentage vs. reroll cap)? Product must choose before Commit 13 thresholds are frozen.

## 13. Go / No-Go verdict for Commit 8

**NO-GO for Commit 8 until Commit 7.2 passes the 60–90 s runtime test.** **[VERIFIED_IN_RUNTIME_LOG]** The confirmed FOLLOWING/path defect can disable a scripted actor through a Vehicle Lua exception, so telemetry built on top of the current runtime would not be trustworthy. Commit 7.2 must pass its seven acceptance criteria first. **[INFERENCE_REQUIRES_GAME_TEST]** After 7.2 passes, the recommendation is GO for Commit 7.3 and then GO for Commit 8; the diagnostic export should be validated before beginning the telemetry foundation. GE hooks, `map.objects`, and the existing trigger engine remain suitable for Commit 8 once the P0 is removed. Do not change the working Commit 7.1 driving behaviour beyond the narrowly scoped 7.2 fix.
