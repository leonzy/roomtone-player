import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../config/app_config.dart';
import '../domain/playback_event.dart';

/// 播放事件传输层抽象。
///
/// 生产实现是 [DioPlaybackConnector]（Dio 换 ticket / 拉全量 + web_socket_channel
/// 建连）；测试注入假实现即可覆盖退避、降级与去重，不需要真连网。
abstract class PlaybackConnector {
  /// `POST /playback/events/ticket`，返回一次性 ticket。
  Future<String> fetchTicket();

  /// 用 ticket 升级 WebSocket。返回时握手必须已经成功。
  Future<PlaybackConnection> openEvents(String ticket);

  /// `GET /playback` 全量快照（重连对齐 / 降级轮询共用）。
  Future<Map<String, dynamic>> fetchPlayback();
}

/// 一条已建立的播放事件连接。
abstract class PlaybackConnection {
  /// WS 文本帧。实现负责把二进制帧转成 UTF-8 字符串。
  Stream<String> get messages;

  /// 发送一条文本帧。
  void send(String payload);

  Future<void> close();
}

/// 生产实现：复用 [Dio] 的 baseUrl 与认证拦截器（token 不手工拼）。
///
/// ticket 请求走 [dio]，因此自动带 `Authorization: Bearer <token>`；
/// WS 握手只用 URL 里的 ticket（浏览器无法给 WS 设置 Authorization 头）。
class DioPlaybackConnector implements PlaybackConnector {
  DioPlaybackConnector({required this.dio, String? baseUrl})
    : _baseUrl = baseUrl;

  /// WS 握手超时。服务端接受 TCP 但迟迟不完成升级时，不能让重连循环卡死。
  static const Duration handshakeTimeout = Duration(seconds: 10);

  final Dio dio;
  final String? _baseUrl;

  /// WS 地址的根。默认用 [AppConfig.resolvedBaseUrl]：入口域名 302 解析后的
  /// 真实地址（与 Dio 的 RedirectResolveInterceptor 一致），避免 WS 握手
  /// 无法跟随 HTTP 重定向。显式传入 [baseUrl] 时优先使用（测试 / 特殊部署）。
  String get _root {
    final configured = _baseUrl;
    if (configured != null && configured.isNotEmpty) return configured;
    final resolved = AppConfig.resolvedBaseUrl;
    if (resolved.isNotEmpty) return resolved;
    return dio.options.baseUrl;
  }

  @override
  Future<String> fetchTicket() async {
    final res = await dio.post<Map<String, dynamic>>(
      '${AppConfig.apiPrefix}/playback/events/ticket',
    );
    final ticket = res.data?['ticket'];
    if (ticket is! String || ticket.isEmpty) {
      throw const FormatException('playback ticket missing');
    }
    return ticket;
  }

  @override
  Future<PlaybackConnection> openEvents(String ticket) async {
    final channel = WebSocketChannel.connect(eventsUri(ticket));
    try {
      await channel.ready.timeout(handshakeTimeout);
    } catch (_) {
      // 握手失败时 channel 可能仍处于半开状态，尽力关闭，避免泄漏。
      try {
        unawaited(channel.sink.close());
      } catch (_) {
        // 未完成握手时 close 可能同步抛错，忽略。
      }
      rethrow;
    }
    return _WebSocketPlaybackConnection(channel);
  }

  @override
  Future<Map<String, dynamic>> fetchPlayback() async {
    final res = await dio.get<dynamic>('${AppConfig.apiPrefix}/playback');
    final data = res.data;
    if (data is List) return <String, dynamic>{'groups': data};
    if (data is Map) return Map<String, dynamic>.from(data);
    return const <String, dynamic>{};
  }

  /// 构造 `ws(s)://<host><apiPrefix>/playback/events?ticket=...`。
  ///
  /// 保留根地址里的子路径（反代子路径部署），并跟随 http→ws / https→wss。
  @visibleForTesting
  Uri eventsUri(String ticket) {
    final root = Uri.parse(_root);
    final scheme = root.scheme == 'https' ? 'wss' : 'ws';
    var basePath = root.path;
    if (basePath.endsWith('/')) {
      basePath = basePath.substring(0, basePath.length - 1);
    }
    final prefix =
        AppConfig.apiPrefix.startsWith('/')
            ? AppConfig.apiPrefix
            : '/${AppConfig.apiPrefix}';
    return root.replace(
      scheme: scheme,
      path: '$basePath$prefix/playback/events',
      queryParameters: <String, String>{'ticket': ticket},
    );
  }
}

class _WebSocketPlaybackConnection implements PlaybackConnection {
  _WebSocketPlaybackConnection(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<String> get messages => _channel.stream.map((data) {
    if (data is String) return data;
    if (data is List<int>) return utf8.decode(data);
    return data.toString();
  });

  @override
  void send(String payload) => _channel.sink.add(payload);

  @override
  Future<void> close() => _channel.sink.close();
}

/// 播放事件 WebSocket 客户端。
///
/// 生命周期：
/// 1. [connect] 启动后台循环：`POST /playback/events/ticket` → WS 升级；
/// 2. 连接断开后按 1/2/4/8/16/30 秒指数退避重连（30 秒封顶）；
/// 3. 连续 [degradedAfterFailures] 次失败进入降级：[degraded] 置 true，
///    每 [pollInterval] 拉一次 `GET /playback` 写入 [snapshot]；
/// 4. 重连成功后立即拉一次 `/playback` 全量对齐，并停止降级轮询；
/// 5. 事件按 `seq` 去重：`seq <= lastSeq` 丢弃。重连后保留基线；若新连接
///    首条事件序号回退（服务端重启，seq 从 1 重新计数），重置基线后接受。
///
/// 单连接接收全部区域的事件，调用方按 `group_id` 分发，不要每个区域各开一条。
class PlaybackSocket {
  PlaybackSocket({
    required PlaybackConnector connector,
    this.pollInterval = const Duration(seconds: 3),
    this.backoffSchedule = defaultBackoffSchedule,
    this.degradedAfterFailures = 3,
  }) : assert(backoffSchedule.isNotEmpty, 'backoffSchedule 不能为空'),
       assert(degradedAfterFailures > 0, 'degradedAfterFailures 必须大于 0'),
       assert(pollInterval > Duration.zero, 'pollInterval 必须大于 0'),
       _connector = connector;

  /// 1/2/4/8/16/30 秒，30 秒封顶。
  static const List<Duration> defaultBackoffSchedule = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
  ];

  final PlaybackConnector _connector;

  /// 降级轮询间隔。
  final Duration pollInterval;

  /// 重连退避序列；用尽后停在最后一档。
  final List<Duration> backoffSchedule;

  /// 连续失败多少次进入降级。
  final int degradedAfterFailures;

  final StreamController<PlaybackEvent> _events =
      StreamController<PlaybackEvent>.broadcast();

  /// 原始 JSON 消息（含服务端下发的 `{cmd: ...}` 指令）。
  ///
  /// [events] 只保留带 `seq/type` 的事件信封；local sink 的指令没有 seq，
  /// 必须走这条流，否则会被当成坏消息丢掉。
  final StreamController<Map<String, dynamic>> _rawMessages =
      StreamController<Map<String, dynamic>>.broadcast();

  /// WS 是否已建立（重连成功置 true，断开置 false）。
  final ValueNotifier<bool> connected = ValueNotifier<bool>(false);

  /// 是否处于降级态（实时事件不可用，退回轮询）。
  final ValueNotifier<bool> degraded = ValueNotifier<bool>(false);

  /// 最近一次 `GET /playback` 快照。降级轮询与重连全量对齐都会更新。
  final ValueNotifier<Map<String, dynamic>?> snapshot =
      ValueNotifier<Map<String, dynamic>?>(null);

  int _lastSeq = 0;
  int _failures = 0;
  bool _started = false;
  bool _disposed = false;
  bool _firstEventAfterConnect = false;
  bool _pollInFlight = false;

  PlaybackConnection? _connection;
  StreamSubscription<String>? _subscription;
  Completer<void>? _connectionClosed;
  Timer? _pollTimer;
  Timer? _backoffTimer;
  Completer<void>? _backoffCompleter;

  /// 增量事件流（已按 seq 去重）。
  Stream<PlaybackEvent> get events => _events.stream;

  /// 原始 JSON 消息流（事件信封 + 服务端指令）。
  Stream<Map<String, dynamic>> get rawMessages => _rawMessages.stream;

  /// 发送一条 JSON 消息。未连接或发送失败时返回 false。
  bool sendJson(Map<String, dynamic> message) {
    final connection = _connection;
    if (connection == null || _disposed) return false;
    try {
      connection.send(jsonEncode(message));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 当前已处理的最大 seq。
  int get lastSeq => _lastSeq;

  /// 是否已建立 WS 连接。
  bool get isConnected => _connection != null;

  /// 启动自动重连循环；重复调用无副作用。
  void connect() {
    if (_started || _disposed) return;
    _started = true;
    unawaited(_run());
  }

  Future<void> _run() async {
    while (!_disposed) {
      PlaybackConnection? connection;
      try {
        final ticket = await _connector.fetchTicket();
        if (_disposed) return;

        connection = await _connector.openEvents(ticket);
        if (_disposed) {
          await connection.close();
          return;
        }

        _connection = connection;
        _failures = 0;
        _firstEventAfterConnect = true;
        _setConnected(true);
        _setDegraded(false);
        _stopPolling();
        // 重连成功后立即拉一次全量，不能只依赖增量事件。
        unawaited(_pollPlayback());

        final closed = Completer<void>();
        _connectionClosed = closed;
        _subscription = connection.messages.listen(
          _handleMessage,
          onError: (Object _, StackTrace _) => _complete(closed),
          onDone: () => _complete(closed),
          cancelOnError: true,
        );
        await closed.future;

        // 广播流在 done 之后 cancel() 的 Future 可能永远不完成，不能 await；
        // 此时订阅已经结束，取消只是兜底。
        final subscription = _subscription;
        _subscription = null;
        unawaited(subscription?.cancel());
        // onError 时底层 socket 可能仍处于打开状态，尽力关闭避免泄漏。
        try {
          unawaited(connection.close());
        } catch (_) {
          // 已关闭时忽略。
        }
        _connectionClosed = null;
        _connection = null;
        _setConnected(false);
        if (_disposed) return;

        // 连接建立后断开也算一次失败：连续短命连接同样会进入降级。
        _failures++;
        _maybeDegrade();
        await _waitBackoff();
      } catch (_) {
        if (_disposed) return;
        if (connection != null) {
          try {
            await connection.close();
          } catch (_) {
            // 连接可能已经关闭，忽略。
          }
        }
        _subscription = null;
        _connectionClosed = null;
        _connection = null;
        _setConnected(false);
        _failures++;
        _maybeDegrade();
        await _waitBackoff();
      }
    }
  }

  void _handleMessage(String payload) {
    if (_disposed) return;
    Map<String, dynamic>? decoded;
    try {
      final value = jsonDecode(payload);
      if (value is Map<String, dynamic>) decoded = value;
    } catch (_) {
      // 单条坏消息不应打断整条事件流。
      return;
    }
    if (decoded == null) return;
    if (!_rawMessages.isClosed) _rawMessages.add(decoded);

    final event = PlaybackEvent.tryParseMap(decoded);
    if (event == null) return;

    if (_firstEventAfterConnect) {
      _firstEventAfterConnect = false;
      // 服务端重启后 EventBus 的 seq 从 1 重新计数。新连接首条事件若
      // 严格回退，说明基线已失效；重置后接受，避免永久丢弃全部事件。
      if (event.seq < _lastSeq) _lastSeq = 0;
    }

    if (event.seq <= _lastSeq) return;
    _lastSeq = event.seq;
    if (!_events.isClosed) _events.add(event);
  }

  void _complete(Completer<void> completer) {
    if (!completer.isCompleted) completer.complete();
  }

  void _maybeDegrade() {
    if (_failures < degradedAfterFailures) return;
    _setDegraded(true);
    _startPolling();
  }

  void _setConnected(bool value) {
    if (_disposed || connected.value == value) return;
    connected.value = value;
  }

  void _setDegraded(bool value) {
    if (_disposed || degraded.value == value) return;
    degraded.value = value;
  }

  void _startPolling() {
    if (_disposed || _pollTimer != null) return;
    _pollTimer = Timer.periodic(
      pollInterval,
      (_) => unawaited(_pollPlayback()),
    );
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _pollPlayback() async {
    if (_disposed || _pollInFlight) return;
    _pollInFlight = true;
    try {
      final data = await _connector.fetchPlayback();
      if (!_disposed) snapshot.value = data;
    } catch (_) {
      // 降级轮询失败保留上一份快照，等下一轮；不改变 degraded 状态。
    } finally {
      _pollInFlight = false;
    }
  }

  Future<void> _waitBackoff() {
    // dispose 后不再新建定时器：连接失败可能晚于 dispose 返回，
    // 否则 widget 测试会报 “A Timer is still pending”。
    if (_disposed) return Future<void>.value();
    final index = (_failures - 1).clamp(0, backoffSchedule.length - 1).toInt();
    final completer = Completer<void>();
    _backoffCompleter = completer;
    _backoffTimer = Timer(backoffSchedule[index], () {
      _backoffTimer = null;
      _backoffCompleter = null;
      _complete(completer);
    });
    return completer.future;
  }

  /// 停止重连、关闭连接并释放资源。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    _stopPolling();
    _backoffTimer?.cancel();
    _backoffTimer = null;
    final backoff = _backoffCompleter;
    _backoffCompleter = null;
    if (backoff != null) _complete(backoff);

    final closed = _connectionClosed;
    _connectionClosed = null;
    if (closed != null) _complete(closed);

    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());

    final connection = _connection;
    _connection = null;
    if (connection != null) {
      try {
        await connection.close();
      } catch (_) {
        // 已断开时 close 可能抛错，忽略。
      }
    }

    connected.value = false;
    await _events.close();
    await _rawMessages.close();
    connected.dispose();
    degraded.dispose();
    snapshot.dispose();
  }
}
