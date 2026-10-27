import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:songloft_flutter/features/playback/data/local_output.dart';

/// 内存传输层：记录所有出站报文，测试可手动推入服务端指令。
class _FakeTransport implements LocalOutputTransport {
  final StreamController<Map<String, dynamic>> _messages =
      StreamController<Map<String, dynamic>>.broadcast();
  final ValueNotifier<bool> _connected = ValueNotifier<bool>(false);
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  @override
  ValueListenable<bool> get connected => _connected;

  @override
  bool send(Map<String, dynamic> message) {
    if (!_connected.value) return false;
    sent.add(message);
    return true;
  }

  void setConnected(bool value) => _connected.value = value;

  void emit(Map<String, dynamic> message) => _messages.add(message);

  Future<void> close() async {
    _connected.dispose();
    await _messages.close();
  }
}

/// 记录调用顺序的音频 fake；字段可配置，供 report 报文断言。
class _FakeAudio implements LocalAudio {
  int? loadedSongId;
  Duration? loadedPosition;
  Completer<void>? loadGate;
  int playCalls = 0;
  int pauseCalls = 0;
  final List<Duration> seekCalls = <Duration>[];
  final List<double> volumeCalls = <double>[];
  int skipNextCalls = 0;
  int skipPreviousCalls = 0;
  int stopCalls = 0;

  @override
  Duration position = Duration.zero;

  @override
  double volume = 40;

  @override
  bool isPlaying = false;

  @override
  bool isBuffering = false;

  @override
  bool hasSong = false;

  @override
  int? songId;

  @override
  Future<void> load(int songId, {required Duration position}) async {
    this.songId = songId;
    loadedSongId = songId;
    loadedPosition = position;
    hasSong = true;
    await loadGate?.future;
  }

  @override
  Future<void> play() async => playCalls++;

  @override
  Future<void> pause() async => pauseCalls++;

  @override
  Future<void> seek(Duration position) async => seekCalls.add(position);

  @override
  Future<void> setVolume(double volume) async => volumeCalls.add(volume);

  @override
  Future<void> skipNext() async => skipNextCalls++;

  @override
  Future<void> skipPrevious() async => skipPreviousCalls++;

  @override
  Future<void> stop() async => stopCalls++;
}

class _FakeMembership implements LocalZoneMembership {
  _FakeMembership(this.groups);

  Set<String> groups;

  @override
  Future<Set<String>> groupsContaining(String playerId) async => groups;
}

class _FakeDeviceIdSource implements LocalDeviceIdSource {
  _FakeDeviceIdSource(this.id);

  final String id;
  int calls = 0;

  @override
  Future<String> loadOrCreate() async {
    calls++;
    return id;
  }
}

/// 可手动触发的 Timer fake：记录周期并允许逐次 fire。
class _FakeTimer implements Timer {
  _FakeTimer(this.duration, this.callback);

  final Duration duration;
  final void Function() callback;
  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _tick++;
    callback();
  }
}

class _FakeTimerFactory {
  final List<_FakeTimer> timers = <_FakeTimer>[];

  _FakeTimer get latest => timers.last;

  Timer call(Duration duration, void Function() callback) {
    final timer = _FakeTimer(duration, callback);
    timers.add(timer);
    return timer;
  }
}

LocalOutput _buildOutput({
  required _FakeTransport transport,
  required _FakeAudio audio,
  _FakeMembership? membership,
  _FakeTimerFactory? timers,
  String deviceId = 'dev-1',
}) {
  return LocalOutput(
    transport: transport,
    audio: audio,
    membership: membership ?? _FakeMembership(<String>{}),
    deviceIdSource: _FakeDeviceIdSource(deviceId),
    deviceName: '测试设备',
    timerFactory: timers?.call,
    observeLifecycle: false,
  );
}

/// 让 stream 事件与 unawaited 的异步指令跑完。
Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalDeviceIdStore', () {
    test('首次生成后持久化，二次读取相同', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      final first = await LocalDeviceIdStore().loadOrCreate();
      expect(first, isNotEmpty);
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(first),
        isTrue,
        reason: '设备 id 必须是 UUID v4 风格：$first',
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(localDeviceIdKey), first);

      // 模拟重启：新的 store 实例必须读到同一个 id。
      final second = await LocalDeviceIdStore().loadOrCreate();
      expect(second, first);
    });

    test('已有持久化 id 时直接复用，不重新生成', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        localDeviceIdKey: 'existing-device-id',
      });

      expect(await LocalDeviceIdStore().loadOrCreate(), 'existing-device-id');
    });
  });

  group('LocalOutput', () {
    test('register 报文含 id/kind/name/caps', () async {
      final transport = _FakeTransport();
      final audio = _FakeAudio();
      final output = _buildOutput(transport: transport, audio: audio);

      transport.setConnected(true);
      await output.start();

      expect(output.deviceId, 'dev-1');
      expect(output.isRegistered, isTrue);
      expect(transport.sent, hasLength(1));

      final register = transport.sent.single;
      expect(register['type'], 'register_player');
      expect(register['id'], 'dev-1');
      expect(register['kind'], 'local');
      expect(register['name'], '测试设备');

      final caps = register['caps'] as Map<String, dynamic>;
      expect(caps['codecs'], LocalOutput.supportedCodecs);
      expect(caps['sample_rates'], LocalOutput.supportedSampleRates);

      await output.dispose();
      await transport.close();
    });

    test('report 报文按 500ms 周期发送', () async {
      final transport = _FakeTransport();
      final audio =
          _FakeAudio()
            ..position = const Duration(seconds: 12)
            ..volume = 37.6
            ..isPlaying = true
            ..hasSong = true;
      final timers = _FakeTimerFactory();
      final output = _buildOutput(
        transport: transport,
        audio: audio,
        timers: timers,
      );

      transport.setConnected(true);
      await output.start();

      expect(timers.timers, hasLength(1));
      expect(timers.latest.duration, const Duration(milliseconds: 500));
      expect(
        transport.sent.where((m) => m['type'] == 'report'),
        isEmpty,
        reason: '注册后不能立刻上报，必须等第一个 500ms 周期',
      );

      timers.latest.fire();
      final reports =
          transport.sent.where((m) => m['type'] == 'report').toList();
      expect(reports, hasLength(1));
      expect(reports.single['id'], 'dev-1');
      expect(reports.single['position_ms'], 12000);
      expect(reports.single['buffering'], isFalse);
      expect(reports.single['volume'], 38);
      expect(reports.single['state'], 'playing');

      // 一次性 Timer 自续：fire 后必须重新排一个 500ms 的 Timer。
      expect(timers.timers, hasLength(2));
      expect(timers.latest.duration, const Duration(milliseconds: 500));
      timers.latest.fire();
      expect(transport.sent.where((m) => m['type'] == 'report'), hasLength(2));

      await output.dispose();
      expect(timers.latest.isActive, isFalse, reason: 'dispose 必须停掉心跳');
      await transport.close();
    });

    test(
      'play waits for the current load and stop cancels the waiting play',
      () async {
        final transport = _FakeTransport();
        final audio = _FakeAudio()..loadGate = Completer<void>();
        final output = _buildOutput(
          transport: transport,
          audio: audio,
          membership: _FakeMembership(<String>{'g1'}),
        );
        transport.setConnected(true);
        await output.start();
        await output.setFocusedGroup('g1');
        transport.emit(<String, dynamic>{'cmd': 'load', 'song_id': 42});
        transport.emit(<String, dynamic>{'cmd': 'play'});
        await _flush();
        expect(audio.playCalls, 0);
        transport.emit(<String, dynamic>{'cmd': 'stop'});
        audio.loadGate!.complete();
        await _flush();
        expect(audio.playCalls, 0);
        audio.loadGate = Completer<void>();
        transport.emit(<String, dynamic>{'cmd': 'load', 'song_id': 43});
        transport.emit(<String, dynamic>{'cmd': 'play'});
        await _flush();
        expect(audio.playCalls, 0);
        audio.loadGate!.complete();
        await _flush();
        expect(audio.playCalls, 1);
        await output.dispose();
        await transport.close();
      },
    );

    test('服务端指令 load/play/pause/seek/volume 映射到 audio', () async {
      final transport = _FakeTransport();
      final audio = _FakeAudio();
      final output = _buildOutput(
        transport: transport,
        audio: audio,
        membership: _FakeMembership(<String>{'g1'}),
      );

      transport.setConnected(true);
      await output.start();
      await output.setFocusedGroup('g1');

      transport.emit(<String, dynamic>{
        'cmd': 'load',
        'song_id': 42,
        'position_ms': 1500,
      });
      await _flush();
      expect(audio.loadedSongId, 42);
      expect(audio.loadedPosition, const Duration(milliseconds: 1500));
      expect(output.isServerControlled, isTrue);

      transport.emit(<String, dynamic>{'cmd': 'play'});
      await _flush();
      expect(audio.playCalls, 1);

      transport.emit(<String, dynamic>{'cmd': 'pause'});
      await _flush();
      expect(audio.pauseCalls, 1);

      transport.emit(<String, dynamic>{'cmd': 'seek', 'position_ms': 30000});
      await _flush();
      expect(audio.seekCalls, <Duration>[const Duration(seconds: 30)]);

      transport.emit(<String, dynamic>{'cmd': 'volume', 'volume': 73});
      await _flush();
      expect(audio.volumeCalls, <double>[73]);

      await output.dispose();
      await transport.close();
    });

    test('控制其它区域时仍执行发给本机的服务端指令', () async {
      final transport = _FakeTransport();
      final audio = _FakeAudio();
      final output = _buildOutput(
        transport: transport,
        audio: audio,
        membership: _FakeMembership(<String>{'other-group'}),
      );

      transport.setConnected(true);
      await output.start();
      await output.setFocusedGroup('g1');

      transport.emit(<String, dynamic>{'cmd': 'pause'});
      await _flush();

      expect(audio.pauseCalls, 1);
      expect(output.isServerControlled, isTrue);

      await output.dispose();
      await transport.close();
    });

    test('dispose 发送 unregister_player 报文', () async {
      final transport = _FakeTransport();
      final audio = _FakeAudio();
      final output = _buildOutput(transport: transport, audio: audio);

      transport.setConnected(true);
      await output.start();
      expect(output.isRegistered, isTrue);

      await output.dispose();

      final unregister = transport.sent.last;
      expect(unregister['type'], 'unregister_player');
      expect(unregister['id'], 'dev-1');
      expect(output.isRegistered, isFalse);

      await transport.close();
    });
  });
}
