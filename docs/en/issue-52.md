# Investigating iOS video interruption recovery and background track changes

Related: [songloft-org/songloft-player#52](https://github.com/songloft-org/songloft-player/issues/52), 2026-10-26. Status: interruption-handling candidate; the reported symptoms have not been reproduced or accepted on the device.

## Report and investigation limits

The report names iPhone 14 Pro / iOS 16.1 and two symptoms: music does not continue after watching a video, and background playback stops after one track. There are no comments, client version, logs, or explicit IPA / Safari / PWA identification. This candidate targets the installed Flutter client and does not establish web behavior.

Local main matches remote main at investigation time: `538c228677350fa7c87f74bb5fe12e6e71b7ef56`. The existing Build and Release succeeded for that SHA; it does not build or publish this candidate.

## Interruption path and candidate behavior

The old Handler and locked `just_audio 0.10.6` both subscribe to `AudioSession.interruptionEventStream`. Reviewing the implementations shows that two listeners alone do not prove a normal interruption cannot resume: just_audio maintains its own resume intent, and the old Handler passes the ordinary single-interruption case. The initial investigation overstated the duplicate listeners as the reported root cause; that conclusion has been corrected.

The old Handler does have verifiable boundary issues: repeated begin events overwrite playback intent; end events neither check their type nor clear intent; manual pause during interruption can still be followed by automatic playback; playback can start before an asynchronous pause finishes; direct player.play bypasses live reconnection; disposing during configuration can install late subscriptions. Injected session/player tests verify these Handler behaviors, without establishing that the reporter triggered any of them on hardware.

The candidate disables just_audio's automatic interruption handling and gives the Handler ownership, including headphone-unplug handling:

- pause / unknown begin saves playback intent and uses the normal pause path to cancel old loads and live retries. Repeated begin events preserve intent.
- Only a matching pause end (iOS `shouldResume`) can resume. An unknown end requires manual playback.
- Manual pause, stop, source replacement and disposal invalidate old resumes. Recovery waits for pause and uses the regular play path, including live reconnection.
- With the music configuration, duck events leave playback intent unchanged and retain system duck behavior. Unplugging headphones cancels automatic recovery.
- Log interruption type, playback state, stopped state and the resume decision for device diagnosis.

`audio_session` maps iOS begin to unknown, and end to pause or unknown according to `shouldResume`. Follow its [event contract](https://github.com/ryanheise/audio_session/blob/master/lib/src/core.dart); automatic recovery after leaving a video cannot be promised when the OS does not permit it.

## Background track changes remain unresolved

Reviewed `UIBackgroundModes=audio`, the music session configuration, `_onSongCompleted` mode/queue routing, and the existing avoidance of Handler.stop before replacing a source. These are present, so a missing background declaration or completion callback does not explain the report. Single-play mode, the end of an ordered list and sleep timers also intentionally stop playback.

The vendored `media_kit.open()` still calls an internal stop. Upstream [mpv's iOS AudioUnit driver](https://github.com/mpv-player/mpv/blob/master/audio/out/ao_audiounit.m) deactivates the session in uninit, making output lifetime during replacement worth tracing on hardware. That upstream source does not establish what a released IPA actually does. This task does not change that layer or introduce unverified silent keep-alive/session takeover behavior.

Confirm client type/version, deployment mode, play mode, whether returning to the foreground immediately advances playback, and fault logs. Distinguish receipt of completed, next-source loading, new interruptions, and load/play failures.

## Validation object and record

- Repository: `songloft-org/songloft-player`, baseline above plus uncommitted worktree. Parent baseline: `041d34d7e9387b60ed8126022071f731a7268aa6`; its pre-existing backend/plugin changes are outside this task.
- Environment: Linux x86_64 / Flutter 3.44.8 / Dart 3.12.2.
- Code identity: SHA-256 of path, NUL, contents, NUL for `lib/core/audio/audio_service.dart` followed by `test/core/audio/audio_interruption_test.dart`: `25b5207ec901f972373edd2f72fe52f26c8caef816f4f97136730db4e75e53ed`. Individual hashes: `/tmp/songloft-player-52-20261026/validation.json`.
- Isolated old implementation: copy sources/resolved dependency locations and add only the session injection seam to the HEAD Handler. Of 17 cases, 14 fail for the target behavior and 3 pass (`before-final.log`). Normal single-interruption recovery already passes. Initial fixture failures caused by missing package graph, fonts and icon never ran tests and are not negative-regression evidence.
- Commands: `dart format lib/ test/` (458 files, no changes), `flutter analyze --no-pub` (no issues), `flutter test --no-pub --concurrency=2` (791 passing, including 17 new interruption regressions), `git diff --check` (passed). Final results are in `analyze-final.log`, `full-final.log` and `validation.json` in that directory.
- Not run: macOS/iOS compilation; iPhone 14 Pro / iOS 16.1 video interruption/recovery and consecutive/long background playback; native Android focus/headphone handling; other native platforms; Safari/PWA; Bundle backend; candidate remote CI. Linux injected tests do not replace this acceptance.

## iPhone acceptance steps

1. Record the installed package version, deployment mode and list-loop mode. Select three playable tracks and disable sleep timers.
2. Open a video app while music plays, then end the video and return. Check whether the OS emits an end event allowing recovery. Without that permission, manual play should still work.
3. Manually pause or stop from the lock screen during interruption; an end event must not restart playback. Also test headphone unplugging.
4. Resume music and lock the screen across at least three natural track endings. Separately test background manual-next and tracks with different sample rates.
5. If playback stalls, export logs around the fault and record whether returning to the foreground immediately resumes it. Do not count intentional pause, ordered-list end or sleep timer stops as failures.

On 2026-10-26, the user authorized committing, pushing and replying to the issue, with device testing deferred until a new package is available. Commit message: `fix(audio): 统一中断恢复与取消边界 (Ref #52)`. Pushing main triggers the automatic dev build; track commit/package status through CI for the corresponding SHA and the issue reply. Keep the issue open and do not use `Fixes #52` before device acceptance. No stable-version tag is created in this task.
