# Zone names, grouping and transfer validation (2026-10-27)

Target: Roomtone parent `708ec132`, Flutter submodule `152c8d0` plus uncommitted working tree, Windows amd64, embedded Flutter Web. Not committed, pushed or released.

- Audio-device rows in zone settings expose speaker renaming. A solo zone and its speaker share the name in both directions. Restore and grouping reconcile existing solo names; rediscovery retains user names.
- Grouped zones use a link icon, separate member-name lines and a compact “first member + N” label. Output settings, party selectors, alarm targets and DSP members show actual names.
- Each speaker has its own slider, mute and +/-1 controls. Individual changes affect only that speaker and persist its offset; group +/-1 retains offsets, and group mute preserves volumes.
- The transfer dialog shows the source members and song above actual destination speakers/zones. Offline destinations are disabled. Successful transfers focus the destination; errors remain visible.
- Identity/membership events coalesce snapshot refreshes so open pages receive new names.

Validation: all 35 output tests passed, including four new widget regressions for grouped names, independent/member-relative volume, mute, transfer targets/focus and renaming. Relevant Dart analysis and release Web build passed. Backend app/player tests and vet passed; naming regressions cover rediscovery, restart, two-way solo naming and grouping. Browser inspection covered saving a name, grouping the two paused EDIFIER devices, member names/compact labels, volume layout and destination list. Local screenshots: `roon-group-selector.png`, `roon-group-volume.png`, `roon-transfer-zones.png` in the user's Roomtone tools directory.

After the user requested no more playback tests, no play button or real playback transfer was executed. New audible verification of volume/mute or transfers: Not run. Widget tests use an in-memory API.

Lesson: the first revision exposed speaker renaming while group.name and player.Name remained independent. Saving the solo zone as “餐厅” left factory names in member/volume pages. The fix links solo names and checks every display surface plus event refresh. A successful edit dialog alone does not prove application-wide renaming.

Follow-up: actual user transfer exposed cached volume members (PATCH to 9EC4 inside destination 9764, 404). Added zone keys, generation checks and membership refresh, clearing pending debounce writes. Two regressions cover destination changes and member removal inside the same zone. All 37 output tests passed with relevant analysis clean. The updated browser panel targets 9764 without the stale error; no volume/play control was actuated. Screenshot: `volume-target-fixed.png`.


## Narrow queue and duplicate remote playback (2026-10-27)

Target: Flutter base `152c8d0` plus the current uncommitted worktree; Windows / Flutter 3.47.0-0.1.pre, locally embedded Web.

- The mobile AdaptiveScaffold omitted playlistDrawer. The queue now overlays the content area while preserving transport/navigation, and can be closed.
- Remote playPlaylist recursively built its queue through `_playCurrent`, which also started browser audio; autoPlay:false single-song operations still loaded local media. Remote queue edits now skip all local media loading and send playback only to the selected zone.
- Remote focus invalidates pending local loads and calls handler.pause even before playing is reported, including HLS. Browser HLS/duration events cannot overwrite the remote mirror. Responses from a previous zone cannot replace the current zone queue.
- Regressions cover queue open/close at 320/446/599px, no local media load for remote playlist/single-song playback, switching during a pending load, and out-of-order zone responses. Existing player/output/sidebar tests are included. Two stale capsule tests now match the current Roon queue button and 104px standard player.
- Commands: `dart format lib/ test/`; `flutter test test/features/player test/features/playback test/features/output test/shared/layouts/adaptive_scaffold_queue_test.dart test/shared/layouts/adaptive_scaffold_sidebar_test.dart test/shared/layouts/adaptive_scaffold_reparent_test.dart`; `flutter analyze --no-pub`.
- Analysis: no new diagnostics; two existing unawaited_return_in_try_block warnings and one alarms_page unnecessary_import info. Native platforms and multi-speaker correlation/synchronization: Not run.


Final checks: 363 tests passed; targeted `dart analyze` on six changed implementation/test files reported no issues; `git diff --check` passed. Web release built and was embedded in the local Go dev executable. At approximately 440px, the actual browser queue opens, closes, and remains usable. Starting English audio from the library with Cocoon focused produced Cocoon state=playing (song_id=2), Web state=idle with an empty queue, no DOM audio/video elements, and no local SongloftAudioHandler.playSong call. Playback was paused afterward and the original queue/index/position restored. No additional listening confirmation was requested; state/media checks are not represented as a new listening acceptance.

Final-build queue selection recheck: Cocoon song_id=5/state=playing; Web song_id=0/state=idle; duration updated to 04:05. DOM media elements and local loading logs remained empty. Evidence: `C:/Users/leon/.local/roomtone-tools/narrow-remote-proof.json` and `narrow-queue-fixed.png`. API assertions confirmed restoration of the original eight-song queue, index 3, position 62.2211278 seconds and paused state.


## Independent Web playback and integer volume (2026-10-27)

User reported that changing UI focus muted ongoing Web playback, and volume labels exposed long decimals. The earlier immediate-pause-on-remote-focus guard was too broad; this section supersedes that behavior.

- Focus selects the zone being controlled without stopping the local renderer. Local playback state/mode is retained separately; async loads, audio events, natural completion and server device commands execute in the local output context.
- Remote song selection still edits/sends only its own queue and never loads Web media. Empty remote queues clear only the projection. Returning to Web uses its actual track/position without reloading an existing source.
- Device commands for the local renderer are not gated by UI focus. Queue debounces retain their zone owner; background Web track changes synchronize to the Web group instead of B.
- Volume labels round to integers; the local slider uses 100 steps and local writes round to integers.
- Regressions cover pending loads across focus/remote edits, empty zones, background position/next track, returning without reload, local transport while viewing remote, and queue ownership. 368 related player/output/layout tests passed, including volume label/slider widget checks.

Live recheck: the final local embedded build played the original Web queue and showed integer volume 11. After focusing paused Cocoon, Web remained playing (song_id=9, position 130.503s and advancing), while Cocoon stayed paused. User explicitly confirmed that audio remained continuous. Returning to Web showed 03:57 without restarting, still with integer volume 11. Targeted Dart analysis, Web release and embedded Go builds passed. The user's current playback choice was preserved. Evidence: local tools directory web-independent-live-a.json and web-independent-volume-fixed.png.
