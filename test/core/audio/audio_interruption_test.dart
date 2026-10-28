import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;

// Keep source imports relative, as required by the repository conventions.
// ignore: avoid_relative_lib_imports
import '../../../lib/core/audio/audio_service.dart';

class _Player implements ja.AudioPlayer {
  final events = StreamController<ja.PlaybackEvent>.broadcast(sync: true);
  final states = StreamController<ja.ProcessingState>.broadcast(sync: true);
  final playingEvents = StreamController<bool>.broadcast(sync: true);
  final errors = StreamController<ja.PlayerException>.broadcast(sync: true);
  @override
  Stream<ja.PlayerException> get errorStream => errors.stream;
  @override
  bool playing = true;
  @override
  ja.ProcessingState processingState = ja.ProcessingState.ready;
  int playCalls = 0;
  int pauseCalls = 0;
  Completer<void>? pauseGate;
  @override
  Stream<ja.PlaybackEvent> get playbackEventStream => events.stream;
  @override
  Stream<ja.ProcessingState> get processingStateStream => states.stream;
  @override
  Stream<bool> get playingStream => playingEvents.stream;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get bufferedPosition => Duration.zero;
  @override
  double get speed => 1;
  @override
  Future<void> stop() async {
    playing = false;
  }

  @override
  Future<void> play() async {
    playCalls++;
    playing = true;
    playingEvents.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    playing = false;
    await pauseGate?.future;
  }

  @override
  Future<void> dispose() async {
    await events.close();
    await states.close();
    await playingEvents.close();
    await errors.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session implements AudioSession {
  final interruptions = StreamController<AudioInterruptionEvent>.broadcast(
    sync: true,
  );
  final noisy = StreamController<void>.broadcast(sync: true);
  Completer<void>? configureGate;
  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      interruptions.stream;
  @override
  Stream<void> get becomingNoisyEventStream => noisy.stream;
  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {
    await configureGate?.future;
  }

  void begin([AudioInterruptionType type = AudioInterruptionType.unknown]) =>
      interruptions.add(AudioInterruptionEvent(true, type));
  void end([AudioInterruptionType type = AudioInterruptionType.pause]) =>
      interruptions.add(AudioInterruptionEvent(false, type));
  Future<void> close() async {
    await interruptions.close();
    await noisy.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Player player;
  late _Session session;
  late SongloftAudioHandler handler;

  setUp(() async {
    player = _Player();
    session = _Session();
    handler = SongloftAudioHandler(player: player, audioSession: session);
    await handler.ensureInitialized();
  });
  tearDown(() async {
    player.pauseGate?.complete();
    await handler.dispose();
    await session.close();
  });
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('iOS unknown begin and shouldResume end resumes exactly once', () async {
    session.begin();
    expect(player.playing, isFalse);
    expect(player.pauseCalls, 1);
    session.end();
    await flush();
    expect(player.playCalls, 1);
    expect(player.playing, isTrue);
    session.end();
    await flush();
    expect(player.playCalls, 1);
  });

  test(
    'duplicate begin does not overwrite the original playback intent',
    () async {
      session.begin();
      session.begin();
      session.end();
      await flush();
      expect(player.pauseCalls, 1);
      expect(player.playCalls, 1);
    },
  );

  test('unknown end without shouldResume stays paused', () async {
    session.begin();
    session.end(AudioInterruptionType.unknown);
    await flush();
    expect(player.playCalls, 0);
    // An unmatched later end must not consume stale intent.
    session.end();
    await flush();
    expect(player.playCalls, 0);
    await handler.play();
    expect(player.playCalls, 1);
  });

  test('already paused before interruption stays paused', () async {
    player.playing = false;
    session.begin();
    session.end();
    await flush();
    expect(player.playCalls, 0);
  });

  for (final action in ['pause', 'stop', 'unplug', 'dispose']) {
    test('$action during interruption prevents resume', () async {
      session.begin();
      switch (action) {
        case 'pause':
          await handler.pause();
        case 'stop':
          await handler.stop();
        case 'unplug':
          session.noisy.add(null);
        case 'dispose':
          await handler.dispose();
      }
      session.end();
      await flush();
      expect(player.playCalls, 0);
    });
  }

  test('headphone unplug pauses and duck events do not restart it', () async {
    session.begin(AudioInterruptionType.duck);
    expect(player.pauseCalls, 0);
    session.noisy.add(null);
    session.end(AudioInterruptionType.duck);
    await flush();
    expect(player.playing, isFalse);
    expect(player.playCalls, 0);
  });

  test('duck pair does not consume a pending pause interruption', () async {
    session.begin();
    session.begin(AudioInterruptionType.duck);
    session.end(AudioInterruptionType.duck);
    expect(player.playCalls, 0);
    session.end();
    await flush();
    expect(player.playCalls, 1);
  });

  test('resume waits for an asynchronous pause to finish', () async {
    player.pauseGate = Completer<void>();
    session.begin();
    session.end();
    await flush();
    expect(player.playCalls, 0);
    player.pauseGate!.complete();
    player.pauseGate = null;
    await flush();
    expect(player.playCalls, 1);
  });

  test('manual pause after end cancels a queued resume', () async {
    player.pauseGate = Completer<void>();
    session.begin();
    session.end();
    final pausing = handler.pause();
    player.pauseGate!.complete();
    player.pauseGate = null;
    await pausing;
    await flush();
    expect(player.playCalls, 0);
  });

  test(
    'a second interruption defers a queued resume until its own end',
    () async {
      player.pauseGate = Completer<void>();
      session.begin();
      session.end();
      session.begin();
      player.pauseGate!.complete();
      player.pauseGate = null;
      await flush();
      expect(player.playCalls, 0);
      session.end();
      await flush();
      expect(player.playCalls, 1);
    },
  );

  test('resume delegates to the live reconnect entry point', () async {
    player.playing = false;
    handler.setLiveReconnecting(true);
    var reconnects = 0;
    handler.onPlayRequested = () async {
      reconnects++;
      return true;
    };
    session.begin();
    session.end();
    await flush();
    expect(reconnects, 1);
    expect(player.playCalls, 0);
  });

  test('manual pause while the resume hook awaits prevents playback', () async {
    final gate = Completer<bool>();
    handler.onPlayRequested = () => gate.future;
    session.begin();
    session.end();
    await flush();
    await handler.pause();
    gate.complete(false);
    await flush();
    expect(player.playCalls, 0);
  });

  test('failed delegated resume is handled', () async {
    handler.onPlayRequested = () async => throw StateError('load failed');
    session.begin();
    session.end();
    await flush();
    expect(player.playCalls, 0);
  });

  test('dispose during configuration cannot install late listeners', () async {
    await handler.dispose();
    session.configureGate = Completer<void>();
    player = _Player();
    handler = SongloftAudioHandler(player: player, audioSession: session);
    await handler.dispose();
    session.configureGate!.complete();
    await handler.ensureInitialized();
    expect(session.interruptions.hasListener, isFalse);
    expect(session.noisy.hasListener, isFalse);
  });
}
