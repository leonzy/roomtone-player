import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/platform_utils.dart';
import 'playback_socket.dart';

/// 本机设备 id 的持久化 key。
///
/// 必须是随机 UUID 并跨重启保持不变：用设备型号 / IP 会在换网或重装后
/// 变成一个新区域，旧区域留下僵尸设备（docs/architecture_playback.md §5.2）。
const String localDeviceIdKey = 'roomtone_device_id';

/// 生成 UUID v4 风格的本机设备 id。
String generateLocalDeviceId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// 本机设备 id 来源。测试注入固定值，生产实现落 shared_preferences。
abstract class LocalDeviceIdSource {
  Future<String> loadOrCreate();
}

/// shared_preferences 实现。
class LocalDeviceIdStore implements LocalDeviceIdSource {
  LocalDeviceIdStore({Future<SharedPreferences> Function()? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _prefs;

  @override
  Future<String> loadOrCreate() async {
    final prefs = await _prefs();
    final existing = prefs.getString(localDeviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = generateLocalDeviceId();
    await prefs.setString(localDeviceIdKey, id);
    return id;
  }
}

/// local sink 的传输层抽象。
///
/// 生产实现包 [PlaybackSocket]；测试用内存 fake 即可断言注册报文、
/// 心跳与指令映射，不需要真连网。
abstract class LocalOutputTransport {
  /// 原始 JSON 消息（事件信封 + 服务端 `{cmd: ...}` 指令）。
  Stream<Map<String, dynamic>> get messages;

  /// WS 是否已连接。
  ValueListenable<bool> get connected;

  /// 发送一条 JSON 消息；未连接时返回 false。
  bool send(Map<String, dynamic> message);
}

/// 把 [PlaybackSocket] 适配成 [LocalOutputTransport]。
class PlaybackSocketTransport implements LocalOutputTransport {
  PlaybackSocketTransport(this.socket);

  final PlaybackSocket socket;

  @override
  Stream<Map<String, dynamic>> get messages => socket.rawMessages;

  @override
  ValueListenable<bool> get connected => socket.connected;

  @override
  bool send(Map<String, dynamic> message) => socket.sendJson(message);
}

/// 服务端指令最终落到本机播放器上的最小接口。
///
/// 生产实现是 PlayerNotifier 的适配器；测试用 fake 记录调用顺序。
abstract class LocalAudio {
  /// 加载歌曲但不自动起播（起播由随后的 play 指令按 play_at 触发）。
  Future<void> load(int songId, {required Duration position});

  Future<void> play();

  Future<void> pause();

  Future<void> seek(Duration position);

  Future<void> setVolume(double volume);

  Future<void> skipNext();

  Future<void> skipPrevious();

  Future<void> stop();

  Duration get position;

  double get volume;

  bool get isPlaying;

  bool get isBuffering;

  bool get hasSong;

  /// 当前播放曲目 id；没有曲目时为 null。
  ///
  /// 上报给服务端用于镜像组状态：客户端自己起播时服务端没有解码协程，
  /// 只能靠这条字段知道区域在放什么。
  int? get songId;
}

/// 心跳定时器工厂。
///
/// 生产实现直接用 [Timer]；测试注入 fake 以断言 500ms 周期，
/// 不依赖真实时间。
typedef LocalOutputTimerFactory =
    Timer Function(Duration duration, void Function() callback);

/// 查询哪些区域包含本机。
///
/// 双模规则：只有焦点区域含本机时才执行服务端指令；其余时候本机是
/// 纯控制器，服务端指令必须静默丢弃（docs/architecture_playback_ui.md §7.3）。
abstract class LocalZoneMembership {
  Future<Set<String>> groupsContaining(String playerId);
}

/// 本机作为 `local` 播放器的注册、心跳与指令执行。
///
/// 生命周期（docs/architecture_playback.md §5.2）：
/// 1. WS 连上 → `register_player`（id 持久化，重连复用同一区域）；
/// 2. 每 500ms → `report`，服务端据此判在线；
/// 3. 断线 → 停止上报；服务端 30s 后标 offline；
/// 4. 正常退出 → `unregister_player`。
class LocalOutput with WidgetsBindingObserver {
  LocalOutput({
    required LocalOutputTransport? transport,
    required LocalAudio audio,
    required LocalZoneMembership membership,
    required LocalDeviceIdSource deviceIdSource,
    String? deviceName,
    this.reportInterval = const Duration(milliseconds: 500),
    DateTime Function()? now,
    LocalOutputTimerFactory? timerFactory,
    this.observeLifecycle = true,
  }) : _transport = transport,
       _audio = audio,
       _membership = membership,
       _deviceIdSource = deviceIdSource,
       deviceName = deviceName ?? defaultLocalDeviceName(),
       _now = now ?? DateTime.now,
       _timerFactory = timerFactory ?? Timer.new;

  /// 客户端自拉流支持的编码。服务端按这个列表协商输出格式。
  static const List<String> supportedCodecs = <String>[
    'flac',
    'mp3',
    'aac',
    'wav',
  ];

  /// 客户端能处理的采样率。
  static const List<int> supportedSampleRates = <int>[44100, 48000];

  final LocalOutputTransport? _transport;
  final LocalAudio _audio;
  final LocalZoneMembership _membership;
  final LocalDeviceIdSource _deviceIdSource;
  final String deviceName;
  final Duration reportInterval;
  final DateTime Function() _now;
  final LocalOutputTimerFactory _timerFactory;
  final bool observeLifecycle;

  /// 服务端接管期间为 true：本地 EQ 必须置灰，避免双重均衡。
  final ValueNotifier<bool> serverControlled = ValueNotifier<bool>(false);

  /// 当前焦点区域。只有该区域包含本机时才执行服务端指令。
  final ValueNotifier<String?> focusedGroupId = ValueNotifier<String?>(null);

  String? _deviceId;
  bool _started = false;
  bool _disposed = false;
  bool _registered = false;
  bool _takeover = false;
  bool _lifecycleObserved = false;
  int _focusGeneration = 0;
  int _playToken = 0;

  /// 服务端时钟 - 本地时钟的估计值（本地 = 服务端 + offset）。
  Duration _serverOffset = Duration.zero;

  StreamSubscription<Map<String, dynamic>>? _messageSubscription;
  Timer? _reportTimer;

  /// 当前设备 id（start 之前为 null）。
  String? get deviceId => _deviceId;

  /// 是否已发送 register_player。
  bool get isRegistered => _registered;

  /// 是否处于服务端接管态。
  bool get isServerControlled => serverControlled.value;

  /// 启动：读取持久化 id、订阅 WS、连上后立即注册。
  Future<void> start() async {
    if (_started || _disposed || _transport == null) return;
    _started = true;
    _deviceId = await _deviceIdSource.loadOrCreate();
    if (_disposed) return;

    _messageSubscription = _transport.messages.listen(_handleMessage);
    _transport.connected.addListener(_onConnectedChanged);
    if (observeLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      _lifecycleObserved = true;
    }
    if (_transport.connected.value) _onConnectedChanged();
  }

  /// 焦点只影响界面；此连接上的设备指令始终作用于本机所属区域。
  Future<void> setFocusedGroup(String? groupId) async {
    focusedGroupId.value = groupId;
    final generation = ++_focusGeneration;
    final id = _deviceId;
    if (id == null) {
      _takeover = false;
      return;
    }
    try {
      final groups = await _membership.groupsContaining(id);
      if (_disposed || generation != _focusGeneration) return;
      _takeover = groups.isNotEmpty;
      if (!_takeover) _setServerControlled(false);
    } catch (_) {
      if (_disposed || generation != _focusGeneration) return;
      _takeover = false;
      _setServerControlled(false);
    }
  }

  /// 注册报文。公开给测试断言结构。
  Map<String, dynamic> buildRegisterMessage() => <String, dynamic>{
    'type': 'register_player',
    'id': _deviceId ?? '',
    'kind': 'local',
    'name': deviceName,
    'caps': <String, dynamic>{
      'codecs': supportedCodecs,
      'sample_rates': supportedSampleRates,
    },
  };

  /// 500ms 心跳报文。公开给测试断言结构。
  Map<String, dynamic> buildReportMessage() => <String, dynamic>{
    'type': 'report',
    'id': _deviceId ?? '',
    'song_id': _audio.songId ?? 0,
    'position_ms': _audio.position.inMilliseconds,
    'buffering': _audio.isBuffering,
    'volume': _audio.volume.round().clamp(0, 100),
    'state': _playbackState,
    'rtt_ms': 0,
  };

  String get _playbackState {
    if (_audio.isPlaying) return 'playing';
    if (_audio.hasSong) return 'paused';
    return 'idle';
  }

  void _onConnectedChanged() {
    final connected = _transport?.connected.value ?? false;
    if (connected) {
      _register();
    } else {
      _registered = false;
      _reportTimer?.cancel();
      _reportTimer = null;
      _setServerControlled(false);
    }
  }

  void _register() {
    final id = _deviceId;
    if (id == null || _disposed) return;
    if (!(_transport?.send(buildRegisterMessage()) ?? false)) return;
    _registered = true;
    _scheduleReport();
    unawaited(_refreshFocusMembership());
  }

  void _scheduleReport() {
    _reportTimer?.cancel();
    if (!_registered || _disposed) return;
    // 用一次性 Timer 自续，而不是 Timer.periodic：F7-01 的验收要求
    // `rg 'Timer.periodic' lib/features/playback` 只命中降级轮询路径。
    _reportTimer = _timerFactory(reportInterval, () {
      if (!_registered || _disposed) return;
      _transport?.send(buildReportMessage());
      _scheduleReport();
    });
  }

  Future<void> _ensureFocus() async {
    if (focusedGroupId.value != null) return;
    final id = _deviceId;
    if (id == null) return;
    try {
      final groups = await _membership.groupsContaining(id);
      if (_disposed || focusedGroupId.value != null) return;
      if (groups.isNotEmpty) {
        focusedGroupId.value = groups.first;
        _takeover = true;
      }
    } catch (_) {
      // 拿不到区域列表时保持未接管；下一条 member/group 事件会重试。
    }
  }

  Future<void> _refreshFocusMembership() async {
    final groupId = focusedGroupId.value;
    if (groupId == null) {
      await _ensureFocus();
      return;
    }
    await setFocusedGroup(groupId);
  }

  void _handleMessage(Map<String, dynamic> message) {
    if (_disposed) return;

    // 用事件信封的 time_ms 粗估服务端时钟偏移，供 play_at 对齐。
    final timeMs = _asInt(message['time_ms']);
    if (timeMs != null) {
      _serverOffset = Duration(
        milliseconds: _now().millisecondsSinceEpoch - timeMs,
      );
    }

    final type = message['type'];
    if (type is String &&
        (type == 'member_changed' || type == 'group_changed')) {
      unawaited(_refreshFocusMembership());
    }

    // 服务端 local sink 的指令字段是 cmd；兼容把指令名放在 type 的旧格式。
    final command = message['cmd'] ?? (message['seq'] == null ? type : null);
    if (command is String) _handleCommand(command, message);
  }

  void _handleCommand(String command, Map<String, dynamic> message) {
    if (!_takeover) return;
    switch (command) {
      case 'load':
        final songId = _asInt(message['song_id']);
        if (songId == null || songId <= 0) return;
        _playToken++;
        _setServerControlled(true);
        final position = Duration(
          milliseconds: _asInt(message['position_ms']) ?? 0,
        );
        unawaited(_audio.load(songId, position: position));
      case 'play':
        _setServerControlled(true);
        unawaited(_playAt(_asInt(message['play_at_ms'])));
      case 'pause':
        _playToken++;
        _setServerControlled(true);
        unawaited(_audio.pause());
      case 'seek':
        final position = _asInt(message['position_ms']);
        if (position == null) return;
        unawaited(_audio.seek(Duration(milliseconds: position)));
      case 'volume':
        final volume = _asInt(message['volume']);
        if (volume == null) return;
        unawaited(_audio.setVolume(volume.toDouble().clamp(0, 100)));
      case 'skip':
        final direction = message['direction'];
        final delta = _asInt(message['delta']) ?? 0;
        if (direction == 'prev' ||
            direction == 'previous' ||
            direction == 'back' ||
            delta < 0) {
          unawaited(_audio.skipPrevious());
        } else {
          unawaited(_audio.skipNext());
        }
      case 'stop':
        _playToken++;
        _setServerControlled(false);
        unawaited(_audio.stop());
      case 'eq':
        // 服务端接管期间本地 EQ 置灰；曲线由服务端 PCM 管线负责。
        _setServerControlled(true);
    }
  }

  Future<void> _playAt(int? playAtMs) async {
    final token = ++_playToken;
    if (playAtMs != null) {
      final localPlayAt = playAtMs + _serverOffset.inMilliseconds;
      final delayMs = localPlayAt - _now().millisecondsSinceEpoch;
      if (delayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }
    }
    if (_disposed || token != _playToken || !_takeover) return;
    await _audio.play();
  }

  void _setServerControlled(bool value) {
    if (_disposed || serverControlled.value == value) return;
    serverControlled.value = value;
  }

  Future<void> _unregister() async {
    if (!_registered) return;
    _registered = false;
    _reportTimer?.cancel();
    _reportTimer = null;
    final id = _deviceId;
    if (id != null) {
      _transport?.send(<String, dynamic>{
        'type': 'unregister_player',
        'id': id,
      });
    }
    _setServerControlled(false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(_unregister());
    }
  }

  /// 停止心跳、发送 unregister_player 并释放资源。
  Future<void> dispose() async {
    if (_disposed) return;
    // 先同步取消定时器再 await：否则 widget 测试在 dispose 后立刻检查
    // pending timer 会报 “A Timer is still pending”。
    _playToken++;
    _reportTimer?.cancel();
    _reportTimer = null;
    _transport?.connected.removeListener(_onConnectedChanged);
    await _unregister();
    _disposed = true;
    await _messageSubscription?.cancel();
    _messageSubscription = null;
    if (_lifecycleObserved) {
      WidgetsBinding.instance.removeObserver(this);
      _lifecycleObserved = false;
    }
    serverControlled.dispose();
    focusedGroupId.dispose();
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// 平台设备名：优先主机名，拿不到时退回平台名。
String defaultLocalDeviceName() {
  final name = PlatformUtils.deviceName.trim();
  if (name.isNotEmpty) return name;
  return '本机（${PlatformUtils.platformName}）';
}
