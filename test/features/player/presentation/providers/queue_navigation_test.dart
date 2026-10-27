import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dlna_dart/xmlParser.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:songloft_flutter/core/audio/audio_service.dart';
import 'package:songloft_flutter/core/network/api_client.dart';
import 'package:songloft_flutter/core/storage/app_preferences.dart';
import 'package:songloft_flutter/core/storage/secure_storage.dart';
import 'package:songloft_flutter/features/auth/presentation/providers/auth_provider.dart';
import 'package:songloft_flutter/features/dlna/domain/dlna_state.dart';
import 'package:songloft_flutter/features/dlna/data/dlna_service.dart';
import 'package:songloft_flutter/features/dlna/presentation/providers/dlna_provider.dart';
import 'package:songloft_flutter/features/library/presentation/providers/favorite_provider.dart';
import 'package:songloft_flutter/features/player/domain/playback_context.dart';
import 'package:songloft_flutter/features/player/domain/playback_source.dart';
import 'package:songloft_flutter/features/player/domain/player_state.dart';
import 'package:songloft_flutter/features/player/presentation/providers/lyric_provider.dart';
import 'package:songloft_flutter/features/player/presentation/providers/player_provider.dart';
import 'package:songloft_flutter/features/settings/data/settings_api.dart';
import 'package:songloft_flutter/features/settings/presentation/providers/settings_provider.dart';
import 'package:songloft_flutter/main.dart';
import 'package:songloft_flutter/features/output/presentation/providers/zone_focus_provider.dart';
import 'package:songloft_flutter/features/playback/presentation/providers/zone_queue_sync.dart';
import 'package:songloft_flutter/features/playback/presentation/providers/local_output_provider.dart';
import 'package:songloft_flutter/features/playback/presentation/providers/playback_socket_provider.dart';
import 'package:songloft_flutter/features/output/data/output_api.dart';
import 'package:songloft_flutter/features/output/domain/output_models.dart';
import 'package:songloft_flutter/features/output/presentation/providers/output_provider.dart';
import 'package:songloft_flutter/features/output/presentation/providers/remote_zone_provider.dart';
import 'package:songloft_flutter/l10n/app_localizations_zh.dart';
import 'package:songloft_flutter/l10n/l10n_holder.dart';
import 'package:songloft_flutter/shared/models/song.dart';

// Queue/navigation use real player and DLNA notifiers, with fake audio transports.
class _Audio implements SongloftAudioHandler {
  final played = <int>[];
  final attempted = <int>[];
  final failedIds = <int>{};
  final seeks = <Duration>[];
  Completer<void>? playGate;
  int pauses = 0;
  int stops = 0;
  final positions = StreamController<Duration>.broadcast(sync: true);
  @override
  VoidCallback? onSongCompleted;
  @override
  VoidCallback? onPlaybackError;
  @override
  VoidCallback? onPlaybackCancelled;
  @override
  Future<bool> Function()? onPlayRequested;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<ja.PlayerState> get playerStateStream => const Stream.empty();
  @override
  ja.ProcessingState get processingState => ja.ProcessingState.ready;
  @override
  PlaybackSource get lastPlaybackSource => PlaybackSource.unknown;
  @override
  Future<void> playSong(
    Song song, {
    String? quality,
    int? audioTrack,
    bool normalize = false,
    bool autoPlay = true,
  }) async {
    attempted.add(song.id);
    if (failedIds.contains(song.id)) throw StateError('audio source failed');
    played.add(song.id);
    await playGate?.future;
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async {
    stops++;
    onPlaybackCancelled?.call();
  }

  @override
  Future<void> pause() async {
    pauses++;
    onPlaybackCancelled?.call();
  }

  @override
  Future<void> seek(Duration position) async => seeks.add(position);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _RemoteApi implements OutputApi {
  final queues = <List<int>>[];
  final queueZones = <String>[];
  final queueIndices = <int>[];
  final pendingQueues = <String, Completer<OutputStatus>>{};
  @override
  Future<OutputStatus> getQueue(String groupId) =>
      pendingQueues[groupId]?.future ?? Future.value(const OutputStatus());
  @override
  Future<OutputStatus> replaceQueue(
    String groupId,
    List<int> songIds, {
    int index = 0,
  }) async {
    queues.add(List.of(songIds));
    queueZones.add(groupId);
    queueIndices.add(index);
    return const OutputStatus();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _LocalIdentity extends LocalDeviceIdNotifier {
  @override
  String? build() => 'web';
}

class _Outputs extends OutputController {
  final actions = <String>[];
  @override
  OutputState build() => const OutputState();
  void setGroups(List<OutputGroup> groups) =>
      state = OutputState(groups: groups);
  @override
  Future<OutputStatus?> transport(
    String groupId,
    String action, {
    double? position,
    String? repeat,
    bool? shuffle,
  }) async {
    actions.add('$groupId:$action');
    return const OutputStatus();
  }
}

class _Storage implements SecureStorageService {
  @override
  Future<String?> getAccessToken() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Favorites extends FavoriteNotifier {
  @override
  FavoriteState build() => const FavoriteState(initialized: true);
}

class _Lyrics extends LyricNotifier {
  @override
  LyricState build() => const LyricState();
}

class _DlnaTransport implements DlnaService {
  final completed = StreamController<void>.broadcast(sync: true);
  final titles = <String>[];
  bool fail = false;

  @override
  Stream<void> get completionStream => completed.stream;
  @override
  Stream<PositionParser> get positionStream => const Stream.empty();
  @override
  Future<void> castTo(
    String deviceId,
    String url, {
    String title = '',
    PlayType mime = AudioMime.mp3,
  }) async {
    if (fail) throw StateError('device rejected the song');
    titles.add(title);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Normalize extends VolumeNormalizeNotifier {
  @override
  Future<VolumeNormalizeSetting> build() async =>
      const VolumeNormalizeSetting(enabled: false);
}

Song _song(int id) => Song(
  id: id,
  type: 'local',
  title: 'Song $id',
  duration: 180,
  url: 'https://music.example.test/songs/$id',
  addedAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

Song _radio(int id) => Song.fromJson({
  'id': id,
  'title': 'Radio $id',
  'type': 'radio',
  'is_live': true,
  'url': 'https://radio.example.test/$id',
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late _Audio audio;
  late _DlnaTransport dlna;
  late PlayerNotifier player;
  late _RemoteApi remoteApi;
  late Directory temporaryDirectory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    updateGlobalL10n(AppLocalizationsZh());
    final preferences = await AppPreferences.create();
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'songloft-queue-test-',
    );
    audio = _Audio();
    dlna = _DlnaTransport();
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest:
            (options, handler) => handler.resolve(
              Response(
                requestOptions: options,
                data: <String, dynamic>{},
                statusCode: 200,
              ),
            ),
      ),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => temporaryDirectory.path,
        );
    remoteApi = _RemoteApi();
    container = ProviderContainer(
      overrides: [
        audioHandlerProvider.overrideWithValue(audio),
        outputApiProvider.overrideWithValue(remoteApi),
        localDeviceIdProvider.overrideWith(_LocalIdentity.new),
        playbackEventsProvider.overrideWith((ref) => const Stream.empty()),
        outputControllerProvider.overrideWith(_Outputs.new),
        secureStorageProvider.overrideWithValue(_Storage()),
        appPreferencesProvider.overrideWith((ref) async => preferences),
        dioProvider.overrideWithValue(dio),
        favoriteProvider.overrideWith(_Favorites.new),
        lyricStateProvider.overrideWith(_Lyrics.new),
        dlnaServiceProvider.overrideWithValue(dlna),
        volumeNormalizeProvider.overrideWith(_Normalize.new),
      ],
    );
    player = container.read(playerStateProvider.notifier);
    // Allow the real startup preference/queue restoration to finish.
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  tearDown(() async {
    container.dispose();
    await audio.positions.close();
    await dlna.completed.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await temporaryDirectory.delete(recursive: true);
  });

  test(
    'remote playlist and single-song playback never load browser audio',
    () async {
      container.read(remoteZoneIdProvider.notifier).set('cocoon');
      await player.playPlaylist([_song(1), _song(2)], startIndex: 1);
      expect(
        container.read(playerStateProvider).duration,
        const Duration(seconds: 180),
      );
      expect(container.read(playerStateProvider).currentTime, Duration.zero);
      await player.playSong(_song(3));
      expect(audio.attempted, isEmpty);
      expect(remoteApi.queues.length, 2);
      expect(remoteApi.queues.first, [1, 2]);
      expect(remoteApi.queues.last, contains(3));
      expect(
        (container.read(outputControllerProvider.notifier) as _Outputs).actions,
        ['cocoon:play', 'cocoon:play'],
      );
    },
  );

  test('remote focus and queue edits preserve a pending Web load', () async {
    audio.playGate = Completer<void>();
    final loading = player.playPlaylist([_song(1)]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(audio.attempted, [1]);
    container.read(remoteZoneIdProvider.notifier).set('cocoon');
    await player.adoptZoneQueue([_song(2)], mirrorPlaying: true);
    await player.playPlaylist([_song(3)]);
    expect(audio.pauses, 0);
    expect(audio.stops, 0);
    audio.playGate!.complete();
    await loading;
    expect(player.loadedIsPlaying, isTrue);
    expect(player.loadedSongId, 1);
    expect(container.read(playerStateProvider).currentSong?.id, 3);
    expect(audio.attempted, [1]);
  });

  test(
    'Web keeps its own next track and position while controlling B',
    () async {
      await player.playPlaylist([_song(1), _song(2)]);
      container.read(remoteZoneIdProvider.notifier).set('b');
      await player.adoptZoneQueue([
        _song(3),
      ], position: const Duration(seconds: 7));
      audio.positions.add(const Duration(seconds: 42));
      expect(player.loadedPosition, const Duration(seconds: 42));
      expect(
        container.read(playerStateProvider).currentTime,
        const Duration(seconds: 7),
      );
      audio.onSongCompleted!();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(audio.attempted, [1, 2]);
      expect(player.loadedSongId, 2);
      expect(container.read(playerStateProvider).currentSong?.id, 3);
      expect(
        (container.read(outputControllerProvider.notifier) as _Outputs).actions,
        isEmpty,
      );
      expect(audio.pauses, 0);
    },
  );

  test(
    'empty remote queue does not clear Web audio and returning does not restart it',
    () async {
      await player.playPlaylist([_song(1)]);
      container.read(remoteZoneIdProvider.notifier).set('empty');
      await player.adoptZoneQueue([]);
      expect(container.read(playerStateProvider).playlist, isEmpty);
      expect(player.loadedSongId, 1);
      expect(player.loadedIsPlaying, isTrue);
      expect(audio.stops, 0);
      audio.positions.add(const Duration(seconds: 42));
      container.read(remoteZoneIdProvider.notifier).set(null);
      await player.adoptZoneQueue([_song(1)], localZone: true, autoPlay: true);
      expect(audio.attempted, [1]);
      expect(
        container.read(playerStateProvider).currentTime,
        const Duration(seconds: 42),
      );
      expect(container.read(playerStateProvider).isPlaying, isTrue);
    },
  );

  test(
    'server transport operates Web without changing the focused remote zone',
    () async {
      await player.playPlaylist([_song(1)]);
      container.read(remoteZoneIdProvider.notifier).set('b');
      await player.adoptZoneQueue([_song(2)], mirrorPlaying: true);
      await player.runOnLocalOutput(player.pauseForServer);
      expect(player.loadedIsPlaying, isFalse);
      expect(container.read(playerStateProvider).isPlaying, isTrue);
      await player.runOnLocalOutput(player.resumeForServer);
      await player.runOnLocalOutput(
        () => player.seek(const Duration(seconds: 12)),
      );
      await player.runOnLocalOutput(() => player.setVolume(10.589));
      expect(player.loadedIsPlaying, isTrue);
      expect(audio.seeks.last, const Duration(seconds: 12));
      expect(player.runOnLocalOutput(() => player.currentState.volume), 11);
      expect(container.read(playerStateProvider).currentSong?.id, 2);
      expect(
        (container.read(outputControllerProvider.notifier) as _Outputs).actions,
        isEmpty,
      );
    },
  );

  test(
    'slow previous zone response cannot replace the current zone queue',
    () async {
      final outputs =
          container.read(outputControllerProvider.notifier) as _Outputs;
      outputs.setGroups([
        for (final id in ['a', 'b'])
          OutputGroup.fromJson({
            'id': id,
            'name': id,
            'members': [
              {'player_id': 'raop:$id'},
            ],
          }),
      ]);
      remoteApi.pendingQueues['a'] = Completer<OutputStatus>();
      await container.read(zoneFocusProvider.notifier).focus('a');
      final syncProvider = Provider<ZoneQueueSync>((ref) {
        final sync = ZoneQueueSync(ref);
        ref.onDispose(sync.dispose);
        return sync;
      });
      container.read(syncProvider).start();
      await container.read(zoneFocusProvider.notifier).focus('b');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await player.playPlaylist([_song(2)]);
      remoteApi.pendingQueues['a']!.complete(const OutputStatus());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(container.read(remoteZoneIdProvider), 'b');
      expect(container.read(playerStateProvider).currentSong?.id, 2);
      expect(container.read(playerStateProvider).playlist.map((s) => s.id), [
        2,
      ]);
      expect(audio.attempted, isEmpty);
    },
  );

  test(
    'background Web queue push retains its owner across a focus switch',
    () async {
      final outputs =
          container.read(outputControllerProvider.notifier) as _Outputs;
      outputs.setGroups([
        OutputGroup.fromJson({
          'id': 'web-zone',
          'name': 'Web',
          'members': [
            {'player_id': 'web'},
          ],
        }),
        OutputGroup.fromJson({
          'id': 'b',
          'name': 'B',
          'members': [
            {'player_id': 'raop:b'},
          ],
        }),
      ]);
      await container.read(zoneFocusProvider.notifier).focus('web-zone');
      final provider = Provider<ZoneQueueSync>((ref) {
        final sync = ZoneQueueSync(ref);
        ref.onDispose(sync.dispose);
        return sync;
      });
      container.read(provider).start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await player.playPlaylist([_song(1), _song(2)]);
      final stops = audio.stops;
      await container.read(zoneFocusProvider.notifier).focus('b');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      audio.onSongCompleted!();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(player.loadedSongId, 2);
      expect(player.loadedIsPlaying, isTrue);
      expect(audio.stops, stops);
      expect(remoteApi.queueZones, isNotEmpty);
      expect(remoteApi.queueZones.every((id) => id == 'web-zone'), isTrue);
      expect(remoteApi.queues.last, [1, 2]);
      expect(remoteApi.queueIndices.last, 1);
      expect(container.read(playerStateProvider).playlist, isEmpty);
    },
  );

  test(
    'explicit transfer stop cancels pending Web load even while viewing B',
    () async {
      audio.playGate = Completer<void>();
      final load = player.playPlaylist([_song(1)]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      container.read(remoteZoneIdProvider.notifier).set('b');
      await player.adoptZoneQueue([_song(2)]);
      await player.runOnLocalOutput(player.stopForServer);
      audio.playGate!.complete();
      await load;
      expect(player.loadedHasSong, isFalse);
      expect(player.loadedIsPlaying, isFalse);
      expect(container.read(playerStateProvider).currentSong?.id, 2);
    },
  );

  for (final mode in PlayMode.values) {
    test('live completion stays on station in $mode, preserving priority', () {
      fakeAsync((clock) {
        container.invalidate(appPreferencesProvider);
        clock.flushMicrotasks();
        unawaited(player.setPlayMode(mode));
        unawaited(player.playPlaylist([_radio(1), _radio(2)]));
        clock.flushMicrotasks();
        unawaited(player.playSongNext(_radio(2)));
        player.setSleepTimerAfterSongs(2);
        clock.flushMicrotasks();
        audio.onSongCompleted!();
        audio.onSongCompleted!(); // Duplicate event must not fork retries.
        clock.flushMicrotasks();
        expect(container.read(playerStateProvider).currentSong?.id, 1);
        expect(container.read(playerStateProvider).hasPriorityNext, isTrue);
        expect(
          container.read(playerStateProvider).sleepTimer?.remainingSongs,
          2,
        );
        expect(container.read(playerStateProvider).isRetrying, isTrue);
        clock.elapse(const Duration(seconds: 2));
        expect(audio.played, [1, 1]);
        expect(container.read(playerStateProvider).playMode, mode);
        expect(container.read(playerStateProvider).isRetrying, isFalse);
        container.dispose();
      });
    });
  }

  test(
    'live loading retries beyond network budget then recovers same station',
    () {
      fakeAsync((clock) {
        container.invalidate(appPreferencesProvider);
        clock.flushMicrotasks();
        audio.failedIds.add(1);
        unawaited(player.playPlaylist([_radio(1), _radio(2)]));
        clock.flushMicrotasks();
        clock.elapse(const Duration(minutes: 3));
        expect(audio.attempted.length, greaterThan(8));
        expect(audio.attempted.toSet(), {1});
        expect(container.read(playerStateProvider).currentSong?.id, 1);
        audio.failedIds.clear();
        clock.elapse(const Duration(seconds: 10));
        expect(audio.played, [1]);
        expect(container.read(playerStateProvider).isRetrying, isFalse);
        expect(container.read(playerStateProvider).infoMessage, isNull);
        container.dispose();
      });
    },
  );

  for (final action in ['pause', 'stop', 'toggle', 'next', 'dispose']) {
    test('$action cancels pending live reconnect and ignores late events', () {
      fakeAsync((clock) {
        container.invalidate(appPreferencesProvider);
        clock.flushMicrotasks();
        unawaited(player.playPlaylist([_radio(1), _radio(2)]));
        clock.flushMicrotasks();
        audio.onPlaybackError?.call();
        clock.flushMicrotasks();
        switch (action) {
          case 'pause':
            unawaited(audio.pause());
          case 'stop':
            unawaited(audio.stop());
          case 'toggle':
            unawaited(player.togglePlay());
          case 'next':
            unawaited(player.playNext());
          case 'dispose':
            container.dispose();
        }
        clock.flushMicrotasks();
        if (action != 'next' && action != 'dispose') {
          audio.onSongCompleted!();
          audio.onPlaybackError?.call();
        }
        clock.elapse(const Duration(minutes: 3));
        expect(audio.played, action == 'next' ? [1, 2] : [1]);
        if (action != 'dispose') container.dispose();
      });
    });
  }

  test('notification play resumes a cancelled live station', () {
    fakeAsync((clock) {
      container.invalidate(appPreferencesProvider);
      clock.flushMicrotasks();
      unawaited(player.playPlaylist([_radio(1), _radio(2)]));
      clock.flushMicrotasks();
      unawaited(audio.pause());
      clock.flushMicrotasks();
      unawaited(audio.onPlayRequested?.call());
      clock.flushMicrotasks();
      expect(audio.played, [1, 1]);
      container.dispose();
    });
  });

  test('pause cancels unlimited initial live load retries', () {
    fakeAsync((clock) {
      container.invalidate(appPreferencesProvider);
      clock.flushMicrotasks();
      audio.failedIds.add(1);
      unawaited(player.playPlaylist([_radio(1), _radio(2)]));
      clock.flushMicrotasks();
      expect(audio.attempted, [1]);
      unawaited(audio.pause());
      clock.flushMicrotasks();
      clock.elapse(const Duration(minutes: 3));
      expect(audio.attempted, [1]);
      expect(container.read(playerStateProvider).isRetrying, isFalse);
      container.dispose();
    });
  });

  test('duration sleep timer stops live reconnect', () {
    fakeAsync((clock) {
      container.invalidate(appPreferencesProvider);
      clock.flushMicrotasks();
      unawaited(player.playPlaylist([_radio(1), _radio(2)]));
      clock.flushMicrotasks();
      player.setSleepTimerByDuration(const Duration(seconds: 1));
      audio.onSongCompleted!();
      clock.flushMicrotasks();
      clock.elapse(const Duration(minutes: 3));
      expect(audio.played, [1]);
      expect(container.read(playerStateProvider).sleepTimer, isNull);
      container.dispose();
    });
  });

  test(
    'scheduling preserves current song, queue source, and playback',
    () async {
      await player.playPlaylist([_song(1), _song(2)], sourcePlaylistId: 42);
      await player.playSongNext(_song(3));
      final state = container.read(playerStateProvider);
      expect(audio.played, [1]);
      expect(state.currentSong?.id, 1);
      expect(state.playlist.map((s) => s.id), [1, 3, 2]);
      expect(state.playbackContext, PlaybackContext.playlist(42));
      expect(state.hasPriorityNext, isTrue);
      await player.playNext();
      expect(audio.played, [1, 3]);
      expect(container.read(playerStateProvider).hasPriorityNext, isFalse);
    },
  );

  test('an empty queue starts the requested song', () async {
    await player.playSongNext(_song(7));
    expect(audio.played, [7]);
    expect(container.read(playerStateProvider).currentIndex, 0);
    expect(container.read(playerStateProvider).hasPriorityNext, isFalse);
  });

  test(
    'random previous returns first actual song and next retraces history',
    () async {
      await player.setPlayMode(PlayMode.random);
      await player.playPlaylist([_song(1), _song(2), _song(3)]);
      await player.playNext();
      final second = container.read(playerStateProvider).currentSong!.id;
      expect(second, isNot(1));
      await player.playPrev();
      expect(audio.played, [1, second, 1]);
      await player.playNext();
      expect(audio.played, [1, second, 1, second]);
    },
  );

  test('latest scheduled song plays first, then earlier requests', () async {
    await player.setPlayMode(PlayMode.random);
    await player.playPlaylist([_song(1), _song(2), _song(3)]);
    await player.playSongNext(_song(2));
    await player.playSongNext(_song(3));
    await player.playNext();
    await player.playNext();
    expect(audio.played, [1, 3, 2]);
  });

  test(
    'single-loop completion honors manual next once and keeps the mode',
    () async {
      await player.setPlayMode(PlayMode.single);
      await player.playPlaylist([_song(1), _song(2)]);
      await player.playSongNext(_song(2));
      audio.onSongCompleted!();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(audio.played, [1, 2]);
      expect(container.read(playerStateProvider).playMode, PlayMode.single);
      audio.onSongCompleted!();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(audio.played, [1, 2, 2]);
    },
  );

  test('history and next song survive queue insert/reorder/delete', () async {
    await player.setPlayMode(PlayMode.random);
    await player.playPlaylist([_song(1), _song(2), _song(3)]);
    await player.playSong(_song(2));
    await player.playSongNext(_song(3));
    player.insertToPlaylist(0, _song(4));
    player.moveInPlaylist(3, 0);
    await player.removeFromPlaylist(1); // Remove unplayed song 4.
    await player.playPrev();
    expect(container.read(playerStateProvider).currentSong?.id, 1);
    await player.playNext();
    expect(container.read(playerStateProvider).currentSong?.id, 3);
    expect(audio.played, [1, 2, 1, 3]);
  });

  test(
    'scheduling current song replays once and returns to remaining queue',
    () async {
      final song = _song(1);
      await player.playPlaylist([song, _song(2)]);
      await player.playSongNext(song);
      await player.playSongNext(song);
      expect(container.read(playerStateProvider).playlist.length, 3);
      await player.playNext();
      await player.playNext();
      expect(audio.played, [1, 1, 2]);
    },
  );
  test(
    'rapid previous clicks keep moving back while audio is loading',
    () async {
      await player.setPlayMode(PlayMode.random);
      await player.playPlaylist([_song(1), _song(2), _song(3)]);
      await player.playSong(_song(2));
      await player.playSong(_song(3));
      audio.playGate = Completer<void>();
      final first = player.playPrev();
      final second = player.playPrev();
      expect(container.read(playerStateProvider).currentSong?.id, 1);
      audio.playGate!.complete();
      await Future.wait([first, second]);
      audio.playGate = null;
      await player.playNext();
      expect(container.read(playerStateProvider).currentSong?.id, 2);
    },
  );
  test(
    'scheduling while previous audio is loading preserves older history',
    () async {
      await player.setPlayMode(PlayMode.random);
      await player.playPlaylist([_song(1), _song(2), _song(3)]);
      await player.playSong(_song(2));
      await player.playSong(_song(3));
      audio.playGate = Completer<void>();
      final back = player.playPrev();
      await player.playSongNext(_song(4));
      audio.playGate!.complete();
      await back;
      audio.playGate = null;
      await player.playPrev();
      expect(container.read(playerStateProvider).currentSong?.id, 1);
      await player.playNext();
      expect(container.read(playerStateProvider).currentSong?.id, 4);
    },
  );

  test('previous during a new song load returns the last heard song', () async {
    await player.setPlayMode(PlayMode.random);
    await player.playPlaylist([_song(1), _song(2), _song(3)]);
    await player.playSongNext(_song(2));
    audio.playGate = Completer<void>();
    final next = player.playNext();
    final back = player.playPrev();
    expect(container.read(playerStateProvider).currentSong?.id, 1);
    audio.playGate!.complete();
    await Future.wait([next, back]);
    audio.playGate = null;
    expect(container.read(playerStateProvider).currentSong?.id, 1);
  });

  test(
    'selecting within the same queue keeps history, priority and source',
    () async {
      await player.setPlayMode(PlayMode.random);
      await player.playPlaylist([
        _song(1),
        _song(2),
        _song(3),
      ], sourcePlaylistId: 42);
      await player.playSongNext(_song(4));
      final songs = List<Song>.from(
        container.read(playerStateProvider).playlist,
      );
      await player.playPlaylist(songs, startIndex: 2, keepContext: true);
      expect(container.read(playerStateProvider).currentSong?.id, 2);
      expect(container.read(playerStateProvider).hasPriorityNext, isTrue);
      await player.playPrev();
      expect(container.read(playerStateProvider).currentSong?.id, 1);
      await player.playNext();
      expect(container.read(playerStateProvider).currentSong?.id, 4);
      expect(container.read(playerStateProvider).sourcePlaylistId, 42);
    },
  );
  test(
    'DLNA failure clears pending history navigation before going back',
    () async {
      await player.setPlayMode(PlayMode.random);
      await player.playPlaylist([_song(1), _song(2), _song(3)]);
      await player.playSong(_song(2));
      await player.playSong(_song(3));
      final casting = container.read(dlnaStateProvider.notifier);
      await casting.castToDevice(
        const DlnaDeviceInfo(
          id: 'renderer',
          name: 'Test renderer',
          location: 'https://renderer.example.test',
        ),
      );
      await player.playPrev(); // Successfully cast song 2.
      expect(dlna.titles, ['Song 3', 'Song 2']);
      dlna.fail = true;
      await player.playNext(); // Forward-history song 3 fails.
      expect(container.read(dlnaStateProvider).error, isNotNull);
      dlna.fail = false;
      await player.playPrev();
      expect(container.read(playerStateProvider).currentSong?.id, 2);
      expect(dlna.titles.last, 'Song 2');
      await player.playPrev();
      expect(container.read(playerStateProvider).currentSong?.id, 1);
    },
  );

  test(
    'DLNA completion honors manual next before single loop and single play',
    () async {
      for (final mode in [PlayMode.single, PlayMode.singlePlay]) {
        // Start a fresh queue while retaining the established casting session.
        await player.setPlayMode(mode);
        await player.playPlaylist([_song(1), _song(2)]);
        final casting = container.read(dlnaStateProvider.notifier);
        if (!container.read(dlnaStateProvider).isCasting) {
          await casting.castToDevice(
            const DlnaDeviceInfo(
              id: 'renderer',
              name: 'Test renderer',
              location: 'https://renderer.example.test',
            ),
          );
        }
        await player.playSongNext(_song(2));
        dlna.completed.add(null);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(container.read(playerStateProvider).currentSong?.id, 2);
        expect(container.read(playerStateProvider).hasPriorityNext, isFalse);
        expect(container.read(playerStateProvider).playMode, mode);
        expect(dlna.titles.last, 'Song 2');
        dlna.completed.add(null);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (mode == PlayMode.singlePlay) {
          expect(container.read(dlnaStateProvider).isPlaying, isFalse);
        }
      }
    },
  );
  test(
    'failure skip honors manual next after the queue is reordered',
    () async {
      await player.playPlaylist([_song(1), _song(2), _song(3)]);
      await player.playSongNext(_song(3));
      player.moveInPlaylist(1, 0); // Priority song now precedes current song.
      audio.failedIds.add(1);
      await player.playSong(
        _song(1),
      ); // Exhaust retries, then skip automatically.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(audio.played, [1, 3]);
      expect(container.read(playerStateProvider).currentSong?.id, 3);
      expect(container.read(playerStateProvider).hasPriorityNext, isFalse);
    },
  );

  // ---- 区域队列接管（Roon 模型：区域拥有队列） ----

  test('adoptZoneQueue 换队列与当前曲目，但不起播', () async {
    await player.playPlaylist([_song(1), _song(2)]);
    expect(audio.played, [1]);

    await player.adoptZoneQueue(
      [_song(7), _song(8), _song(9)],
      index: 1,
      position: const Duration(seconds: 42),
    );

    final st = container.read(playerStateProvider);
    expect(st.playlist.map((s) => s.id), [7, 8, 9]);
    expect(st.currentIndex, 1);
    expect(st.currentSong?.id, 8);
    expect(st.currentTime, const Duration(seconds: 42));
    expect(st.isPlaying, isFalse);
    // 切区域不能顺带出声：本机只接管队列。
    expect(audio.played, [1]);
  });

  test('adoptZoneQueue 空队列表示清空', () async {
    await player.playPlaylist([_song(1), _song(2)]);

    await player.adoptZoneQueue(const <Song>[]);

    final st = container.read(playerStateProvider);
    expect(st.playlist, isEmpty);
    expect(st.currentIndex, -1);
    expect(st.hasSong, isFalse);
  });

  test('adoptZoneQueue 下标越界时夹到合法范围', () async {
    await player.adoptZoneQueue([_song(7), _song(8)], index: 9);

    final st = container.read(playerStateProvider);
    expect(st.currentIndex, 1);
    expect(st.currentSong?.id, 8);
  });

  test('adoptZoneQueue 同步总时长，远端区域进度条按本区域曲目画', () async {
    await player.adoptZoneQueue(
      [_song(7), _song(8)],
      index: 1,
      position: const Duration(seconds: 30),
      mirrorPlaying: true,
    );

    final st = container.read(playerStateProvider);
    // _song() 的 duration 是 180s：远端区域本机不加载音源，
    // durationStream 不会更新，必须由 adopt 写入。
    expect(st.duration, const Duration(seconds: 180));
  });

  test('adoptZoneQueue 位置超过曲目时长时归零，避免瞬间播完', () async {
    // 服务端历史脏数据可能给出超过时长的位置（实测 283s / 193.8s 的歌），
    // 直接 seek 会立刻 completed，表现为「切区域后歌瞬间播完」。
    await player.adoptZoneQueue([
      _song(7),
    ], position: const Duration(seconds: 283));

    final st = container.read(playerStateProvider);
    expect(st.currentTime, Duration.zero);
    expect(st.isPlaying, isFalse);
  });

  test('adoptZoneQueue 位置为 0 时不发 seek，按区域位置从头播', () async {
    // 区域位置是唯一权威：切到位置为 0 的区域后，本机必须从 0 开始，
    // 不能被上次会话的恢复点（实测 77s）或服务端旧位置拽走。
    await player.adoptZoneQueue(
      [_song(7)],
      position: Duration.zero,
      localZone: true,
    );

    expect(audio.played, [7]);
    expect(audio.seeks, isEmpty);
    expect(container.read(playerStateProvider).currentTime, Duration.zero);
  });

  test('adoptZoneQueue mirrorPlaying 镜像远端播放态但不出声', () async {
    await player.adoptZoneQueue(
      [_song(7), _song(8)],
      index: 1,
      position: const Duration(seconds: 42),
      mirrorPlaying: true,
    );

    final st = container.read(playerStateProvider);
    expect(st.currentSong?.id, 8);
    expect(st.currentTime, const Duration(seconds: 42));
    // 远端区域正在播放：UI 显示播放态，但本机不能出声。
    expect(st.isPlaying, isTrue);
    expect(audio.played, isEmpty);
  });

  test('advanceRemotePosition 只在播放时推进进度', () async {
    await player.adoptZoneQueue(
      [_song(7)],
      position: const Duration(seconds: 10),
      mirrorPlaying: true,
    );

    player.advanceRemotePosition(const Duration(seconds: 1));
    expect(
      container.read(playerStateProvider).currentTime,
      const Duration(seconds: 11),
    );

    player.applyRemoteZoneStatus(
      playing: false,
      position: const Duration(seconds: 11),
    );
    player.advanceRemotePosition(const Duration(seconds: 1));
    expect(
      container.read(playerStateProvider).currentTime,
      const Duration(seconds: 11),
    );
  });

  test('applyRemoteZoneStatus 只镜像展示字段，不碰音频', () async {
    await player.adoptZoneQueue([_song(7)], index: 0);

    player.applyRemoteZoneStatus(
      playing: true,
      position: const Duration(seconds: 12),
    );

    final st = container.read(playerStateProvider);
    expect(st.isPlaying, isTrue);
    expect(st.currentTime, const Duration(seconds: 12));
    // 远端区域出声的是它的设备，本机不能跟着播。
    expect(audio.played, isEmpty);

    player.applyRemoteZoneStatus(
      playing: false,
      position: const Duration(seconds: 30),
    );
    expect(container.read(playerStateProvider).isPlaying, isFalse);
    expect(
      container.read(playerStateProvider).currentTime,
      const Duration(seconds: 30),
    );
  });
}
